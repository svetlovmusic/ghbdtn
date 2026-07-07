import Foundation
import AppKit

/// A memoized, lazily-computed Bool: the closure runs at most once, on first
/// read. Lets `LanguageScorer.Score` defer its NSSpellChecker lookup so the
/// per-word hot path (on the event-tap thread) skips the synchronous spellcheck
/// entirely whenever a cheaper signal (curated/learned word) already decides.
private final class LazyBool {
    private var cached: Bool?
    private let compute: () -> Bool
    init(_ compute: @escaping () -> Bool) { self.compute = compute }
    var value: Bool {
        if let cached { return cached }
        let v = compute(); cached = v; return v
    }
}

/// Scores how plausible a string is as real text in a given language.
///
/// Two signals are combined:
///  1. `NSSpellChecker` — authoritative for complete words, supports every
///     language macOS ships a dictionary for (so the engine is not limited
///     to the ru/en pair).
///  2. Character-bigram coverage — cheap statistical signal that also works
///     for partial words and out-of-vocabulary tokens. English statistics are
///     built from `/usr/share/dict/words`; other languages learn adaptively
///     from words the spellchecker accepts, seeded with a built-in Russian
///     corpus.
final class LanguageScorer {
    /// Set to false before the singleton is first touched (by `--selftest`) so
    /// the learned-words store runs in-memory and never touches the user's file.
    static var persistLearning = true
    static let shared = LanguageScorer()

    struct Score {
        let text: String
        let language: String
        /// 0…1: fraction of adjacent letter pairs that are common in the language.
        let bigramCoverage: Double
        /// The spellchecker recognizes the exact word. Evaluated lazily — the
        /// NSSpellChecker round-trip only happens if a caller actually reads it,
        /// so the confident curated/learned path pays no spellcheck at all.
        fileprivate let _isDictionaryWord: LazyBool
        var isDictionaryWord: Bool { _isDictionaryWord.value }
        /// The word is in our curated frequent-words list for the language.
        /// This is the override for the OS spellchecker's rare false-accepts
        /// (e.g. it wrongly calls the abracadabra "ghbdtn" a valid English word).
        let isCommonWord: Bool
        /// Letters from the language's own script make up the string.
        let scriptMatch: Bool
        /// Calibrated 4-gram score: where the string's per-character avg logP
        /// sits among real words of the language (0…1). Comparable across
        /// languages, unlike raw perplexity. nil when the n-gram model is not
        /// loaded, the string is too short, or it has out-of-alphabet chars.
        let ngramPercentile: Double?
        /// The n-gram model is loaded but the string contains characters the
        /// language's alphabet doesn't have (e.g. ";bpym" for English) — by
        /// definition it is not a word of this language.
        let ngramForeign: Bool
        /// The user has taught the engine this word via repeated forced
        /// conversions (LearnedStore). Treated like a curated common word.
        let isLearnedWord: Bool
        /// The user has repeatedly rejected auto-converting this word (backspace
        /// after an auto-conversion) — it must be kept in its layout.
        let isKeepWord: Bool
    }

    private var bigrams: [String: Set<String>] = [:]  // language → set of "ab" pairs
    /// language → curated set of frequent words. Built synchronously in init so
    /// it is ready before the very first keystroke (unlike the async bigrams).
    private var commonWords: [String: Set<String>] = [:]
    /// language → character 4-gram model, loaded asynchronously in init.
    /// Until a model is loaded, Score.ngramPercentile stays nil and the
    /// Decider's n-gram layer simply abstains.
    private var ngramModels: [String: NgramModel] = [:]
    /// Adaptive per-language memory of the user's own corrections.
    private let learned: LearnedStore
    private let spellChecker = NSSpellChecker.shared
    private var spellDocTag: Int = 0
    private var availableSpellLanguages: Set<String> = []
    private let queue = DispatchQueue(label: "com.ghbdtn.scorer")

