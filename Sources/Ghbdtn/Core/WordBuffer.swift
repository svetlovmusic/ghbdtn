import Foundation

/// Accumulates the keystrokes of the word currently being typed, plus the
/// last completed word (so a hotkey can convert it after the fact).
///
/// The buffer only ever holds physical keystrokes — *what keys were pressed* —
/// never the interpreted text. Interpretation happens on demand per layout.
final class WordBuffer {
    /// A finished word: its physical keystrokes plus everything needed to
    /// convert it after the fact — the layout its on-screen text is currently
    /// in (updated when the engine converts it), the delimiter that closed it,
    /// and safety flags for the retroactive short-word fix.
    struct CompletedWord {
        var strokes: [KeyStroke]
        /// Layout the on-screen text is in NOW: the typing layout, or the
        /// conversion target after the engine converted the word.
        var layoutID: String
        var delimiter: Character?
        var converted: Bool
        /// The caret may have moved since (click/arrows/⌘-shortcut): the word
        /// is no longer guaranteed to sit just left of the caret, so blind
        /// backspace-retype fixes (retro-conversion) must not touch it. The
        /// manual hotkey ignores this — the user sees where their caret is.
        var detached = false
        let completedAt = Date()
    }

    /// Keystrokes of the word in progress.
    private(set) var current: [KeyStroke] = []
    /// The layout that was active while `current` was being typed.
    private(set) var layoutID: String?

    /// The last finished word (completed by space/punctuation) — kept so the
    /// manual hotkey can convert it post-hoc and the retro short-word fix can
    /// reconsider it.
    private(set) var lastWord: CompletedWord?

    /// Set by the engine when it converts the in-progress word right before a
    /// delimiter completes it; `complete` consumes it so the finished word is
    /// recorded in its converted layout.
    private var pendingConversionLayoutID: String?

    /// Words the user "took back" → (rejection count, last time). A word is only
    /// vetoed after TWO rejections (matching LearnedStore.activationCount): a
    /// single backspace right after a conversion is usually just editing — or
    /// demoing — it, not a rejection. One-shot vetoing wrongly killed a correct
    /// conversion after a single backspace and left it dead in every window for
    /// the rest of the session (issue #2). Counts expire after `vetoTTL` and the
    /// map is capped, so a long-running session can't accumulate.
    private var vetoed: [String: (count: Int, at: Date)] = [:]
    private static let vetoTTL: TimeInterval = 20 * 60
    static let vetoThreshold = 2
    private static let vetoCap = 500

    var isEmpty: Bool { current.isEmpty }
    var count: Int { current.count }

    func append(_ stroke: KeyStroke, activeLayoutID: String) {
        if current.isEmpty {
            layoutID = activeLayoutID
        } else if layoutID != activeLayoutID {
            // Layout changed mid-word (user switched manually) — restart the
            // in-progress word only. The completed words are still on screen
            // untouched, so their history (hotkey conversion) must survive.
            current = []
            pendingConversionLayoutID = nil
            layoutID = activeLayoutID
        }
        current.append(stroke)
    }

    /// Word finished by a delimiter (space, punctuation, return).
    func complete(delimiterChar: Character?) {
        if !current.isEmpty, let layoutID {
            lastWord = CompletedWord(
                strokes: current,
                layoutID: pendingConversionLayoutID ?? layoutID,
                delimiter: delimiterChar,
                converted: pendingConversionLayoutID != nil
            )
        } else {
            // A bare delimiter (second space, punctuation right after a
            // completed word) put a character on screen between lastWord's
            // recorded delimiter and the caret — the retro fix's deleteCount
            // would no longer match the screen ("yt␣␣word" ate a letter), so
            // blind fixes must keep their hands off. The manual hotkey is
            // unaffected: it deletes word+delimiter only.
            lastWord?.detached = true
        }
        pendingConversionLayoutID = nil
        current = []
        layoutID = nil
    }

