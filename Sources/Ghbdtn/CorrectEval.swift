import Foundation

/// Headless evaluation harness for the on-demand text-correction ("recovery")
/// backend: `ghbdtn --correct-eval`. Reads a list of deliberately-mangled
/// inputs, runs each through the configured cloud model, and prints original
/// vs. corrected text plus how much changed — so you can eyeball *fix-rate* vs.
/// *over-edit-rate* before committing to a model or wiring it into the app.
///
/// This is a validation probe, not a product surface. Config (key + model) is
/// read from `tools/correct-eval/config.json` (gitignored) or the environment;
/// examples from `tools/correct-eval/examples.txt`. Model can be overridden with
/// `--model <name>` so you can compare, e.g., gpt-4.1-mini vs. a flagship on the
/// same set without editing files.
enum CorrectEval {
    struct Config {
        var apiKey: String
        var model: String
        var baseURL: String
    }

    /// Bridges the async provider to the synchronous CLI entry point in main.swift.
    /// The result crosses the concurrency boundary via a reference box; the
    /// semaphore provides the happens-before so the read is safe.
    static func runBlocking() -> Bool {
        final class Box: @unchecked Sendable { var value = false }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task { box.value = await run(); sem.signal() }
        sem.wait()
        return box.value
    }

    static func run() async -> Bool {
        let cfg = loadConfig()
        guard !cfg.apiKey.isEmpty else {
            print("""
            ⚠️  No API key found. Do one of:
                • copy tools/correct-eval/config.example.json → config.json and paste your key into "apiKey"
                • or export OPENAI_API_KEY=sk-...
            """)
            return false
        }
        let examples = loadExamples()
        guard !examples.isEmpty else {
            print("⚠️  No examples. Put one mangled line per row in tools/correct-eval/examples.txt")
            return false
        }

        let provider = OpenAICompatibleProvider(baseURL: cfg.baseURL, apiKey: cfg.apiKey, model: cfg.model)

        print("── correct-eval ──")
        print("model:   \(cfg.model)")
        print("baseURL: \(cfg.baseURL)")
        print("cases:   \(examples.count)\n")

        var failures = 0
        var totalPct = 0.0
        for (i, input) in examples.enumerated() {
            do {
                let started = DispatchTime.now()
                let corrected = try await provider.correct(input, systemPrompt: Settings.defaultCorrectionPrompt)
                let ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
                let dist = levenshtein(Array(input), Array(corrected))
                let pct = input.isEmpty ? 0 : Double(dist) / Double(input.count) * 100
                totalPct += pct
                let flag = corrected == input
                    ? "· unchanged"
                    : String(format: "Δ %d chars (%.1f%% of input)", dist, pct)
                print("[\(i + 1)] \(flag), \(Int(ms.rounded())) ms")
                print("    ORIG: \(input)")
                print("    FIX : \(corrected)\n")
            } catch {
                failures += 1
                print("[\(i + 1)] ❌ error: \(error)")
                print("    ORIG: \(input)\n")
            }
        }
        let scored = max(examples.count - failures, 1)
        let avg = totalPct / Double(scored)
        print(String(format: "done — %d/%d ok, avg edit %.1f%% of input length",
                     examples.count - failures, examples.count, avg))
        print("hint: a big Δ on an already-clean line = over-edit; scan the FIX lines for wrong changes.")
        return failures == 0
    }

    // MARK: - Config / examples

    private static func loadConfig() -> Config {
        let env = ProcessInfo.processInfo.environment
        var apiKey = env["OPENAI_API_KEY"] ?? ""
        var model = env["CORRECT_EVAL_MODEL"] ?? ""
        var baseURL = env["OPENAI_BASE_URL"] ?? ""

        let path = env["CORRECT_EVAL_CONFIG"] ?? "tools/correct-eval/config.json"
        if let data = FileManager.default.contents(atPath: path),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if apiKey.isEmpty { apiKey = json["apiKey"] as? String ?? "" }
            if model.isEmpty { model = json["model"] as? String ?? "" }
            if baseURL.isEmpty { baseURL = json["baseURL"] as? String ?? "" }
        }
        // Deliberately NO Keychain fallback: this eval harness must never read
        // the GUI's stored API key and send it to an environment-supplied URL.
        // Pass a key explicitly via OPENAI_API_KEY or the (gitignored) config.

        // `--model <name>` wins over everything, for quick A/B on the same set.
        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--model"), idx + 1 < args.count {
            model = args[idx + 1]
        }
        if model.isEmpty { model = "gpt-4.1-mini" }
        if baseURL.isEmpty { baseURL = "https://api.openai.com/v1" }
        return Config(apiKey: apiKey, model: model, baseURL: baseURL)
    }

    private static func loadExamples() -> [String] {
        let path = ProcessInfo.processInfo.environment["CORRECT_EVAL_EXAMPLES"]
            ?? "tools/correct-eval/examples.txt"
        guard let data = FileManager.default.contents(atPath: path),
              let text = String(data: data, encoding: .utf8) else { return [] }
        return text
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
    }

    // MARK: - Levenshtein (a rough "how much changed" signal, over Characters)

    private static func levenshtein(_ a: [Character], _ b: [Character]) -> Int {
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count)
        var cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = a[i - 1] == b[j - 1]
                    ? prev[j - 1]
                    : Swift.min(prev[j - 1], prev[j], cur[j - 1]) + 1
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }
}