    private init() {
        learned = LearnedStore(persistent: Self.persistLearning)
        spellDocTag = NSSpellChecker.uniqueSpellDocumentTag()
        availableSpellLanguages = Set(spellChecker.availableLanguages.map {
            String($0.split(separator: "_").first ?? Substring($0)).lowercased()
        })
        commonWords["ru"] = Set(Self.russianSeedWords)
        commonWords["en"] = Set(Self.englishCommonWords)
        commonWords["uk"] = Set(Self.ukrainianCommonWords)
        seedModels()
    }

    // MARK: - Public

    /// - Parameter completeWord: false when scoring a word still being typed
    ///   (live mode) — the n-gram layer then scores it as a prefix, without
    ///   the end-of-word transition.
    func score(_ text: String, language: String, completeWord: Bool = true) -> Score {
        let lower = text.lowercased()
        let lang = language.lowercased()
        let model: NgramModel? = queue.sync { ngramModels[lang] }
        return Score(
            text: text,
            language: language,
            bigramCoverage: bigramCoverage(lower, language: language),
            _isDictionaryWord: LazyBool { [self] in isDictionaryWord(text, language: language) },
            isCommonWord: isCommonWord(text, language: language),
            scriptMatch: scriptMatches(lower, language: language),
            ngramPercentile: model?.percentile(of: lower, complete: completeWord),
            ngramForeign: model?.hasForeignCharacters(lower) ?? false,
            isLearnedWord: learned.isLearned(lower, language: lang),
            isKeepWord: learned.isKeep(lower, language: lang)
        )
    }

    /// Prime the OS spellchecker dictionaries for the given languages so the
    /// first live word doesn't pay per-language cold-start latency on the
    /// event-tap (main) thread. Cheap and idempotent; call once at launch.
    func warmUp(languages: [String]) {
        for lang in Set(languages.map { $0.lowercased() }) where hasSpellDictionary(for: lang) {
            _ = spellChecker.checkSpelling(
                of: "aa", startingAt: 0, language: lang, wrap: false,
                inSpellDocumentWithTag: spellDocTag, wordCount: nil
            )
        }
    }

    // MARK: - Adaptive learning

    /// Remember a word the user *forced* the engine to produce (manual hotkey).
    /// After `LearnedStore.activationCount` repeats it is treated like a curated
    /// common word: the engine converts toward it and keeps it when typed
    /// correctly. Only clean, script-consistent words are stored, so wrong-layout
    /// junk (the source side of a conversion) can never poison the store.
    func learnPositive(word: String, language: String) {
        guard isCleanWord(word, language: language) else { return }
        learned.learnPositive(word, language: language)
    }

    /// Remember that the user rejected auto-converting this word (it must be kept
    /// in the layout it was typed in). Same cleanliness guard as `learnPositive`.
    func learnNegative(word: String, language: String) {
        guard isCleanWord(word, language: language) else { return }
        learned.learnNegative(word, language: language)
    }

    /// Diagnostic accessor for the self-test.
    func learnedCount(word: String, language: String, positive: Bool) -> Int {
        learned.rawCount(word, language: language, positive: positive)
    }

