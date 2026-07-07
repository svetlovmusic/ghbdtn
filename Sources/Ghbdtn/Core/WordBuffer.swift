import Foundation

/// Accumulates the keystrokes of the word currently being typed, plus the
/// last completed word (so a hotkey can convert it after the fact).
///
/// The buffer only ever holds physical keystrokes — *what keys were pressed* —
/// never the interpreted text. Interpretation happens on demand per layout.
final class WordBuffer {
    /// Keystrokes of the word in progress.
    private(set) var current: [KeyStroke] = []
    /// The layout that was active while `current` was being typed.
    private(set) var layoutID: String?

    /// The last finished word (completed by space/punctuation) — kept so the
    /// manual hotkey can still convert it. The delimiter character is stored
    /// too so it can be re-emitted after a post-hoc conversion.
    private(set) var lastWord: [KeyStroke] = []
    private(set) var lastWordLayoutID: String?
    private(set) var lastWordDelimiterChar: Character?

    /// Words the user "took back" → (rejection count, last time). A word is only
    /// vetoed after TWO rejections (matching LearnedStore.activationCount): a
    /// single backspace right after a conversion is usually just editing — or
    /// demoing — it, not a rejection. One-shot vetoing wrongly killed a correct
    /// conversion after a single backspace and left it dead in every window for
    /// the rest of the session (issue #2). Counts expire after `vetoTTL` and the
    /// map is capped, so a long-running session can't accumulate.
    private var vetoed: [String: (count: Int, at: Date)] = [:]
    private static let vetoTTL: TimeInterval = 20 * 60
    private static let vetoThreshold = 2
    private static let vetoCap = 500

    var isEmpty: Bool { current.isEmpty }
    var count: Int { current.count }

    func append(_ stroke: KeyStroke, activeLayoutID: String) {
        if current.isEmpty {
            layoutID = activeLayoutID
        } else if layoutID != activeLayoutID {
            // Layout changed mid-word (user switched manually) — restart.
            hardReset()
            layoutID = activeLayoutID
        }
        current.append(stroke)
    }

    /// Word finished by a delimiter (space, punctuation, return).
    func complete(delimiterChar: Character?) {
        if !current.isEmpty {
            lastWord = current
            lastWordLayoutID = layoutID
            lastWordDelimiterChar = delimiterChar
        }
        current = []
        layoutID = nil
    }

    func backspace() {
        if !current.isEmpty {
            current.removeLast()
        }
    }

    /// Reset the in-progress word (mouse click, arrows, app switch, cmd-shortcut).
    /// The last completed word survives soft resets so hotkey conversion still works.
    func softReset() {
        current = []
        layoutID = nil
    }

    /// Full reset including the completed-word memory (app switch, secure input).
    func hardReset() {
        softReset()
        lastWord = []
        lastWordLayoutID = nil
        lastWordDelimiterChar = nil
    }

    /// After the engine replaces a word, the buffer must forget it so the
    /// replacement keystrokes we synthesize don't get re-evaluated.
    func consumeLastWord() {
        lastWord = []
        lastWordLayoutID = nil
        lastWordDelimiterChar = nil
    }

    // MARK: - Veto memory

    func veto(_ word: String) {
        let key = word.lowercased()
        let now = Date()
        // Carry a prior count forward only if it hasn't expired, so stale
        // rejections don't accumulate toward the threshold across a long session.
        let prior = vetoed[key].map { now.timeIntervalSince($0.at) <= Self.vetoTTL ? $0.count : 0 } ?? 0
        vetoed[key] = (prior + 1, now)
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