    func backspace() {
        if !current.isEmpty {
            current.removeLast()
        } else {
            // The backspace ate the completed word's delimiter (or unrelated
            // text left of the caret) — lastWord's recorded on-screen geometry
            // no longer holds, so retro fixes must not touch it.
            lastWord?.detached = true
        }
    }

    /// Reset the in-progress word (mouse click, arrows, app switch, cmd-shortcut).
    /// The last completed word survives soft resets so hotkey conversion still
    /// works, but it is marked detached: the caret has (or may have) moved, so
    /// automatic blind fixes must not touch it anymore.
    func softReset() {
        current = []
        layoutID = nil
        pendingConversionLayoutID = nil
        lastWord?.detached = true
    }

    /// Full reset including the completed-word memory (app switch, secure input).
    func hardReset() {
        softReset()
        lastWord = nil
    }

    // MARK: - Conversion bookkeeping (engine calls these when it edits the screen)

    /// The in-progress word is being converted and will be completed by the
    /// delimiter that triggered the evaluation; record the target layout so
    /// `complete` stores the word as already-converted.
    func noteConversionOfCurrentWord(targetLayoutID: String) {
        pendingConversionLayoutID = targetLayoutID
    }

    /// A live (mid-word) conversion replaced the on-screen prefix and switched
    /// the system layout; the SAME physical strokes now read in the target
    /// layout, so the word keeps accumulating instead of orphaning its tail.
    /// Also arms the pending-conversion mark so the word is recorded as
    /// converted when a delimiter eventually completes it.
    func adoptLayout(_ id: String) {
        guard !current.isEmpty else { return }
        layoutID = id
        pendingConversionLayoutID = id
    }

    /// The engine converted the last COMPLETED word (manual hotkey / cloud
    /// verdict): its on-screen text is now in `targetLayoutID`.
    func updateLastWordConverted(targetLayoutID: String) {
        lastWord?.layoutID = targetLayoutID
        lastWord?.converted = true
    }

    /// The retro short-word fix rewrote the last completed word along with the
    /// current conversion (see AutoSwitchEngine.retroFix).
    func markLastWordRetroConverted(targetLayoutID: String) {
        updateLastWordConverted(targetLayoutID: targetLayoutID)
    }

    // MARK: - Veto memory

    /// - Parameter weight: how many rejections this event is worth. An
    ///   explicit ⌘Z or delete-and-retype is unambiguous, so the engine passes
    ///   `vetoThreshold` to veto the token for the session in one shot.
    func veto(_ word: String, weight: Int = 1) {
        let key = word.lowercased()
        let now = Date()
        // Carry a prior count forward only if it hasn't expired, so stale
        // rejections don't accumulate toward the threshold across a long session.
        let prior = vetoed[key].map { now.timeIntervalSince($0.at) <= Self.vetoTTL ? $0.count : 0 } ?? 0
        vetoed[key] = (prior + weight, now)
        if vetoed.count > Self.vetoCap { pruneVetoed(now: now) }
    }

    func isVetoed(_ word: String) -> Bool {
        let key = word.lowercased()
        guard let entry = vetoed[key] else { return false }
        guard Date().timeIntervalSince(entry.at) <= Self.vetoTTL else {
            vetoed.removeValue(forKey: key)   // expired — let it convert again
            return false
        }
        return entry.count >= Self.vetoThreshold
    }

    /// Drop expired entries; if still over the cap, evict the oldest.
    private func pruneVetoed(now: Date) {
        vetoed = vetoed.filter { now.timeIntervalSince($0.value.at) <= Self.vetoTTL }
        if vetoed.count > Self.vetoCap {
            let overflow = vetoed.count - Self.vetoCap
            for key in vetoed.sorted(by: { $0.value.at < $1.value.at }).prefix(overflow).map(\.key) {
                vetoed.removeValue(forKey: key)
            }
        }
    }
}