    /// A word worth storing: ≥2 letters, only letters plus internal
    /// apostrophes/hyphens, and written in the language's own script.
    private func isCleanWord(_ word: String, language: String) -> Bool {
        let lower = word.lowercased()
        guard lower.filter({ $0.isLetter }).count >= 2,
              lower.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }) else {
            return false
        }
        return scriptMatches(lower, language: language)
    }

    /// Is the character 4-gram model for this language loaded yet?
    func hasNgramModel(for language: String) -> Bool {
        queue.sync { ngramModels[language.lowercased()] != nil }
    }

    /// Is this an exact match in our curated frequent-words list for the language?
    func isCommonWord(_ word: String, language: String) -> Bool {
        commonWords[language.lowercased()]?.contains(word.lowercased()) ?? false
    }

    /// Feed a confirmed-valid word back into the bigram model so coverage of
    /// languages beyond ru/en improves with use.
    func learn(word: String, language: String) {
        let lower = word.lowercased()
        queue.sync {
            var set = bigrams[language] ?? []
            for pair in Self.pairs(of: lower) { set.insert(pair) }
            bigrams[language] = set
        }
    }

    /// Does macOS have a spelling dictionary for this language?
    func hasSpellDictionary(for language: String) -> Bool {
        availableSpellLanguages.contains(language.lowercased())
    }

    // MARK: - Spellcheck

    func isDictionaryWord(_ word: String, language: String) -> Bool {
        guard word.count >= 2 else { return false }
        // NSSpellChecker tokenizes its input, so it reports ",l/" and "it."
        // both "clean": it just skips the punctuation. That means it can't be
        // trusted to tell a real word from wrong-layout junk that merely
        // contains punctuation. Judge the alphabetic core instead — strip
        // leading/trailing non-letters (sentence punctuation rides into the
        // buffer on keys that carry a letter in another layout: RU '.' is 'ю')
        // and require what remains to be a genuine word: letters plus internal
        // apostrophes/hyphens (don't, кто-то), at least two characters.
        //   ",l/"  → core "l"    → too short → not a word (fixes бд → ,l/)
        //   "it."  → core "it"   → real word → blocks it. → шею
        //   "don't"→ core "don't"→ real word
        let core = word.trimmingCharacters(in: CharacterSet.letters.inverted)
        guard core.count >= 2,
              core.allSatisfy({ $0.isLetter || $0 == "'" || $0 == "’" || $0 == "-" }) else {
            return false
        }
        // NSSpellChecker tokenizes on internal apostrophes/hyphens and never
        // flags a lone single letter — it even accepts "ls" — so it rubber-stamps
        // wrong-layout junk whose Latin twin carries an apostrophe from the «э»
        // key: "g'l" → пэд, "g'ls" → пэды, "v'h" → мэр. A genuine
        // contraction/possessive/compound attaches the separator to a
        // substantial stem, so require the part before the first separator to be
        // at least two letters. Kills g'l / g'ls / a'b while keeping don't,
        // we're, кто-то, mother-in-law. (Drops I'm / o'clock, which never take
        // part in a real wrong-layout conversion anyway.)
        if let sep = core.firstIndex(where: { $0 == "'" || $0 == "’" || $0 == "-" }) {
            guard core.distance(from: core.startIndex, to: sep) >= 2 else { return false }
        }
        // NSSpellChecker rubber-stamps many bare 2-letter tokens that aren't real
        // words ("pf", "ls"), so a 2-letter core is only trusted when it is also a
        // curated common word — genuine 2-letter words ("in"/"он") are curated.
        // Fixes issue #3: юзаю → ".pf." (ю on the '.' key; core "pf" false-accepted).
        if core.filter({ $0.isLetter }).count < 3, !isCommonWord(core, language: language) {
            return false
        }
        // Map plain code to a concrete dictionary if needed ("ru" → "ru", "en" → "en").
        guard hasSpellDictionary(for: language) else { return false }
        let range = spellChecker.checkSpelling(
            of: core,
            startingAt: 0,
            language: language,
            wrap: false,
            inSpellDocumentWithTag: spellDocTag,
            wordCount: nil
        )
        return range.location == NSNotFound
    }

    // MARK: - Bigram model

    private func bigramCoverage(_ text: String, language: String) -> Double {
        let letters = text.filter { $0.isLetter }
        guard letters.count >= 2 else { return 0 }
        let known: Set<String> = queue.sync { bigrams[language] ?? [] }
        guard !known.isEmpty else { return 0 }
        let pairs = Self.pairs(of: String(letters))
        guard !pairs.isEmpty else { return 0 }
        let hits = pairs.filter { known.contains($0) }.count
        return Double(hits) / Double(pairs.count)
    }

    private static func pairs(of text: String) -> [String] {
        let chars: [Character] = Array(text)
        guard chars.count >= 2 else { return [] }
        var result: [String] = []
        result.reserveCapacity(chars.count - 1)
        for i in 0..<(chars.count - 1) {
            result.append(String(chars[i]) + String(chars[i + 1]))
        }
        return result
    }

    // MARK: - Script detection

    private func scriptMatches(_ text: String, language: String) -> Bool {
        let letters = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }
        guard !letters.isEmpty else { return false }
        let matching = letters.filter { Self.script(for: language).contains($0) }
        return Double(matching.count) / Double(letters.count) > 0.9
    }

    private static func script(for language: String) -> CharacterSet {
        switch language {
        case "ru", "uk", "be", "bg", "sr", "mk", "kk":
            return CharacterSet(charactersIn: Unicode.Scalar(0x0400)!...Unicode.Scalar(0x04FF)!)
        case "el":
            return CharacterSet(charactersIn: Unicode.Scalar(0x0370)!...Unicode.Scalar(0x03FF)!)
        case "he", "yi":
            return CharacterSet(charactersIn: Unicode.Scalar(0x0590)!...Unicode.Scalar(0x05FF)!)
        case "ar", "fa", "ur":
            return CharacterSet(charactersIn: Unicode.Scalar(0x0600)!...Unicode.Scalar(0x06FF)!)
        case "hy":
            return CharacterSet(charactersIn: Unicode.Scalar(0x0530)!...Unicode.Scalar(0x058F)!)
        case "ka":
            return CharacterSet(charactersIn: Unicode.Scalar(0x10A0)!...Unicode.Scalar(0x10FF)!)
        case "th":
            return CharacterSet(charactersIn: Unicode.Scalar(0x0E00)!...Unicode.Scalar(0x0E7F)!)
        default:
            // Latin-script languages, incl. extended Latin (é, ü, ç, ...).
            var set = CharacterSet(charactersIn: Unicode.Scalar(0x0041)!...Unicode.Scalar(0x007A)!)
            set.formUnion(CharacterSet(charactersIn: Unicode.Scalar(0x00C0)!...Unicode.Scalar(0x024F)!))
            return set
        }
    }

    // MARK: - Seeding

    private func seedModels() {
        queue.async { [weak self] in
            guard let self else { return }
            var en = Set<String>()
            // The system word list gives near-complete English bigram coverage.
            if let words = try? String(contentsOfFile: "/usr/share/dict/words", encoding: .utf8) {
                for word in words.split(separator: "\n").prefix(120_000) {
                    for pair in Self.pairs(of: word.lowercased()) { en.insert(pair) }
                }
            }
            var ru = Set<String>()
            for word in Self.russianSeedWords {
                for pair in Self.pairs(of: word) { ru.insert(pair) }
            }
            self.queue.async {} // no-op; we're already on the queue
            self.bigrams["en"] = en
            self.bigrams["ru"] = ru
            Log.info("Bigram models seeded: en=\(en.count) pairs, ru=\(ru.count) pairs")

            for lang in ["en", "ru", "uk"] {
                guard let url = NgramModel.locateModel(language: lang) else {
                    Log.error("No n-gram model found for \(lang) — OOV detection disabled")
                    continue
                }
                if let model = NgramModel(contentsOf: url) {
                    self.ngramModels[lang] = model
                    Log.info("N-gram model \(lang): \(model.sizeBytes / 1024) KB from \(url.path)")
                } else {
                    Log.error("Failed to parse n-gram model at \(url.path)")
                }
            }
        }
    }

    /// Frequent Russian words used to seed the Cyrillic bigram model. The
    /// spellchecker feedback loop (`learn`) extends coverage during use.
    private static let russianSeedWords: [String] = [
        "и", "в", "не", "на", "я", "быть", "он", "с", "что", "а", "по", "это",
        "она", "этот", "к", "но", "они", "мы", "как", "из", "у", "который",
        "то", "за", "свой", "весь", "год", "от", "так", "о", "для", "ты",
        "же", "все", "тот", "мочь", "вы", "человек", "такой", "его", "сказать",
        "только", "или", "еще", "бы", "себя", "один", "как", "уже", "до",
        "время", "если", "сам", "когда", "другой", "вот", "говорить", "наш",
        "мой", "знать", "стать", "при", "чтобы", "дело", "жизнь", "кто",
        "первый", "очень", "два", "день", "ее", "новый", "рука", "даже",
        "во", "со", "раз", "где", "там", "под", "можно", "ну", "какой",
        "после", "их", "работа", "без", "самый", "потом", "надо", "хотеть",
        "ли", "слово", "идти", "большой", "должен", "место", "иметь", "ничего",
        "сейчас", "тут", "лицо", "друг", "нет", "теперь", "ни", "глаз",
        "тоже", "тогда", "видеть", "вопрос", "через", "да", "здесь", "дом",
        "стоять", "думать", "спросить", "человека", "смотреть", "жить", "чем",
        "мир", "просто", "сила", "конечно", "понять", "почему", "делать",
        "вдруг", "над", "взять", "никто", "сделать", "дверь", "перед", "нужно",
        "понимать", "казаться", "голова", "остаться", "куда", "письмо", "несколько",
        "слышать", "решить", "именно", "начать", "хорошо", "почти", "правда",
        "земля", "конец", "минута", "любить", "пройти", "больше", "хотя",
        "всегда", "второй", "страна", "вода", "отец", "лишь", "город", "путь",
        "деньги", "снова", "лучше", "пока", "мама", "чуть", "утро",
        "вечер", "ночь", "давно", "маленький", "например", "русский",
        "привет", "спасибо", "пожалуйста", "здравствуйте", "сегодня", "завтра",
        "вчера", "сообщение", "написать", "текст", "язык", "клавиатура",
        "раскладка", "программа", "компьютер", "телефон", "интернет", "почта",
        "проект", "задача", "встреча", "документ", "файл", "папка", "музыка",
        "фильм", "книга", "школа", "работать", "учиться", "играть", "читать",
        "писать", "думаю", "может", "хочу", "буду", "есть", "была", "были",
        "было", "меня", "тебя", "него", "неё", "нас", "вас", "них", "мне",
        "тебе", "ему", "ей", "нам", "вам", "им", "мной", "тобой", "собой"
    ].map { $0.lowercased() }.filter { $0.allSatisfy { ch in ch.isLetter && ("а"..."я" ~= ch || ch == "ё") } }

    /// Frequent English words. Used as the override signal when the OS
    /// spellchecker false-accepts a wrong-layout string in the *other*
    /// direction (a Cyrillic abracadabra whose Latin twin is a real word).
    private static let englishCommonWords: [String] = [
        "the", "be", "to", "of", "and", "a", "in", "that", "have", "it", "for",
        "not", "on", "with", "he", "as", "you", "do", "at", "this", "but", "his",
        "by", "from", "they", "we", "say", "her", "she", "or", "an", "will", "my",
        "one", "all", "would", "there", "their", "what", "so", "up", "out", "if",
        "about", "who", "get", "which", "go", "me", "when", "make", "can", "like",
        "time", "no", "just", "him", "know", "take", "people", "into", "year",
        "your", "good", "some", "could", "them", "see", "other", "than", "then",
        "now", "look", "only", "come", "its", "over", "think", "also", "back",
        "after", "use", "two", "how", "our", "work", "first", "well", "way",
        "even", "new", "want", "because", "any", "these", "give", "day", "most",
        "us", "hello", "hi", "hey", "yes", "please", "thanks", "thank", "sorry",
        "okay", "ok", "today", "tomorrow", "yesterday", "message", "text", "code",
        "file", "folder", "email", "project", "task", "meeting", "document",
        "keyboard", "layout", "computer", "phone", "internet", "world", "home",
        "name", "email", "password", "login", "user", "please", "cool", "nice",
        "great", "love", "life", "man", "woman", "child", "world", "school",
        "state", "family", "student", "group", "country", "problem", "hand",
        "part", "place", "case", "week", "company", "system", "program",
        "question", "government", "number", "night", "point", "water", "room",
        "mother", "area", "money", "story", "fact", "month", "lot", "right",
        "study", "book", "eye", "job", "word", "business", "issue", "side",
        "kind", "head", "house", "service", "friend", "father", "power", "hour",
        "game", "line", "end", "member", "car", "city", "community", "read",
        "write", "play", "run", "move", "live", "believe", "hold", "bring",
        "happen", "must", "walk", "help", "start", "call", "open", "close"
    ]

    /// Frequent Ukrainian words. Curated from real corpus frequency (Leipzig
    /// ukr corpora, tools/train_ngram.py) plus everyday/greeting/tech terms, so
    /// short common words the n-gram can't judge (2–4 letters) still convert
    /// reliably once a Ukrainian layout is enabled.
    private static let ukrainianCommonWords: [String] = [
        "на", "в", "у", "і", "що", "з", "не", "та", "до", "за",
        "це", "про", "а", "для", "як", "від", "він", "але", "його", "які",
        "також", "ми", "й", "я", "року", "із", "вони", "тому", "під", "по",
        "буде", "ще", "було", "вже", "щоб", "час", "так", "чи", "якщо", "цього",
        "після", "того", "її", "який", "коли", "може", "вона", "через", "ви", "зараз",
        "все", "те", "можна", "дуже", "їх", "то", "має", "або", "ж", "сьогодні",
        "яка", "лише", "був", "років", "сказав", "були", "більше", "україна", "людей", "бути",
        "всі", "навіть", "цей", "де", "цьому", "зі", "при", "них", "саме", "була",
        "можуть", "хто", "багато", "проти", "без", "нас", "тільки", "там", "один", "раніше",
        "році", "тим", "ці", "будуть", "життя", "яких", "день", "немає", "мають", "треба",
        "країни", "люди", "тоді", "тут", "понад", "свою", "потрібно", "ради", "просто", "крім",
        "однак", "свої", "між", "серед", "ніж", "себе", "тисяч", "рік", "майже", "два",
        "близько", "мене", "інших", "початку", "кілька", "разом", "будь", "ні", "потім", "міста",
        "перед", "всіх", "роботи", "українських", "своїх", "фото", "над", "нього", "поки", "такі",
        "дітей", "адже", "українські", "проте", "той", "цієї", "яку", "травня", "цю", "мені",
        "йому", "тепер", "свого", "протягом", "ця", "цих", "інші", "три", "нам", "їм",
        "хоча", "кількість", "української", "чому", "березня", "відомо", "часом", "думку", "участь", "тих",
        "оскільки", "місце", "дня", "варто", "якого", "осіб", "каже", "завжди", "ті", "таких",
        "двох", "тобто", "одного", "зробити", "яке", "знову", "водночас", "квітня", "більш", "наразі",
        "роки", "тис", "біля", "українців", "роботу", "перший", "лютого", "такий", "українського", "вас",
        "свій", "би", "наші", "собі", "чоловік", "усі", "наприклад", "червня", "уже", "минулого",
        "часу", "вам", "січня", "гроші", "таким", "став", "цим", "новий", "одна", "речі",
        "якому", "о", "стало", "можливість", "привіт", "вітаю", "доброго", "ранку", "добрий", "вечір",
        "добраніч", "дякую", "прошу", "вибач", "перепрошую", "гаразд", "авжеж", "звісно", "звичайно", "погано",
        "хочу", "можу", "буду", "роблю", "пишу", "читаю", "знаю", "бачу", "думаю", "люблю",
        "розумію", "друг", "друже", "подруга", "дім", "дома", "робота", "школа", "книга", "вода",
        "рука", "очі", "голос", "пісня", "музика", "фільм", "слово", "мова", "українська", "російська",
        "англійська", "клавіатура", "розкладка", "компютер", "комп'ютер", "телефон", "інтернет", "пошта", "повідомлення", "текст",
        "файл", "папка", "посилання", "проєкт", "задача", "зустріч", "документ", "звук", "завтра", "вчора",
        "швидко", "повільно", "старий", "великий", "малий", "гарний", "поганий"
    ].map { $0.lowercased() }
}
