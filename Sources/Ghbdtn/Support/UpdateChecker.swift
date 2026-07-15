import Foundation
import AppKit
import Combine

/// Checks GitHub Releases for a newer version and, on request, self-updates:
/// downloads the release .dmg, verifies the staged app, swaps the installed
/// bundle and relaunches.
///
/// Polling: one check ~a minute after launch, then every 24 h (the desktop
/// de-facto standard — releases are weekly at best, and the unauthenticated
/// GitHub API allows 60 req/h, so daily is far below any limit). Requests are
/// conditional (ETag → 304), failures are silent until the next tick.
///
/// Self-update notes for this app specifically:
///  - the release .app is signed with the same "Ghbdtn Local Signing" identity
///    as the installed one, so the Accessibility (TCC) grant survives a swap;
///  - quarantine is only stamped by apps that opt into LSFileQuarantineEnabled
///    (browsers). We download with URLSession, so Gatekeeper never quarantines
///    the update and no "app is damaged" dance happens;
///  - the running bundle is replaced by a detached helper script AFTER this
///    process exits, then relaunched.
final class UpdateChecker: ObservableObject {
    static let shared = UpdateChecker()

    struct Update {
        let version: String   // "0.5.1" (tag without the leading "v")
        let pageURL: URL
        let dmgURL: URL?
    }

    /// Non-nil when a newer release is known; drives the tray-menu item.
    @Published private(set) var available: Update?
    /// True while a download/install is running (menu shows progress state).
    @Published private(set) var installing = false

    private static let repo = "svetlovmusic/ghbdtn"
    private static let checkInterval: TimeInterval = 24 * 60 * 60
    private var timer: Timer?

    // UserDefaults keys (deliberately not part of Settings: the checker must be
    // usable from the headless `--updatecheck` mode without touching Settings,
    // whose init reads the Keychain).
    private enum DefaultsKey {
        static let etag = "updateCheck.etag"
        static let latestVersion = "updateCheck.latestVersion"
        static let latestPage = "updateCheck.latestPage"
        static let latestDmg = "updateCheck.latestDmg"
        static let lastNotified = "updateCheck.lastNotifiedVersion"
    }

    /// Overridable for testing: GHBDTN_FAKE_VERSION=0.4.0 ghbdtn --updatecheck
    var currentVersion: String {
        ProcessInfo.processInfo.environment["GHBDTN_FAKE_VERSION"]
            ?? (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0")
    }

    // MARK: - Scheduling

    /// Kick off background polling: first check shortly after launch (off the
    /// startup path, with jitter so a fleet of machines doesn't sync up), then
    /// daily. Idempotent.
    func start() {
        guard timer == nil else { return }
        let firstDelay = 60.0 + Double.random(in: 0...600)
        DispatchQueue.main.asyncAfter(deadline: .now() + firstDelay) { [weak self] in
            self?.tick()
        }
        let t = Timer(timeInterval: Self.checkInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        t.tolerance = Self.checkInterval / 10   // let the OS coalesce wakeups
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        guard Settings.shared.autoCheckUpdates else { return }
        checkNow(userInitiated: false) { _ in }
    }

    // MARK: - Checking

    /// Query the latest release and update `available`. `completion` receives
    /// a short human-readable status line (for the manual menu action / CLI).
    func checkNow(userInitiated: Bool, completion: @escaping (String) -> Void) {
        let defaults = UserDefaults.standard
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        if let etag = defaults.string(forKey: DefaultsKey.etag) {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        request.timeoutInterval = 15

        URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
            guard let self else { return }
            let http = response as? HTTPURLResponse
            switch (http?.statusCode, error) {
            case (304, _):
                // Unchanged since last time — evaluate the cached answer, so a
                // 304 still yields a verdict (e.g. after the app was updated).
                self.evaluate(version: defaults.string(forKey: DefaultsKey.latestVersion),
                              page: defaults.string(forKey: DefaultsKey.latestPage),
                              dmg: defaults.string(forKey: DefaultsKey.latestDmg),
                              userInitiated: userInitiated, completion: completion)
            case (200, _):
                guard let data,
                      let release = try? JSONDecoder().decode(Release.self, from: data) else {
                    completion("Не удалось разобрать ответ GitHub")
                    return
                }
                let version = release.tag_name.hasPrefix("v")
                    ? String(release.tag_name.dropFirst()) : release.tag_name
                let dmg = release.assets.first { $0.name.hasSuffix(".dmg") }?.browser_download_url
                defaults.set(http?.value(forHTTPHeaderField: "ETag"), forKey: DefaultsKey.etag)
                defaults.set(version, forKey: DefaultsKey.latestVersion)
                defaults.set(release.html_url, forKey: DefaultsKey.latestPage)
                defaults.set(dmg, forKey: DefaultsKey.latestDmg)
                self.evaluate(version: version, page: release.html_url, dmg: dmg,
                              userInitiated: userInitiated, completion: completion)
            default:
                let detail = error?.localizedDescription ?? "HTTP \(http?.statusCode ?? 0)"
                Log.info("Update check failed: \(detail)")
                completion("Не удалось проверить обновления (\(detail))")
            }
        }.resume()
    }

    private struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browser_download_url: String
        }
        let tag_name: String
        let html_url: String
        let assets: [Asset]
    }

