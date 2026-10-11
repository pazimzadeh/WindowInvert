import AppKit
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = InversionController()
    private let hotKeys = HotKeys()
    private var statusItem: NSStatusItem!
    private var settingsWindow: SettingsWindowController?
    private var hotKeyFailures: Set<ShortcutAction> = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?"
        Log.write("launched v\(version) on macOS \(ProcessInfo.processInfo.operatingSystemVersionString); "
                  + "screen recording=\(CGPreflightScreenCaptureAccess()) accessibility=\(AXIsProcessTrusted()); "
                  + "screens: " + NSScreen.screens.map { "\($0.frame) @\($0.backingScaleFactor)x" }.joined(separator: ", "))
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        controller.onChange = { [weak self] in self?.updateIcon() }

        registerHotKeys()

        if !controller.hasScreenRecordingPermission {
            CGRequestScreenCaptureAccess()
        }
        if !controller.hasAccessibilityPermission {
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        controller.stopAll()
    }

    private func updateIcon() {
        statusItem.button?.image = StatusIcon.image(active: !controller.sessions.isEmpty)
    }

    // MARK: - Shortcuts

    @discardableResult
    private func registerHotKeys() -> Set<ShortcutAction> {
        hotKeys.unregisterAll()
        var failures: Set<ShortcutAction> = []
        for action in ShortcutAction.allCases {
            guard let combo = action.combo else { continue }
            let ok = hotKeys.register(id: action.hotKeyID, combo: combo) { [weak self] in self?.perform(action) }
            if !ok { failures.insert(action) }
        }
        hotKeyFailures = failures
        return failures
    }

    private func perform(_ action: ShortcutAction) {
        Log.write("shortcut \(action.rawValue)")
        switch action {
        case .invertWindow: controller.toggle(.window)
        case .invertContent: controller.toggle(.content)
        case .switchStyle: switchStyle()
        case .cycleContrast: cycleContrast()
        case .stopAll:
            guard !controller.sessions.isEmpty else { return }
            controller.stopAll()
            HUD.show("All Inversions Stopped")
        }
    }

    private func switchStyle() {
        controller.colorMode = controller.colorMode == .invert ? .huePreserving : .invert
        HUD.show(controller.colorMode == .invert ? "Classic Invert" : "Hue-Preserving Invert")
    }

    private func menuItem(_ title: String, _ selector: Selector, for action: ShortcutAction) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        if let combo = action.combo, let key = combo.menuKeyEquivalent {
            item.keyEquivalent = key
            item.keyEquivalentModifierMask = combo.modifierFlags
        }
        return item
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        menu.addItem(menuItem("Invert Front Window", #selector(invertWindow), for: .invertWindow))
        menu.addItem(menuItem("Invert Front Window Content Only", #selector(invertContent), for: .invertContent))

        let stopAll = menuItem("Stop All Inversions", #selector(stopAll), for: .stopAll)
        if controller.sessions.isEmpty { stopAll.action = nil }
        menu.addItem(stopAll)

        menu.addItem(.separator())
        let classic = NSMenuItem(title: "Classic Invert", action: #selector(selectClassic), keyEquivalent: "")
        classic.state = controller.colorMode == .invert ? .on : .off
        let hue = NSMenuItem(title: "Hue-Preserving Invert", action: #selector(selectHuePreserving), keyEquivalent: "")
        hue.state = controller.colorMode == .huePreserving ? .on : .off
        menu.addItem(classic)
        menu.addItem(hue)
        menu.addItem(menuItem("Switch Invert Style", #selector(switchStyleFromMenu), for: .switchStyle))

        menu.addItem(.separator())
        for contrast in Contrast.allCases {
            let item = NSMenuItem(title: contrast.title, action: #selector(selectContrast(_:)), keyEquivalent: "")
            item.tag = contrast.rawValue
            item.state = controller.contrast == contrast ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(menuItem("Cycle Contrast Levels", #selector(cycleContrast), for: .cycleContrast))

        menu.addItem(.separator())
        let sheets = NSMenuItem(title: "Invert Behind Sheets & Popovers", action: #selector(toggleSheets), keyEquivalent: "")
        sheets.state = controller.pausesBehindSheets ? .off : .on
        menu.addItem(sheets)
        let missionControl = NSMenuItem(title: "Invert During Mission Control", action: #selector(toggleMissionControl),
                                        keyEquivalent: "")
        missionControl.state = controller.hidesInMissionControl ? .off : .on
        menu.addItem(missionControl)

        menu.addItem(.separator())
        let screen = controller.hasScreenRecordingPermission
        let screenItem = NSMenuItem(title: screen ? "Screen Recording: Allowed" : "Screen Recording: Not Allowed — Open Settings…",
                                    action: screen ? nil : #selector(openScreenRecording), keyEquivalent: "")
        let ax = controller.hasAccessibilityPermission
        let axItem = NSMenuItem(title: ax ? "Accessibility: Allowed" : "Accessibility: Not Allowed — Open Settings…",
                                action: ax ? nil : #selector(openAccessibility), keyEquivalent: "")
        menu.addItem(screenItem)
        menu.addItem(axItem)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)

        menu.addItem(NSMenuItem(title: "Show Diagnostic Log", action: #selector(showLog), keyEquivalent: ""))
        let trace = NSMenuItem(title: controller.isTracingMissionControl ? "Recording Mission Control Diagnostics…"
                              : "Record Mission Control Diagnostics (20 seconds)",
                              action: #selector(traceMissionControl), keyEquivalent: "")
        if controller.isTracingMissionControl || controller.sessions.isEmpty { trace.action = nil }
        menu.addItem(trace)
        menu.addItem(NSMenuItem(title: "Settings…", action: #selector(openSettings), keyEquivalent: ","))

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "About WindowInvert", action: #selector(showAbout), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Quit WindowInvert", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil {
            item.target = self
        }
    }

    @objc private func invertWindow() { controller.toggle(.window) }
    @objc private func showAbout() {
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(nil)
    }
    @objc private func invertContent() { controller.toggle(.content) }
    @objc private func stopAll() { controller.stopAll() }
    @objc private func switchStyleFromMenu() { switchStyle() }
    @objc private func cycleContrast() {
        controller.contrast = controller.contrast.next
        HUD.show(controller.contrast.title)
    }
    @objc private func toggleSheets() { controller.pausesBehindSheets.toggle() }
    @objc private func toggleMissionControl() { controller.hidesInMissionControl.toggle() }
    @objc private func selectContrast(_ sender: NSMenuItem) {
        controller.contrast = Contrast(rawValue: sender.tag) ?? .high
    }
    @objc private func openSettings() {
        if settingsWindow == nil {
            let settings = SettingsWindowController()
            settings.onShortcutsChanged = { [weak self] in self?.registerHotKeys() ?? [] }
            settings.onRecordingChanged = { [weak self] recording in
                guard let self else { return }
                if recording { self.hotKeys.unregisterAll() } else { self.registerHotKeys() }
            }
            settingsWindow = settings
        }
        settingsWindow?.show(failures: hotKeyFailures)
    }
    @objc private func selectClassic() { controller.colorMode = .invert }
    @objc private func selectHuePreserving() { controller.colorMode = .huePreserving }
    @objc private func openScreenRecording() { Settings.openScreenRecording() }
    @objc private func openAccessibility() { Settings.openAccessibility() }
    @objc private func showLog() {
        if !FileManager.default.fileExists(atPath: Log.url.path) { Log.write("log opened") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSWorkspace.shared.open(Log.url) }
    }
    @objc private func quit() { NSApp.terminate(nil) }
    @objc private func traceMissionControl() { controller.traceMissionControl() }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert(error: error)
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}

enum StatusIcon {
    static func image(active: Bool) -> NSImage {
        let image = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { rect in
            guard let ctx = NSGraphicsContext.current?.cgContext else { return false }
            IconArt.drawGlyph(in: rect.insetBy(dx: 1.5, dy: 1.5), context: ctx, ink: .black,
                              lineWidth: 1.5, mirrored: active)
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = active ? "WindowInvert (active)" : "WindowInvert"
        return image
    }
}
