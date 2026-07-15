import Foundation
import AppKit
import Carbon
import Combine

/// The orchestrator. Consumes tap events, maintains the word buffer, and
/// decides — using the LanguageScorer across all enabled layouts — whether the
/// current word was typed in the wrong layout, then drives TextInjector to fix
/// it and switch the system layout.
final class AutoSwitchEngine {
    static let shared = AutoSwitchEngine()

    /// Emitted whenever a conversion happens, for the menu-bar activity log.
    let didConvert = PassthroughSubject<ConversionRecord, Never>()
    /// Emitted when running state changes (permission lost, toggled off).
    @Published private(set) var isActive = false

    struct ConversionRecord {
        let from: String  // original text
        let to: String    // corrected text
        let fromLayout: String
        let toLayout: String
        let viaAI: Bool
    }

    private let tap = EventTap()
    private let buffer = WordBuffer()
    private let settings = Settings.shared
    private var cancellables = Set<AnyCancellable>()
    private var layoutObserver: NSObjectProtocol?

    /// Enabled layouts, refreshed when the system set changes.
    private var layouts: [KeyboardLayout] = []
    private var frontmostBundleID: String?

    /// The word we just auto-converted, kept so an immediate ⌦/retype can veto it.
    private var lastConversionOriginal: String?

    /// The most recent *automatic* conversion (not a manual-forced one), kept so
    /// that an explicit rejection (⌘Z, or delete-and-retype) feeds persistent
    /// negative learning: the as-typed word plus its source language, i.e.
    /// "the user rejected converting this".
    private var lastAutoConversion: (text: String, sourceLang: String)?
    /// When the last conversion was applied — bounds the ⌘Z rejection window so
    /// an unrelated undo minutes later can't teach a false rejection.
    private var lastConversionAt = Date.distantPast
    /// Armed by a backspace right after an auto-conversion: if the user then
    /// finishes a word identical to the conversion's original, they retyped
    /// what we converted away — THAT counts as a rejection. A lone backspace
    /// does not (it is usually just editing), see checkRetypeRejection().
    private var pendingRejectRetype: (text: String, sourceLang: String)?

    /// True when the last conversion's target is a curated common word (e.g.
    /// "привет"). These flagship words must never be self-disabled by a
    /// reflexive backspace, so both the session veto and negative learning skip
    /// them — otherwise normal testing silently teaches the engine to stop
    /// converting its own headline case.
    private var lastConversionProtected = false

    /// Monotonic counter bumped on every keyboard/navigation event. Async
    /// deciders (the cloud-AI layer) capture it before their network round-trip
    /// and refuse to inject if it changed — i.e. the user typed something since,
    /// so the caret has moved and a blind backspace-retype would corrupt text.
    private(set) var editGeneration = 0

    private init() {}

    // MARK: - Lifecycle

    /// Returns false if Accessibility permission is missing.
    @discardableResult
    func start() -> Bool {
        refreshLayouts()
        observeSystem()

        tap.handler = { [weak self] event in
            self?.handle(event)
        }
        let ok = tap.start()
        isActive = ok && settings.autoSwitchEnabled
        return ok
    }

    func stop() {
        tap.stop()
        isActive = false
    }

    /// Re-evaluate whether the tap should be delivering (permission + toggle).
    func syncEnabledState() {
        if settings.autoSwitchEnabled {
            if !tap.isRunning { _ = tap.start() }
            isActive = tap.isRunning
        } else {
            // Keep the tap alive (so re-enabling is instant) but ignore events.
            isActive = false
        }
    }

    private func observeSystem() {
        // Track the frontmost app to honor per-app exclusions.
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.frontmostBundleID = app?.bundleIdentifier
            // A focus change moves the caret to a different field/app; invalidate
            // any in-flight async (AI) correction so it can't inject there, and
            // disarm rejection tracking — a ⌘Z in another app is not about us.
            self?.editGeneration &+= 1
            self?.buffer.hardReset()
            self?.lastConversionOriginal = nil
            self?.lastAutoConversion = nil
            self?.lastConversionProtected = false
            self?.pendingRejectRetype = nil
        }
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // Rebuild layout list when the user enables/disables layouts.
        layoutObserver = LayoutManager.shared.observeLayoutChanges { [weak self] in
            guard let self else { return }
            self.editGeneration &+= 1
            if !LayoutManager.shared.isProgrammaticSwitch {
                // A user-initiated layout switch invalidates the in-progress
                // word, but the COMPLETED words are still on screen untouched —
                // keep their history (soft, which also detaches them from
                // automatic retro fixes) so the manual hotkey keeps working.
                // hardReset here silently killed post-conversion hotkey use.
                self.buffer.softReset()
            }
            self.refreshLayouts()
        }

