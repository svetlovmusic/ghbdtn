import Foundation

/// Persistent, per-language word memory learned from the user's *own* actions —
/// the adaptive layer on top of the curated lists / dictionary / n-gram model.
///
///  - **positive**: target words of *forced* (manual-hotkey) conversions — words
///    the user explicitly asked the engine to produce. Once seen
///    `activationCount` times they behave like curated common words: the engine
///    converts toward them and never converts them away. This is what teaches
///    the engine words no built-in signal knows — names, slang, and short
///    loanwords like "пэд" that fall below the n-gram model's length floor.
///  - **negative**: as-typed words the user *rejected* by backspacing an auto
///    conversion — words that must be KEPT in the layout they were typed in.
///    Once seen `activationCount` times, auto-conversion of them is vetoed.
///
/// Counting rather than learning instantly makes a single stray force or
/// backspace harmless: a word only takes effect after the user repeats the same
/// correction, so accidental one-offs (a typo, a misfire) never stick.
///
/// Persistence is a small JSON file in Application Support. Reads happen on every
/// keystroke (via `LanguageScorer.score`) so they take a lock and return fast;
/// writes are rare (only on an explicit user correction) and flush off-thread.
final class LearnedStore {
    /// How many times the same correction must repeat before it takes effect.
    static let activationCount = 2

    private var positive: [String: [String: Int]] = [:]  // language → word → count
    private var negative: [String: [String: Int]] = [:]
    private let lock = NSLock()
    private let ioQueue = DispatchQueue(label: "com.ghbdtn.learned.io")
    /// nil disables persistence (used by the headless self-test so it never
    /// touches the user's real learned words).
    private let url: URL?

    private struct Snapshot: Codable {
        var positive: [String: [String: Int]]
        var negative: [String: [String: Int]]
    }

    init(persistent: Bool = true) {
        url = persistent ? Self.defaultURL() : nil
        load()
        // Merge the app-bundled seed of shared learned words (committed to git,
        // so a fresh install / another machine already knows what you taught the
        // app). Read-only — never written back; a `--clean` build ships no seed.
        if persistent { mergeSeed() }
    }

    // MARK: - Reads (hot path)

    /// A learned positive word: convert toward it, never convert it away.
    func isLearned(_ word: String, language: String) -> Bool {
        count(word, language, positive: true) >= Self.activationCount
    }

    /// A learned "keep" word: never auto-convert it out of its layout.
    func isKeep(_ word: String, language: String) -> Bool {
        count(word, language, positive: false) >= Self.activationCount
    }

    // MARK: - Writes (user corrections)

    func learnPositive(_ word: String, language: String) { bump(word, language, positive: true) }
    func learnNegative(_ word: String, language: String) { bump(word, language, positive: false) }

    /// Test/diagnostic helper: current count for a word.
    func rawCount(_ word: String, language: String, positive isPositive: Bool) -> Int {
        count(word, language, positive: isPositive)
    }

    // MARK: - Editor (Settings → Словарь)

    /// One learned word, for the editor UI.
    struct Entry: Identifiable {
        let language: String
        let word: String
        let count: Int
        let positive: Bool
        var id: String { "\(positive ? "+" : "-")\(language):\(word)" }
        /// Active = it actually affects conversion (seen ≥ activationCount); a
        /// lower count is still "learning" and has no effect on typing yet.
        var isActive: Bool { count >= LearnedStore.activationCount }
    }

    /// All learned words of one polarity, sorted by language then word.
    func entries(positive isPositive: Bool) -> [Entry] {
        lock.lock(); defer { lock.unlock() }
        let store = isPositive ? positive : negative
        return store
            .flatMap { lang, words in
                words.map { Entry(language: lang, word: $0.key, count: $0.value, positive: isPositive) }
            }
            .sorted { ($0.language, $0.word) < ($1.language, $1.word) }
    }

    /// Remove one learned word (user edit in Settings). Persists; takes effect
    /// on the next keystroke since reads are live.
    func remove(word: String, language: String, positive isPositive: Bool) {
        let w = word.lowercased(), l = language.lowercased()
        lock.lock()
        if isPositive {
            positive[l]?.removeValue(forKey: w)
            if positive[l]?.isEmpty == true { positive[l] = nil }
        } else {
            negative[l]?.removeValue(forKey: w)
            if negative[l]?.isEmpty == true { negative[l] = nil }
        }
        let snap = Snapshot(positive: positive, negative: negative)
        lock.unlock()
        persist(snap)
    }

    /// Remove every learned word of one polarity. Persists.
    func removeAll(positive isPositive: Bool) {
        lock.lock()
        if isPositive { positive = [:] } else { negative = [:] }
        let snap = Snapshot(positive: positive, negative: negative)
        lock.unlock()
        persist(snap)
    }

    // MARK: - Internals

    private func count(_ word: String, _ language: String, positive isPositive: Bool) -> Int {
        let w = word.lowercased(), l = language.lowercased()
        lock.lock(); defer { lock.unlock() }
        return (isPositive ? positive : negative)[l]?[w] ?? 0
    }

    private func bump(_ word: String, _ language: String, positive isPositive: Bool) {
        let w = word.lowercased(), l = language.lowercased()
        lock.lock()
        if isPositive {
            positive[l, default: [:]][w, default: 0] += 1
        } else {
            negative[l, default: [:]][w, default: 0] += 1
        }
        let snap = Snapshot(positive: positive, negative: negative)
        lock.unlock()
        persist(snap)
    }

    private func load() {
        guard let url, let data = try? Data(contentsOf: url),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        lock.lock()
        positive = snap.positive
        negative = snap.negative
        lock.unlock()
    }

    /// Fold the shipped seed into memory, keeping the higher count per word, so
    /// seeded words are known without overwriting the user's own writable file.
    private func mergeSeed() {
        guard let seedURL = Self.locateSeed(),
              let data = try? Data(contentsOf: seedURL),
              let snap = try? JSONDecoder().decode(Snapshot.self, from: data) else { return }
        lock.lock(); defer { lock.unlock() }
        for (lang, words) in snap.positive {
            for (w, c) in words { positive[lang, default: [:]][w] = max(positive[lang]?[w] ?? 0, c) }
        }
        for (lang, words) in snap.negative {
            for (w, c) in words { negative[lang, default: [:]][w] = max(negative[lang]?[w] ?? 0, c) }
        }
    }

    /// Locate the bundled `seed-learned.json` (same search as NgramModel). A
    /// `--clean` install ships without it, so this returns nil and the seed is
    /// simply skipped.
    private static func locateSeed() -> URL? {
        let file = "Ghbdtn_Ghbdtn.bundle/seed-learned.json"
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL { candidates.append(res.appendingPathComponent(file)) }
        if let exe = Bundle.main.executableURL {
            candidates.append(exe.deletingLastPathComponent().appendingPathComponent(file))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    private func persist(_ snap: Snapshot) {
        guard let url else { return }
        ioQueue.async {
            if let data = try? JSONEncoder().encode(snap) {
                try? data.write(to: url, options: .atomic)
            }
        }
    }

    private static func defaultURL() -> URL? {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                     in: .userDomainMask).first else { return nil }
        let dir = support.appendingPathComponent("Ghbdtn", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("learned.json")
    }
}