    private func evaluate(version: String?, page: String?, dmg: String?,
                          userInitiated: Bool, completion: @escaping (String) -> Void) {
        guard let version, let page, let pageURL = URL(string: page) else {
            completion("Нет данных о релизах")
            return
        }
        let current = currentVersion
        guard Self.isVersion(version, newerThan: current) else {
            DispatchQueue.main.async { self.available = nil }
            completion("У вас последняя версия (\(current))")
            return
        }
        let update = Update(version: version, pageURL: pageURL,
                            dmgURL: dmg.flatMap { URL(string: $0) })
        DispatchQueue.main.async { self.available = update }
        // Notify once per version on the scheduled path; the tray item stays
        // as the persistent reminder without daily nagging.
        let defaults = UserDefaults.standard
        if !userInitiated, defaults.string(forKey: DefaultsKey.lastNotified) != version {
            defaults.set(version, forKey: DefaultsKey.lastNotified)
            Notifier.show(title: "Доступна версия \(version)",
                          body: "Обновить: меню ghbdtn в строке меню → «Обновить до \(version)».")
        }
        completion("Доступна версия \(version) (у вас \(current))")
    }

    /// Numeric dot-component comparison: "0.10.0" > "0.9.1", unlike a string
    /// compare. Missing components count as 0 ("0.5" == "0.5.0").
    static func isVersion(_ a: String, newerThan b: String) -> Bool {
        let av = a.split(separator: ".").map { Int($0) ?? 0 }
        let bv = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(av.count, bv.count) {
            let x = i < av.count ? av[i] : 0
            let y = i < bv.count ? bv[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Self-update

    /// Download the .dmg of `available`, verify the staged app, then swap the
    /// installed bundle and relaunch. Any failure falls back to opening the
    /// release page so the user is never stuck.
    func installAvailableUpdate() {
        guard let update = available, !installing else { return }
        // Only self-swap a normal /Applications install; a dev build living in
        // the repo must not be clobbered by a downloaded release.
        let dest = Bundle.main.bundlePath
        guard let dmgURL = update.dmgURL, dest.hasPrefix("/Applications/") else {
            NSWorkspace.shared.open(update.pageURL)
            return
        }
        DispatchQueue.main.async { self.installing = true }
        Notifier.show(title: "Загружаю обновление \(update.version)…",
                      body: "Приложение перезапустится автоматически.")

        URLSession.shared.downloadTask(with: dmgURL) { [weak self] tmp, _, error in
            guard let self else { return }
            let fail: (String) -> Void = { reason in
                Log.error("Self-update failed: \(reason)")
                DispatchQueue.main.async {
                    self.installing = false
                    Notifier.show(title: "Не удалось обновиться автоматически",
                                  body: "Открываю страницу релиза. (\(reason))")
                    NSWorkspace.shared.open(update.pageURL)
                }
            }
            guard let tmp, error == nil else {
                fail(error?.localizedDescription ?? "download error"); return
            }
            do {
                let staged = try self.stageApp(fromDMG: tmp, expectVersion: update.version)
                try self.swapAndRelaunch(staged: staged, dest: dest)
                // swapAndRelaunch terminates the app; nothing runs after it.
            } catch {
                fail("\(error)")
            }
        }.resume()
    }

    private enum UpdateError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case let .message(m) = self { return m }
            return nil
        }
    }

    /// Mount the dmg, verify the contained ghbdtn.app (bundle id, version,
    /// valid code signature), copy it out to a temp staging dir, unmount.
    private func stageApp(fromDMG dmg: URL, expectVersion: String) throws -> String {
        let mountPoint = NSTemporaryDirectory() + "ghbdtn-update-mount-\(ProcessInfo.processInfo.processIdentifier)"
        let attach = Self.run(["/usr/bin/hdiutil", "attach", dmg.path, "-nobrowse", "-readonly",
                               "-mountpoint", mountPoint])
        guard attach.status == 0 else { throw UpdateError.message("hdiutil attach: \(attach.output)") }
        defer { _ = Self.run(["/usr/bin/hdiutil", "detach", mountPoint, "-force"]) }

        let mounted = mountPoint + "/ghbdtn.app"
        guard FileManager.default.fileExists(atPath: mounted) else {
            throw UpdateError.message("ghbdtn.app не найден в образе")
        }
        // The update must be what it claims: our bundle id, the advertised
        // version, and an intact signature — a truncated download or a foreign
        // artifact must never replace the installed app.
        let info = NSDictionary(contentsOfFile: mounted + "/Contents/Info.plist")
        guard info?["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info?["CFBundleShortVersionString"] as? String == expectVersion else {
            throw UpdateError.message("образ содержит не ту версию/бандл")
        }
        let sign = Self.run(["/usr/bin/codesign", "--verify", "--deep", mounted])
        guard sign.status == 0 else { throw UpdateError.message("подпись не прошла проверку: \(sign.output)") }

        let staging = NSTemporaryDirectory() + "ghbdtn-update-\(expectVersion)"
        try? FileManager.default.removeItem(atPath: staging)
        // ditto preserves signatures, resource forks and permissions exactly.
        let copy = Self.run(["/usr/bin/ditto", mounted, staging + "/ghbdtn.app"])
        guard copy.status == 0 else { throw UpdateError.message("ditto: \(copy.output)") }
        return staging + "/ghbdtn.app"
    }

    /// Hand the swap to a detached helper that waits for this process to exit,
    /// replaces the bundle and relaunches it, then quit.
    private func swapAndRelaunch(staged: String, dest: String) throws {
        let script = """
        #!/bin/bash
        # ghbdtn self-update helper: $1=pid to wait for, $2=staged app, $3=dest
        while /bin/kill -0 "$1" 2>/dev/null; do /bin/sleep 0.2; done
        /bin/rm -rf "$3"
        /usr/bin/ditto "$2" "$3"
        /usr/bin/xattr -dr com.apple.quarantine "$3" 2>/dev/null || true
        /usr/bin/open "$3"
        /bin/rm -rf "$(/usr/bin/dirname "$2")"
        """
        let scriptPath = NSTemporaryDirectory() + "ghbdtn-update-swap.sh"
        try script.write(toFile: scriptPath, atomically: true, encoding: .utf8)

        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/bash")
        helper.arguments = [scriptPath, String(ProcessInfo.processInfo.processIdentifier), staged, dest]
        try helper.run()   // NOT waited on — it outlives us by design

        Log.info("Self-update helper launched; exiting for swap to \(dest)")
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }

    @discardableResult
    private static func run(_ command: [String]) -> (status: Int32, output: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: command[0])
        p.arguments = Array(command.dropFirst())
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (-1, "\(error)") }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(data: data, encoding: .utf8) ?? "")
    }

    // MARK: - Headless check (`ghbdtn --updatecheck`)

    /// Synchronous one-shot check for the CLI diagnostic; never touches
    /// Settings (whose init reads the Keychain) and never installs.
    static func runBlockingCheck() -> Bool {
        let semaphore = DispatchSemaphore(value: 0)
        var ok = true
        let checker = UpdateChecker()
        print("current version: \(checker.currentVersion)")
        checker.checkNow(userInitiated: true) { status in
            print(status)
            ok = !status.hasPrefix("Не удалось")
            semaphore.signal()
        }
        _ = semaphore.wait(timeout: .now() + 30)
        return ok
    }
}
