import AppKit
import SwiftUI
import Combine
import Carbon

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
        // Agent app: no Dock icon.
        NSApp.setActivationPolicy(.accessory)
        // A main menu with an Edit menu — otherwise ⌘X/⌘C/⌘V/⌘A don't reach the
        // field editor in our windows and just beep (see setupMainMenu).
        setupMainMenu()

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

        // Daily update polling (the checker itself re-reads the toggle on each
        // tick, so flipping it off in Settings silences checks immediately).
        UpdateChecker.shared.start()
        UpdateChecker.shared.$available
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
            .store(in: &cancellables)
        UpdateChecker.shared.$installing
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.rebuildMenu() }
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
        // Prime spellchecker dictionaries off the first-keystroke critical path.
        let langs = LayoutManager.shared.enabledLayouts().compactMap { $0.primaryLanguage }
        LanguageScorer.shared.warmUp(languages: langs + ["en", "ru"])
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

    /// An accessory (menu-bar) app has no main menu by default, so the standard
    /// clipboard shortcuts (⌘X/⌘C/⌘V/⌘A) have no menu item to trigger and just
    /// beep in our editable windows (Settings). Install a minimal main menu; the
    /// Edit items use nil target so they travel the responder chain to whatever
    /// text field is focused. Right-click paste worked already because the field
    /// editor's own context menu calls paste: directly.
    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App menu (first item) — gives ⌘H / ⌘Q while a window is focused.
        let appItem = NSMenuItem()
        mainMenu.addItem(appItem)
        let appMenu = NSMenu()
        appItem.submenu = appMenu
        appMenu.addItem(withTitle: "Скрыть", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Выйти из Ghbdtn (Привет)",
                        action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        // Edit menu — the whole reason this exists.
        let editItem = NSMenuItem()
        mainMenu.addItem(editItem)
        let editMenu = NSMenu(title: "Правка")
        editItem.submenu = editMenu
        editMenu.addItem(withTitle: "Отменить", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(withTitle: "Повторить", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Вырезать", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Копировать", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Вставить", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Выделить всё", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        NSApp.mainMenu = mainMenu
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

    /// Version line for the tray menu, read from the bundle's Info.plist. Shown
    /// as a disabled (non-clickable) item so it's easy to see which build a
    /// given machine is running.
    private var menuVersionString: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "?"
        let build = info?["CFBundleVersion"] as? String ?? "?"
        return "Версия \(short) (сборка \(build))"
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
        applyShortcut(settings.manualConvertHotkey, to: convert)
        menu.addItem(convert)

        let correct = NSMenuItem(title: "Поправить текст (ИИ)",
                                 action: #selector(correctText), keyEquivalent: "")
        correct.target = self
        correct.image = NSImage(systemSymbolName: "wand.and.stars", accessibilityDescription: nil)
        applyShortcut(settings.correctionHotkey, to: correct)
        menu.addItem(correct)

        // System-wide "dictate here": macOS forbids adding items to other
        // apps' right-click menus, so the tray menu + global hotkey are the
        // honest equivalents. The status-item menu does not activate this
        // app, so the caret stays in the frontmost app's text field.
        let dictate = NSMenuItem(title: "Диктовка (Whisper)",
                                 action: #selector(startDictation), keyEquivalent: "")
        dictate.target = self
        dictate.image = NSImage(systemSymbolName: "mic", accessibilityDescription: nil)
        applyShortcut(settings.whisperHotkey, to: dictate)
        menu.addItem(dictate)

        let prefs = NSMenuItem(title: "Настройки…", action: #selector(openSettings), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        // Update line: an actionable "upgrade to X" when a newer release is
        // known, otherwise a manual "check now".
        if UpdateChecker.shared.installing {
            let busy = NSMenuItem(title: "Загружается обновление…", action: nil, keyEquivalent: "")
            busy.isEnabled = false
            menu.addItem(busy)
        } else if let update = UpdateChecker.shared.available {
            let upgrade = NSMenuItem(title: "⬆ Обновить до \(update.version)",
                                     action: #selector(installUpdate), keyEquivalent: "")
            upgrade.target = self
            menu.addItem(upgrade)
        } else {
            let check = NSMenuItem(title: "Проверить обновления",
                                   action: #selector(checkForUpdates), keyEquivalent: "")
            check.target = self
            menu.addItem(check)
        }

        // Non-clickable info line: the app version, so you can tell at a glance
        // which build is installed on a given machine (action: nil → greyed out).
        let version = NSMenuItem(title: menuVersionString, action: nil, keyEquivalent: "")
        version.isEnabled = false
        menu.addItem(version)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Выйти из Ghbdtn (Привет)", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    /// Show a Hotkey's shortcut on a status-menu item. Status-item menu key
    /// equivalents are effectively display-only (they fire only while the menu
    /// itself is open), so this never double-triggers the global Carbon hotkey.
    private func applyShortcut(_ hk: Hotkey, to item: NSMenuItem) {
        guard hk.enabled, !(hk.keyCode == 0 && hk.modifiers == 0),
              let key = Self.keyEquivalent(for: UInt16(hk.keyCode)) else { return }
        var mask: NSEvent.ModifierFlags = []
        if hk.modifiers & UInt32(cmdKey) != 0 { mask.insert(.command) }
        if hk.modifiers & UInt32(optionKey) != 0 { mask.insert(.option) }
        if hk.modifiers & UInt32(controlKey) != 0 { mask.insert(.control) }
        if hk.modifiers & UInt32(shiftKey) != 0 { mask.insert(.shift) }
        item.keyEquivalent = key
        item.keyEquivalentModifierMask = mask
    }

    /// Carbon keycode → the character a menu keyEquivalent expects.
    private static func keyEquivalent(for code: UInt16) -> String? {
        switch Int(code) {
        case kVK_Space:                        return " "
        case kVK_Return, kVK_ANSI_KeypadEnter: return "\r"
        case kVK_Tab:                          return "\t"
        case kVK_Delete:                       return String(UnicodeScalar(8))
        case kVK_Escape:                       return String(UnicodeScalar(27))
        default:                               break
        }
        // Letters/digits/punctuation: reuse the recorder's display name.
        let name = HotkeyRecorder.RecorderButton.keyName(code)
        return name.count == 1 ? name.lowercased() : nil
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

    @objc private func correctText() {
        Task { @MainActor in RecoveryController.shared.run() }
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
                contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
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

    @objc private func checkForUpdates() {
        UpdateChecker.shared.checkNow(userInitiated: true) { status in
            Notifier.show(title: "Ghbdtn (Привет)", body: status)
        }
    }

    @objc private func installUpdate() {
        UpdateChecker.shared.installAvailableUpdate()
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
        center.onAction(.textCorrection) {
            Task { @MainActor in RecoveryController.shared.run() }
        }
        center.register(.manualConvert, hotkey: settings.manualConvertHotkey)
        center.register(.voiceDictation, hotkey: settings.whisperHotkey)
        center.register(.textCorrection, hotkey: settings.correctionHotkey)

        // Re-register when the user changes a shortcut.
        settings.$manualConvertHotkey
            .dropFirst()
            .sink { center.register(.manualConvert, hotkey: $0) }
            .store(in: &cancellables)
        settings.$whisperHotkey
            .dropFirst()
            .sink { center.register(.voiceDictation, hotkey: $0) }
            .store(in: &cancellables)
        settings.$correctionHotkey
            .dropFirst()
            .sink { center.register(.textCorrection, hotkey: $0) }
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
