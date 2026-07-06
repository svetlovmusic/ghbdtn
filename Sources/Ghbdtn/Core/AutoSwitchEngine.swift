import Foundation
import AppKit
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
    /// that backspacing it feeds persistent negative learning: the as-typed word
    /// plus its source language, i.e. "the user rejected converting this".
    private var lastAutoConversion: (text: String, sourceLang: String)?

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
            // any in-flight async (AI) correction so it can't inject there.
            self?.editGeneration &+= 1
            self?.buffer.hardReset()
        }
        frontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier

        // Rebuild layout list when the user enables/disables layouts.
        layoutObserver = LayoutManager.shared.observeLayoutChanges { [weak self] in
            guard let self else { return }
            self.editGeneration &+= 1
            if !LayoutManager.shared.isProgrammaticSwitch {
                self.buffer.hardReset()
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

        case .navigationOrClick:
            buffer.softReset()

        case .backspace:
            // A backspace immediately after an auto-conversion is the user
            // rejecting it. Veto that exact token so it isn't auto-converted
            // again this session (the safe direction: at worst we skip a
            // conversion they wanted, recoverable via the manual hotkey).
            if let rejected = lastConversionOriginal {
                buffer.veto(rejected)
            }
            // Persistent negative learning: repeatedly rejecting the same auto
            // conversion (≥ LearnedStore.activationCount) makes the engine keep
            // that word for good. One rejection only vetoes it this session.
            if let auto = lastAutoConversion, !auto.sourceLang.isEmpty {
                LanguageScorer.shared.learnNegative(word: auto.text, language: auto.sourceLang)
            }
            buffer.backspace()
            lastConversionOriginal = nil
            lastAutoConversion = nil

        case let .key(stroke, hasCommandLikeModifiers):
            if hasCommandLikeModifiers {
                // ⌘X etc. — treat as boundary, don't record the key.
                buffer.softReset()
                return
            }
            guard let active = LayoutManager.shared.currentLayout() else { return }
            // Sentence punctuation ends the word — but only when the key
            // carries no letter in any enabled layout. Keys like ';' or ','
            // ARE letters elsewhere (ж, б in Russian) and must stay in the
            // buffer, otherwise wrong-layout words like ";bpym" fall apart.
            if let punct = delimiterCharacter(for: stroke, activeLayout: active) {
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
                evaluateCurrentWord(final: false)
            }

        case let .wordDelimiter(_, char):
            // Evaluate the word we just finished, then roll the buffer. Only a
            // space is re-emitted: it reliably inserts one character in every
            // context. Return and Tab carry action semantics (submit a chat
            // message, run a shell line, move focus) about as often as they
            // insert a character, and we can't tell which — re-typing them
            // would execute/submit the corrected word or over-delete adjacent
            // text. So we leave them untouched (delete the word only): safe
            // everywhere, at the cost that a word finished with Enter in a
            // multi-line editor can still keep its first letter. Space is the
            // overwhelmingly common terminator and is fully fixed.
            evaluateCurrentWord(final: true, delimiter: char == " " ? char : nil)
            buffer.complete(delimiterChar: char)
        }
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
            apply(decision, reemitDelimiter: delimiter, delimiterStroke: delimiterStroke)
        } else if settings.aiEnabled, final {
            consultAI(strokes: strokes, source: source, fallback: decision)
        }
    }

    /// Replace the on-screen wrong word with the corrected text.
    ///
    /// - Parameter reemitDelimiter: the delimiter that terminated the word,
    ///   if any. In every terminated-word path it is on screen (or in flight
    ///   ahead of our synthetic events) by the time the backspaces arrive, so
    ///   it must be deleted along with the word and re-typed after the
    ///   correction. Pass nil only for the live path, where the word has no
    ///   delimiter yet.
    /// - Parameter delimiterStroke: when the delimiter is a punctuation key
    ///   (not a layout-invariant space), the stroke that produced it. Since we
    ///   are asserting the word was meant for `target`, the delimiter is
    ///   re-typed as the character that key produces under `target` — the ABC
    ///   '/' the user pressed becomes Russian '.'.
    private func apply(_ decision: Decider.Decision, reemitDelimiter: Character?,
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
        let deleteCount = original.count + (reemitDelimiter != nil ? 1 : 0)
        let replacement = corrected + (reemit.map(String.init) ?? "")
        TextInjector.shared.replaceText(
            deleteCount: deleteCount,
            with: replacement,
            switchToLayoutID: target.id
        )
        buffer.consumeLastWord()
        buffer.softReset()
        lastConversionOriginal = original
        // Only automatic conversions arm negative learning: a manual-forced one
        // being backspaced is the user changing their own mind, not the engine
        // being wrong.
        lastAutoConversion = forced ? nil : (original, decision.source.primaryLanguage ?? "")

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
        let delimiter = buffer.lastWordDelimiterChar
        apply(decision, reemitDelimiter: delimiter)
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
        // Prefer the in-progress word; fall back to the last completed one.
        let strokes = buffer.isEmpty ? buffer.lastWord : buffer.current
        let layoutID = buffer.isEmpty ? buffer.lastWordLayoutID : buffer.layoutID
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
        let reemit: Character? = buffer.isEmpty ? buffer.lastWordDelimiterChar : nil
        apply(decision, reemitDelimiter: reemit, forced: true)

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
