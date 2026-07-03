import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let engine = AutoSwitchEngine.shared
    private let settings = Settings.shared
    private var settingsWindow: NSWindow?
    private var onboardingWindow: NSWindow?
    private var cancellables = Set<AnyCancellable>()
    private var permissionPollTimer: Timer?

    /// Recent conversions shown in the menu.
    private var recentConversions: [AutoSwitchEngine.ConversionRecord] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Agent app: no Dock icon, no main menu bar app.
        NSApp.setActivationPolicy(.accessory)

        Notifier.requestAuthorization()
        setupStatusItem()
        setupHotkeys()
        observeConversions()

        // Sync login-item state with the stored preference.
        applyLaunchAtLogin(settings.launchAtLogin)
        settings.$launchAtLogin
            .dropFirst()
            .sink { [weak self] in self?.applyLaunchAtLogin($0) }
            .store(in: &cancellables)

        if Permissions.hasAccessibility() {
            startEngine()
        } else {
            showOnboarding()
            pollForPermission()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        engine.stop()
        HotkeyCenter.shared.unregisterAll()
    }

    /// Apply the launch-at-login preference and reconcile the UI with the real
    /// SMAppService state — if the OS refuses the (un)registration, reflect the
    /// actual state back into settings instead of showing a lie.
    private func applyLaunchAtLogin(_ enabled: Bool) {
        LoginItem.set(enabled: enabled)
        let actual = LoginItem.isEnabled
        if actual != enabled {
            Log.error("launchAtLogin: requested \(enabled) but service is \(actual)")
            DispatchQueue.main.async { [weak self] in
                guard let self, self.settings.launchAtLogin != actual else { return }
                self.settings.launchAtLogin = actual
            }
        }
    }

    // MARK: - Engine

    private func startEngine() {
        let ok = engine.start()
        if !ok {
            Notifier.show(title: "Нет доступа к Универсальному доступу",
                          body: "Разрешите Ghbdtn в Настройках → Конфиденциальность → Универсальный доступ.")
        }
        updateStatusIcon()
    }

    private func observeConversions() {
        engine.didConvert
            .receive(on: RunLoop.main)
            .sink { [weak self] record in
                self?.recentConversions.insert(record, at: 0)
                if self!.recentConversions.count > 8 { self?.recentConversions.removeLast() }
                if Settings.shared.showConversionNotifications {
                    Notifier.show(title: "\(record.from) → \(record.to)",
                                  body: "\(record.fromLayout) → \(record.toLayout)\(record.viaAI ? " · ИИ" : "")")
                }
                self?.rebuildMenu()
            }
            .store(in: &cancellables)

        engine.$isActive
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.updateStatusIcon() }
            .store(in: &cancellables)
    }

    // MARK: - Status item & menu

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        updateStatusIcon()
        rebuildMenu()
    }

    private func updateStatusIcon() {
        guard let button = statusItem.button else { return }
        let active = engine.isActive && settings.autoSwitchEnabled
        let symbol = active ? "keyboard.badge.ellipsis" : "keyboard"
        if let image = NSImage(systemSymbolName: symbol, accessibilityDescription: "Ghbdtn (Привет)") {
            image.isTemplate = true
            button.image = image
        } else {
            button.title = active ? "⌨︎" : "⌨"
        }
        button.appearsDisabled = !active
    }

    private func rebuildMenu() {
        let menu = NSMenu()

        // Header / toggle
        let toggle = NSMenuItem(
            title: settings.autoSwitchEnabled ? "Автопереключение: вкл" : "Автопереключение: выкл",
            action: #selector(toggleAutoSwitch), keyEquivalent: ""
        )
        toggle.target = self
        toggle.state = settings.autoSwitchEnabled ? .on : .off
        menu.addItem(toggle)

        if !Permissions.hasAccessibility() {
            menu.addItem(.separator())
            let warn = NSMenuItem(title: "⚠︎ Нужен доступ (Универсальный доступ)",
                                  action: #selector(showOnboarding), keyEquivalent: "")
            warn.target = self
            menu.addItem(warn)
        }

        menu.addItem(.separator())

        // Recent conversions
        if recentConversions.isEmpty {
            let empty = NSMenuItem(title: "Пока нет конвертаций", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            let header = NSMenuItem(title: "Недавние:", action: nil, keyEquivalent: "")
            header.isEnabled = false
            menu.addItem(header)
            for r in recentConversions.prefix(6) {
                let item = NSMenuItem(title: "  \(r.from)  →  \(r.to)", action: nil, keyEquivalent: "")
                item.isEnabled = false
                menu.addItem(item)
            }
        }

        menu.addItem(.separator())

        let convert = NSMenuItem(title: "Конвертировать выделенное / последнее слово",
                                 action: #selector(manualConvert), keyEquivalent: "")
        convert.target = self
        menu.addItem(convert)

        // System-wide "dictate here": macOS forbids adding items to other
        // apps' right-click menus, so the tray menu + global hotkey are the
        // honest equivalents. The status-item menu does not activate this
        // app, so the caret stays in the frontmost app's text field.
        let dictate = NSMenuItem(title: "Диктовка (Whisper)",
                                 action: #selector(startDictation), keyEquivalent: "")
        dictate.target = self
        dictate.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
        menu.addItem(dictate)

        let prefs = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти из Ghbdtn (Привет)", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    // MARK: - Actions

    @objc private func toggleAutoSwitch() {
        settings.autoSwitchEnabled.toggle()
        engine.syncEnabledState()
        updateStatusIcon()
        rebuildMenu()
    }

    @objc private func manualConvert() {
        engine.manualConvertLastWord()
    }

    @objc private func startDictation() {
        Task { @MainActor in DictationController.shared.toggle() }
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            let view = SettingsView().environmentObject(settings)
            let hosting = NSHostingController(rootView: view)
            // Build the window with its final styleMask up front — mutating
            // styleMask *after* assigning content makes AppKit re-lay-out the
            // content ignoring the titlebar, sliding it up under the title.
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 520),
                styleMask: [.titled, .closable, .miniaturizable],
                backing: .buffered, defer: false
            )
            window.contentViewController = hosting
            window.title = "Настройки Ghbdtn (Привет)"
            window.center()
            window.isReleasedWhenClosed = false
            settingsWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func showOnboarding() {
        if onboardingWindow == nil {
            let view = OnboardingView(onDone: { [weak self] in
                self?.onboardingWindow?.close()
                self?.startEngine()
            })
            let hosting = NSHostingController(rootView: view)
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 460, height: 430),
                styleMask: [.titled, .closable],
                backing: .buffered, defer: false
            )
            window.contentViewController = hosting
            window.title = "Добро пожаловать в Ghbdtn (Привет)"
            window.center()
            window.isReleasedWhenClosed = false
            onboardingWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        onboardingWindow?.makeKeyAndOrderFront(nil)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    // MARK: - Hotkeys

    private func setupHotkeys() {
        let center = HotkeyCenter.shared
        center.installHandler()
        center.onAction(.manualConvert) { [weak self] in
            self?.engine.manualConvertLastWord()
        }
        center.onAction(.voiceDictation) {
            Task { @MainActor in DictationController.shared.toggle() }
        }
        // Registered/unregistered by DictationController per session — a bare
        // Escape must not be captured while no dictation is running.
        center.onAction(.voiceCancel) {
            Task { @MainActor in DictationController.shared.cancel() }
        }
        center.register(.manualConvert, hotkey: settings.manualConvertHotkey)
        center.register(.voiceDictation, hotkey: settings.whisperHotkey)

        // Re-register when the user changes a shortcut.
        settings.$manualConvertHotkey
            .dropFirst()
            .sink { center.register(.manualConvert, hotkey: $0) }
            .store(in: &cancellables)
        settings.$whisperHotkey
            .dropFirst()
            .sink { center.register(.voiceDictation, hotkey: $0) }
            .store(in: &cancellables)
    }

    // MARK: - Permission polling

    private func pollForPermission() {
        permissionPollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] timer in
            if Permissions.hasAccessibility() {
                timer.invalidate()
                self?.permissionPollTimer = nil
                self?.onboardingWindow?.close()
                self?.startEngine()
                self?.rebuildMenu()
            }
        }
    }
}
