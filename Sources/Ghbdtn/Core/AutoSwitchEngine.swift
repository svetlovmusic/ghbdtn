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
            buffer.backspace()
            lastConversionOriginal = nil

        case let .key(stroke, hasCommandLikeModifiers):
            if hasCommandLikeModifiers {
                // ⌘X etc. — treat as boundary, don't record the key.
                buffer.softReset()
                return
            }
            guard let active = LayoutManager.shared.currentLayout() else { return }
            buffer.append(stroke, activeLayoutID: active.id)
            lastConversionOriginal = nil
            if settings.trigger == .live {
                evaluateCurrentWord(final: false)
            }

        case let .wordDelimiter(_, char):
            // Evaluate the word we just finished, then roll the buffer.
            evaluateCurrentWord(final: true)
            buffer.complete(delimiterChar: char)
        }
    }

    // MARK: - Decision

    private func evaluateCurrentWord(final: Bool) {
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
            isCompleteWord: final
        ) else { return }

        // If the local decision is confident, act. At final-eval time the
        // delimiter keyDown is still passing through the listen-only tap and
        // has not reached the app yet, so nothing extra is on screen.
        if decision.confident {
            apply(decision, reemitDelimiter: nil)
        } else if settings.aiEnabled, final {
            consultAI(strokes: strokes, source: source, fallback: decision)
        }
    }

    /// Replace the on-screen wrong word with the corrected text.
    ///
    /// - Parameter reemitDelimiter: when the word was already terminated on
    ///   screen (post-hoc conversions: manual hotkey, async AI), pass the
    ///   delimiter character so it is deleted along with the word and re-typed
    ///   after the correction. Pass nil for the live path where the delimiter
    ///   has not landed yet.
    private func apply(_ decision: Decider.Decision, reemitDelimiter: Character?) {
        let target = decision.target
        let corrected = decision.correctedText
        let original = decision.originalText

        let deleteCount = original.count + (reemitDelimiter != nil ? 1 : 0)
        let replacement = corrected + (reemitDelimiter.map(String.init) ?? "")
        TextInjector.shared.replaceText(
            deleteCount: deleteCount,
            with: replacement,
            switchToLayoutID: target.id
        )
        buffer.consumeLastWord()
        buffer.softReset()
        lastConversionOriginal = original

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
        apply(decision, reemitDelimiter: reemit)
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
