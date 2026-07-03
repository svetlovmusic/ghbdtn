import Foundation

/// Character 4-gram language model with interpolated Kneser–Ney smoothing,
/// trained offline on real running text (tools/train_ngram.py) and serialized
/// ARPA-style: per-order probability tables plus per-context backoff weights,
/// quantized to a byte each. Words are padded as `^^^word$`.
///
/// The model answers "how plausible is this string as (part of) a word of the
/// language" for out-of-vocabulary input — names, slang, rare words, word
/// prefixes — that the spellchecker and curated lists can't judge. Raw
/// log-probabilities are NOT comparable across languages (different corpora,
/// alphabet sizes), so each model carries calibration quantiles: the
/// distribution of per-character avg logP over real words of its language.
/// `percentile(of:)` maps a score onto that distribution, giving a value that
/// IS comparable across languages.
///
/// Lookup is a binary search over sorted UInt32 keys (6 bits per character),
/// a few hundred nanoseconds per n-gram — safe to run on every keystroke.
final class NgramModel {
    let language: String
    let sizeBytes: Int

    /// Words shorter than this can't be judged reliably.
    static let minCompleteLength = 4
    static let minPrefixLength = 5

    private static let quantileCount = 101
    private static let order = 4
    private static let quantScale = 12.0

    private var charIndex: [Character: UInt32] = [:]
    private let startIndex: UInt32  // '^'
    private let endIndex: UInt32    // '$'

    // Per order 1...4: sorted keys and quantized values. `bows` is empty for
    // the highest order (no backoff from it).
    private var keys: [[UInt32]] = []
    private var probs: [[UInt8]] = []
    private var bows: [[UInt8]] = []

    private var quantComplete: [Double] = []
    private var quantPrefix: [Double] = []

    private let lnFloor = -255.0 / NgramModel.quantScale

    // MARK: - Loading

    init?(contentsOf url: URL) {
        guard let data = try? Data(contentsOf: url) else { return nil }
        sizeBytes = data.count

        var offset = 0
        func take(_ n: Int) -> Data? {
            guard offset + n <= data.count else { return nil }
            defer { offset += n }
            return data.subdata(in: (data.startIndex + offset)..<(data.startIndex + offset + n))
        }
        func u8() -> Int? { take(1).map { Int($0[$0.startIndex]) } }
        func u16() -> UInt16? {
            take(2).map { d in d.withUnsafeBytes { $0.loadUnaligned(as: UInt16.self).littleEndian } }
        }
        func u32() -> UInt32? {
            take(4).map { d in d.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian } }
        }

        guard let magic = take(4), magic.elementsEqual("GNG1".utf8) else { return nil }
        guard let langBytes = take(2), let lang = String(data: langBytes, encoding: .ascii) else { return nil }
        language = lang

        guard let alphaCount = u8(), alphaCount > 2 else { return nil }
        var start: UInt32?
        var end: UInt32?
        for i in 0..<alphaCount {
            guard let unit = u16(), let scalar = Unicode.Scalar(UInt32(unit)) else { return nil }
            let ch = Character(scalar)
            charIndex[ch] = UInt32(i)
            if ch == "^" { start = UInt32(i) }
            if ch == "$" { end = UInt32(i) }
        }
        guard let start, let end else { return nil }
        startIndex = start
        endIndex = end

        func quantiles() -> [Double]? {
            var result: [Double] = []
            result.reserveCapacity(Self.quantileCount)
            for _ in 0..<Self.quantileCount {
                guard let bits = u32() else { return nil }
                result.append(Double(Float(bitPattern: bits)))
            }
            // The table must be non-decreasing for binary search to be valid.
            guard zip(result, result.dropFirst()).allSatisfy({ $0 <= $1 }) else { return nil }
            return result
        }
        guard let qc = quantiles(), let qp = quantiles() else { return nil }
        quantComplete = qc
        quantPrefix = qp