        // React to the auto-switch toggle live.
        settings.$autoSwitchEnabled
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.syncEnabledState() }
            .store(in: &cancellables)
    }

    private func refreshLayouts() {
        layouts = LayoutManager.shared.enabledLayouts()
        KeyTranslator.shared.invalidateCaches()
        Log.debug("Layouts: \(layouts.map(\.id).joined(separator: ", "))")
    }

    // MARK: - Event handling

    private func handle(_ event: EventTap.TapEvent) {
        guard settings.autoSwitchEnabled, isActive else {
            // Still keep buffer coherent on resets so re-enabling is clean.
            if case .navigationOrClick = event { buffer.softReset() }
            if case .secureInputActive = event { buffer.hardReset() }
            return
        }

        // Per-app exclusion.
        if let bid = frontmostBundleID, settings.excludedBundleIDs.contains(bid) {
            return
        }

        // Any real input invalidates in-flight async (AI) corrections.
        editGeneration &+= 1

        switch event {
        case .secureInputActive:
            buffer.hardReset()
            pendingRejectRetype = nil

        case .navigationOrClick:
            buffer.softReset()
            // The caret moved: a later ⌘Z is about whatever the user is doing
            // now, not about the conversion — disarm the rejection window too.
            pendingRejectRetype = nil
            lastConversionOriginal = nil
            lastAutoConversion = nil
            lastConversionProtected = false

        case .backspace:
            // A backspace right after an auto-conversion is NOT a rejection by
            // itself: it is usually just editing (deleting the space to type a
            // comma, rephrasing), and counting it silently taught the engine to
            // permanently stop converting words the user wanted (learned.json
            // filled with poisoned keep-words). It only ARMS retype-detection:
            // if the user now types the same original token back and finishes
            // it, that is a deliberate rejection — see checkRetypeRejection().
            // The immediate rejection signal is ⌘Z (handleCommandShortcut).
            // Curated flagship words stay exempt from all rejection learning.
            if let auto = lastAutoConversion, !auto.sourceLang.isEmpty, !lastConversionProtected {
                pendingRejectRetype = auto
            }
            buffer.backspace()
            lastConversionOriginal = nil
            lastAutoConversion = nil
            lastConversionProtected = false

        case let .key(stroke, hasCommandLikeModifiers, hasCommandKey):
            if hasCommandLikeModifiers {
                handleCommandShortcut(stroke, isCommand: hasCommandKey)
                return
            }
            guard let active = LayoutManager.shared.currentLayout() else { return }
            // Sentence punctuation ends the word — but only when the key
            // carries no letter in any enabled layout. Keys like ';' or ','
            // ARE letters elsewhere (ж, б in Russian) and must stay in the
            // buffer, otherwise wrong-layout words like ";bpym" fall apart.
            if let punct = delimiterCharacter(for: stroke, activeLayout: active) {
                checkRetypeRejection()
                // This keystroke is new input after any prior conversion, so
                // it closes the immediate-reject window (a later backspace must
                // not veto the word we converted before it).
                lastConversionOriginal = nil
                lastAutoConversion = nil
                // Pass the stroke: if the word converts, the delimiter has to be
                // re-typed as the *target* layout's character (the ABC '/' the
                // user pressed means Russian '.'), not the source glyph.
                evaluateCurrentWord(final: true, delimiter: punct, delimiterStroke: stroke)
                buffer.complete(delimiterChar: punct)
                return
            }
            buffer.append(stroke, activeLayoutID: active.id)
            lastConversionOriginal = nil
            lastAutoConversion = nil
            if settings.trigger == .live {
                scheduleLiveEvaluation()
            }

        case let .wordDelimiter(_, char):
            checkRetypeRejection()
            // New input after a prior conversion closes its ⌘Z-rejection
            // window (an undo pressed later is aimed at this newer edit). A
            // conversion triggered by THIS delimiter re-arms below in apply().
            lastConversionOriginal = nil
            lastAutoConversion = nil
            lastConversionProtected = false
            // Evaluate the word we just finished, then roll the buffer — but
            // only when a SPACE finished it. Return and Tab carry action
            // semantics (submit a chat message, run a shell line, move focus)
            // about as often as they insert a character, and we can't tell
            // which. Converting after them corrupts text either way: in a chat
            // the Enter has already submitted the uncorrected message, so the
            // late correction types ghost text into the now-empty input; in a
            // multi-line editor one of our backspaces eats the newline and the
            // word's first letter survives. So Enter/Tab only complete the
            // buffer — the word stays reachable via the manual hotkey.
            if char == " " {
                evaluateCurrentWord(final: true, delimiter: " ")
            }
            buffer.complete(delimiterChar: char)
        }
    }

    /// ⌘Z right after an auto-conversion is the user undoing it — the
    /// strongest rejection signal available. The tap is listen-only, so the
    /// shortcut still reaches the app and performs the app's own undo; we only
    /// learn from it: veto the token for this session outright and count one
    /// persistent rejection (permanent after LearnedStore.activationCount).
    /// ⇧⌘Z (redo), ⌃Z (not undo on macOS) and every other shortcut just act
    /// as a caret boundary. Detection is by physical QWERTY-Z position — on
    /// remapped Latin layouts (plain Dvorak) it may miss; acceptable, it only
    /// costs a learning signal, never a conversion.
    private func handleCommandShortcut(_ stroke: KeyStroke, isCommand: Bool) {
        let isUndo = isCommand && Int(stroke.keyCode) == kVK_ANSI_Z && !stroke.shift
        if isUndo,
           let auto = lastAutoConversion, !auto.sourceLang.isEmpty, !lastConversionProtected,
           Date().timeIntervalSince(lastConversionAt) < Self.undoRejectWindow {
            if let rejected = lastConversionOriginal {
                buffer.veto(rejected, weight: WordBuffer.vetoThreshold)
            }
            LanguageScorer.shared.learnNegative(word: auto.text, language: auto.sourceLang)
            Log.info("⌘Z after auto-conversion: rejection learned for \"\(auto.text)\"")
        }
        lastConversionOriginal = nil
        lastAutoConversion = nil
        lastConversionProtected = false
        pendingRejectRetype = nil
        buffer.softReset()
    }
    private static let undoRejectWindow: TimeInterval = 20

    /// Second half of backspace rejection (armed in the .backspace handler):
    /// the user deleted a fresh auto-conversion and has now finished a word.
    /// If it reads exactly like the conversion's original in the same layout,
    /// they deliberately retyped what we converted away — veto it for the
    /// session and count one persistent rejection. Any other word disarms.
    private func checkRetypeRejection() {
        guard let pending = pendingRejectRetype else { return }
        pendingRejectRetype = nil
        guard !buffer.current.isEmpty,
              let lid = buffer.layoutID,
              let src = layouts.first(where: { $0.id == lid }),
              (src.primaryLanguage ?? "") == pending.sourceLang else { return }
        let asTyped = KeyTranslator.shared.interpret(buffer.current, layout: src)
        guard asTyped.lowercased() == pending.text.lowercased() else { return }
        buffer.veto(asTyped, weight: WordBuffer.vetoThreshold)
        LanguageScorer.shared.learnNegative(word: pending.text, language: pending.sourceLang)
        Log.info("Delete-and-retype after auto-conversion: rejection learned for \"\(pending.text)\"")
    }

    /// The character this keystroke contributes as a word boundary, or nil
    /// when it may be part of a word. A key counts as punctuation only if it
    /// produces a single punctuation/symbol character in the active layout
    /// AND no other enabled layout puts a letter on it: the ABC '/' key
    /// (Russian '.') qualifies, while ';' or ',' do not — they are ж and б
    /// when the user meant to type Russian.
    private func delimiterCharacter(for stroke: KeyStroke, activeLayout: KeyboardLayout) -> Character? {
        let translator = KeyTranslator.shared
        guard let produced = translator.translate(stroke, layout: activeLayout),
              produced.count == 1, let ch = produced.first,
              ch.isPunctuation || ch.isSymbol else { return nil }
        for layout in layouts where layout.id != activeLayout.id {
            if let s = translator.translate(stroke, layout: layout),
               s.contains(where: { $0.isLetter }) {
                return nil
            }
        }
        return ch
    }

    // MARK: - Decision

    /// Live-trigger evaluation runs only after a short pause in typing, not on
    /// the keystroke itself. Converting mid-burst raced the user's next key:
    /// by the time our backspaces landed another character was on screen, the
    /// delete count was stale, and letters were eaten. The debounce also cuts
    /// per-keystroke scoring work to (at most) one evaluation per pause.
    /// `editGeneration` guards staleness: ANY later event bumps it, so a
    /// pending evaluation after more typing / navigation / focus change no-ops.
    private var liveEvalWork: DispatchWorkItem?
    private static let liveEvalDebounce: TimeInterval = 0.25

    private func scheduleLiveEvaluation() {
        liveEvalWork?.cancel()
        let generation = editGeneration
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.liveEvalWork = nil
            // Re-check the toggles: the user may have disabled auto-switch (or
            // flipped the trigger) inside the debounce window — a conversion
            // must not fire after the feature was turned off.
            guard self.editGeneration == generation,
                  self.isActive, self.settings.autoSwitchEnabled,
                  self.settings.trigger == .live else { return }
            self.evaluateCurrentWord(final: false)
        }
        liveEvalWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.liveEvalDebounce, execute: work)
    }

    private func evaluateCurrentWord(final: Bool, delimiter: Character? = nil,
                                     delimiterStroke: KeyStroke? = nil) {
        let strokes = buffer.current
        guard strokes.count >= 2 else { return }
        guard let sourceLayoutID = buffer.layoutID,
              let source = layouts.first(where: { $0.id == sourceLayoutID }) else { return }

        let asTyped = KeyTranslator.shared.interpret(strokes, layout: source)
        guard asTyped.contains(where: { $0.isLetter }) else { return }
        if buffer.isVetoed(asTyped) { return }

        guard let decision = Decider.decide(
            strokes: strokes,
            source: source,
            candidates: layouts,
            sensitivity: settings.sensitivity,
            minWordLength: settings.minWordLength,
            isCompleteWord: final
        ) else { return }

        // If the local decision is confident, act. The delimiter keyDown that
        // triggered a final eval reaches the app BEFORE anything we synthesize:
        // the listen-only tap cannot hold it back, and our events enter the
        // pipeline at the HID tap, behind it. So the word AND its delimiter
        // are on screen when our backspaces land — delete and re-type both.
        if decision.confident {
            apply(decision, context: final ? .finalCurrent : .liveCurrent,
                  reemitDelimiter: delimiter, delimiterStroke: delimiterStroke)
        } else if settings.aiEnabled, final {
            consultAI(strokes: strokes, source: source, fallback: decision)
        }
    }

    /// Which on-screen word a conversion replaces — determines the buffer
    /// bookkeeping after the injection.
    private enum ApplyContext {
        /// The in-progress word, converted at its terminating delimiter; the
        /// caller completes the buffer right after.
        case finalCurrent
        /// The in-progress word, converted mid-typing (live trigger or manual
        /// hotkey mid-word). The buffer keeps accumulating the SAME word in
        /// the target layout, so its tail is not orphaned into a new word.
        case liveCurrent
        /// The last completed word (manual hotkey post-hoc, cloud verdict).
        case completedLast
    }

    /// Replace the on-screen wrong word with the corrected text.
    ///
    /// - Parameter reemitDelimiter: the delimiter that terminated the word,
    ///   if any. In every terminated-word path it is on screen (or in flight
    ///   ahead of our synthetic events) by the time the backspaces arrive, so
    ///   it must be deleted along with the word and re-typed after the
    ///   correction. Pass nil only for in-progress words.
    /// - Parameter delimiterStroke: when the delimiter is a punctuation key
    ///   (not a layout-invariant space), the stroke that produced it. Since we
    ///   are asserting the word was meant for `target`, the delimiter is
    ///   re-typed as the character that key produces under `target` — the ABC
    ///   '/' the user pressed becomes Russian '.'.
    private func apply(_ decision: Decider.Decision, context: ApplyContext,
                       reemitDelimiter: Character?,
                       delimiterStroke: KeyStroke? = nil, forced: Bool = false) {
        let target = decision.target
        let corrected = decision.correctedText
        let original = decision.originalText

        // On-screen the source glyph occupies one slot; re-type the target one.
        var reemit = reemitDelimiter
        if reemitDelimiter != nil, let stroke = delimiterStroke,
           let s = KeyTranslator.shared.translate(stroke, layout: target),
           s.count == 1, let c = s.first {
            reemit = c
        }

        // Retroactive short-word fix («yt описано»): a confident boundary
        // conversion is strong evidence the word BEFORE it, typed in the same
        // wrong layout, was wrong too — rewrite both in one injection.
        var retro: (deleteExtra: Int, prefix: String)?
        if context == .finalCurrent, !forced, !decision.viaAI {
            retro = retroFix(for: decision)
        }

        let deleteCount = (retro?.deleteExtra ?? 0) + original.count + (reemitDelimiter != nil ? 1 : 0)
        let replacement = (retro?.prefix ?? "") + corrected + (reemit.map(String.init) ?? "")
        TextInjector.shared.replaceText(
            deleteCount: deleteCount,
            with: replacement,
            switchToLayoutID: target.id
        )
        switch context {
        case .finalCurrent:
            buffer.noteConversionOfCurrentWord(targetLayoutID: target.id)
        case .liveCurrent:
            buffer.adoptLayout(target.id)
        case .completedLast:
            buffer.updateLastWordConverted(targetLayoutID: target.id)
        }
        lastConversionOriginal = original
        lastConversionAt = Date()
        // Only automatic conversions arm negative learning: a manual-forced one
        // being backspaced is the user changing their own mind, not the engine
        // being wrong.
        lastAutoConversion = forced ? nil : (original, decision.source.primaryLanguage ?? "")
        lastConversionProtected = {
            guard let lang = target.primaryLanguage, !lang.isEmpty else { return false }
            return LanguageScorer.shared.isCommonWord(corrected, language: lang)
        }()

        // Learn only from *trustworthy* corrections: a word the target
        // language's dictionary actually recognizes. Learning from every
        // conversion (incl. mistaken or manual-forced ones) would poison the
        // bigram model with garbage.
        if let lang = target.primaryLanguage,
           LanguageScorer.shared.isDictionaryWord(corrected, language: lang) {
            LanguageScorer.shared.learn(word: corrected, language: lang)
        }

        let record = ConversionRecord(
            from: original, to: corrected,
            fromLayout: decision.source.localizedName,
            toLayout: target.localizedName,
            viaAI: decision.viaAI
        )
        didConvert.send(record)
        notifyIfNeeded(record)
    }

    /// The «yt описано» fix: when a word converts confidently at its boundary,
    /// reconsider the word immediately before it. Convert it too — in the same
    /// injection — only under the strictest agreement: typed in the same
    /// (wrong) layout, finished with a single space, fresh, caret geometry
    /// intact (not detached), not vetoed, short enough that the length floor
    /// skipped it, and its twin in the SAME target direction is a word the
    /// engine trusts outright (curated frequent word or user-taught). Longer
    /// unconverted neighbors stayed for a reason — they are left alone.
    private func retroFix(for decision: Decider.Decision) -> (deleteExtra: Int, prefix: String)? {
        guard let prev = buffer.lastWord,
              !prev.converted, !prev.detached,
              prev.delimiter == " ",
              prev.layoutID == decision.source.id,
              Date().timeIntervalSince(prev.completedAt) < Self.retroFixWindow else { return nil }
        let translator = KeyTranslator.shared
        let prevOriginal = translator.interpret(prev.strokes, layout: decision.source)
        guard !prevOriginal.isEmpty, !buffer.isVetoed(prevOriginal) else { return nil }
        let twin = translator.interpret(prev.strokes, layout: decision.target)
        let twinLetters = twin.filter { $0.isLetter }.count
        guard twin != prevOriginal, twinLetters >= 1,
              twinLetters < settings.minWordLength else { return nil }
        let lang = decision.target.primaryLanguage ?? "en"
        let score = LanguageScorer.shared.score(twin, language: lang, completeWord: true)
        guard score.isCommonWord || score.isLearnedWord else { return nil }
        buffer.markLastWordRetroConverted(targetLayoutID: decision.target.id)
        return (prevOriginal.count + 1, twin + " ")
    }
    private static let retroFixWindow: TimeInterval = 30

    /// Entry point for asynchronous deciders (the cloud-AI layer). Only applies
    /// if the user has typed *nothing* since the request was fired (generation
    /// unchanged) and the completed word is still the last thing on screen —
    /// otherwise the caret has moved and a blind backspace-retype would corrupt
    /// unrelated text, so we no-op.
    func applyAIVerdictIfSafe(_ decision: Decider.Decision, capturedGeneration: Int) {
        guard capturedGeneration == editGeneration else {
            Log.info("AI verdict dropped: user kept typing (gen \(capturedGeneration)≠\(editGeneration))")
            return
        }
        // The completed word plus its delimiter are on screen (the sync path
        // already ran during word completion, so a completed word reaching here
        // means the buffer rolled over). Re-emit the delimiter we recorded.
        let delimiter = buffer.lastWord?.delimiter
        apply(decision, context: .completedLast, reemitDelimiter: delimiter)
    }

    private func notifyIfNeeded(_ record: ConversionRecord) {
        if settings.playSoundOnSwitch {
            NSSound(named: "Pop")?.play()
        }
        // Notification center handled by AppDelegate observer if enabled.
    }

    // MARK: - Manual conversion (hotkey)

    /// Convert the last typed word (or current) on demand, regardless of
    /// confidence. Used by the manual hotkey when auto-switch missed one.
    func manualConvertLastWord() {
        // Prefer the in-progress word; fall back to the last completed one —
        // including one the engine itself converted (its recorded layoutID is
        // the conversion target, so a second hotkey press toggles it back).
        let usingCurrent = !buffer.isEmpty
        let strokes = usingCurrent ? buffer.current : (buffer.lastWord?.strokes ?? [])
        let layoutID = usingCurrent ? buffer.layoutID : buffer.lastWord?.layoutID
        guard strokes.count >= 1,
              let layoutID,
              let source = layouts.first(where: { $0.id == layoutID }) else {
            // Nothing buffered — try converting the selection instead.
            manualConvertSelection()
            return
        }
        // Force a conversion to the best alternative even if not confident.
        guard let decision = Decider.decide(
            strokes: strokes, source: source, candidates: layouts,
            sensitivity: .aggressive, force: true
        ) else { return }

        // Don't fire when the best alternative is identical to what's typed —
        // that would delete and retype the same text for no reason.
        guard decision.correctedText != decision.originalText else {
            NSSound.beep()
            return
        }

        // If the word was already terminated (buffer rolled over), the delimiter
        // is on screen — delete and re-emit it around the correction.
        let reemit: Character? = usingCurrent ? nil : buffer.lastWord?.delimiter
        apply(decision, context: usingCurrent ? .liveCurrent : .completedLast,
              reemitDelimiter: reemit, forced: true)

        // Positive learning: the user explicitly asked for this word. After
        // LearnedStore.activationCount forced conversions it auto-converts on
        // its own — this is how the engine learns names, slang, and short
        // loanwords ("пэд") no built-in signal recognizes.
        if let lang = decision.target.primaryLanguage {
            LanguageScorer.shared.learnPositive(word: decision.correctedText, language: lang)
        }
    }

    /// Convert whatever text is currently selected (works even with no buffer,
    /// e.g. text pasted or typed before launch). Toggles between the two most
    /// likely layouts.
    func manualConvertSelection() {
        guard layouts.count >= 2 else { return }
        guard let current = LayoutManager.shared.currentLayout() else { return }
        // Convert from the current layout to the "other" primary layout.
        let target = layouts.first { $0.id != current.id } ?? current
        TextInjector.shared.convertSelection(from: current, to: target) { ok in
            if ok { Log.info("Converted selection \(current.id) → \(target.id)") }
        }
    }
}