        for order in 1...Self.order {
            guard let count32 = u32() else { return nil }
            let count = Int(count32)
            guard let keyData = take(count * 4) else { return nil }
            var orderKeys = [UInt32](repeating: 0, count: count)
            keyData.withUnsafeBytes { raw in
                for i in 0..<count {
                    orderKeys[i] = raw.loadUnaligned(fromByteOffset: i * 4, as: UInt32.self).littleEndian
                }
            }
            // Sorted keys are the contract for binary search — verify, don't trust.
            guard zip(orderKeys, orderKeys.dropFirst()).allSatisfy({ $0 < $1 }) else { return nil }

            if order < Self.order {
                guard let vals = take(count * 2) else { return nil }
                var p = [UInt8](repeating: 0, count: count)
                var b = [UInt8](repeating: 0, count: count)
                vals.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                    for i in 0..<count {
                        p[i] = raw[i * 2]
                        b[i] = raw[i * 2 + 1]
                    }
                }
                keys.append(orderKeys)
                probs.append(p)
                bows.append(b)
            } else {
                guard let vals = take(count) else { return nil }
                keys.append(orderKeys)
                probs.append([UInt8](vals))
                bows.append([])
            }
        }
        guard offset == data.count else { return nil }
    }

    // MARK: - Scoring

    /// Percentile of the string's per-character avg logP among real words of
    /// the language (0 = worse than any real word, 1 = better than all).
    /// `complete: false` scores the string as a word prefix (no end marker,
    /// prefix calibration table). Returns nil when the string is too short or
    /// contains characters outside the model's alphabet.
    func percentile(of word: String, complete: Bool) -> Double? {
        guard let avg = averageLogProb(word, complete: complete) else { return nil }
        return percentile(avg, in: complete ? quantComplete : quantPrefix)
    }

    /// True when the string has characters the language's alphabet doesn't
    /// contain — by definition it cannot be a word of this language.
    func hasForeignCharacters(_ word: String) -> Bool {
        for ch in word.lowercased() where ch != "^" && ch != "$" {
            if charIndex[ch] == nil { return true }
        }
        return false
    }

    /// Per-transition average ln P over the padded word (`^^^word$`, or
    /// `^^^word` for prefixes). Mirrors BinModel.avg_logp in tools/ngram_lm.py.
    func averageLogProb(_ word: String, complete: Bool) -> Double? {
        let lower = word.lowercased()
        var indices: [UInt32] = []
        indices.reserveCapacity(lower.count)
        for ch in lower {
            // Literal '^'/'$' would collide with the boundary markers.
            guard ch != "^", ch != "$", let idx = charIndex[ch] else { return nil }
            indices.append(idx)
        }
        let minLen = complete ? Self.minCompleteLength : Self.minPrefixLength
        guard indices.count >= minLen else { return nil }

        // Rolling 18-bit context of the 3 preceding character indices.
        var ctx = (startIndex << 12) | (startIndex << 6) | startIndex
        var total = 0.0
        for idx in indices {
            total += conditionalLogProb(context: ctx, char: idx)
            ctx = ((ctx << 6) | idx) & 0x3FFFF
        }
        var n = indices.count
        if complete {
            total += conditionalLogProb(context: ctx, char: endIndex)
            n += 1
        }
        return total / Double(n)
    }

    /// ln P(char | 3-char context) via the standard ARPA backoff chain:
    /// longest matching n-gram wins; each missed order adds that context's
    /// backoff weight.
    private func conditionalLogProb(context ctx: UInt32, char: UInt32) -> Double {
        if let i = find((ctx << 6) | char, order: 4) {
            return lnProb(order: 4, at: i)
        }
        var acc = 0.0
        if let i = find(ctx, order: 3) { acc += lnBow(order: 3, at: i) }
        let ctx2 = ctx & 0xFFF
        if let i = find((ctx2 << 6) | char, order: 3) {
            return acc + lnProb(order: 3, at: i)
        }
        if let i = find(ctx2, order: 2) { acc += lnBow(order: 2, at: i) }
        let ctx1 = ctx & 0x3F
        if let i = find((ctx1 << 6) | char, order: 2) {
            return acc + lnProb(order: 2, at: i)
        }
        if let i = find(ctx1, order: 1) { acc += lnBow(order: 1, at: i) }
        if let i = find(char, order: 1) {
            return acc + lnProb(order: 1, at: i)
        }
        return acc + lnFloor
    }

    @inline(__always)
    private func lnProb(order: Int, at i: Int) -> Double {
        -Double(probs[order - 1][i]) / Self.quantScale
    }

    @inline(__always)
    private func lnBow(order: Int, at i: Int) -> Double {
        -Double(bows[order - 1][i]) / Self.quantScale
    }

    @inline(__always)
    private func find(_ key: UInt32, order: Int) -> Int? {
        let arr = keys[order - 1]
        var lo = 0
        var hi = arr.count - 1
        while lo <= hi {
            let mid = (lo + hi) >> 1
            let v = arr[mid]
            if v == key { return mid }
            if v < key { lo = mid + 1 } else { hi = mid - 1 }
        }
        return nil
    }

    /// Map an avg logP onto the calibration quantiles by linear interpolation.
    private func percentile(_ value: Double, in table: [Double]) -> Double {
        guard let first = table.first, let last = table.last else { return 0 }
        if value <= first { return 0 }
        if value >= last { return 1 }
        var lo = 0
        var hi = table.count - 1
        while hi - lo > 1 {
            let mid = (lo + hi) >> 1
            if table[mid] <= value { lo = mid } else { hi = mid }
        }
        let span = table[hi] - table[lo]
        let frac = span > 0 ? (value - table[lo]) / span : 0
        return (Double(lo) + frac) / Double(table.count - 1)
    }

    // MARK: - Model discovery

    /// Locate `ngram-<lang>.bin`, checking the app bundle's copied SwiftPM
    /// resource bundle, the executable's directory (plain `swift build` runs,
    /// e.g. the self-test), and finally Application Support (user-supplied
    /// models for extra languages).
    static func locateModel(language: String) -> URL? {
        let file = "ngram-\(language.lowercased()).bin"
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("Ghbdtn_Ghbdtn.bundle/Models/\(file)"))
        }
        if let exe = Bundle.main.executableURL {
            candidates.append(exe.deletingLastPathComponent()
                .appendingPathComponent("Ghbdtn_Ghbdtn.bundle/Models/\(file)"))
        }
        if let support = FileManager.default.urls(for: .applicationSupportDirectory,
                                                  in: .userDomainMask).first {
            candidates.append(support.appendingPathComponent("Ghbdtn/Models/\(file)"))
        }
        return candidates.first { FileManager.default.fileExists(atPath: $0.path) }
    }
}
