import AppKit
import Carbon
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let controller = InversionController()
    private let hotKeys = HotKeys()
    private var statusItem: NSStatusItem!

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

        let option = Int(optionKey)
        hotKeys.register(id: 1, keyCode: kVK_ANSI_8, modifiers: option) { [weak self] in
            self?.controller.toggle(.window)
        }
        hotKeys.register(id: 2, keyCode: kVK_ANSI_9, modifiers: option) { [weak self] in
            self?.controller.toggle(.content)
        }

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
        let active = !controller.sessions.isEmpty
        let image = NSImage(systemSymbolName: active ? "circle.lefthalf.filled.inverse" : "circle.lefthalf.filled",
                            accessibilityDescription: "WindowInvert")
            ?? NSImage(systemSymbolName: "circle.lefthalf.filled", accessibilityDescription: "WindowInvert")
        image?.isTemplate = true
        statusItem.button?.image = image
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        let invertWindow = NSMenuItem(title: "Invert Front Window", action: #selector(invertWindow), keyEquivalent: "8")
        invertWindow.keyEquivalentModifierMask = [.option]
        let invertContent = NSMenuItem(title: "Invert Front Window Content Only", action: #selector(invertContent), keyEquivalent: "9")
        invertContent.keyEquivalentModifierMask = [.option]
        menu.addItem(invertWindow)
        menu.addItem(invertContent)

        let count = controller.sessions.count
        let stopAll = NSMenuItem(title: count > 0 ? "Stop All Inversions (\(count))" : "Stop All Inversions",
                                 action: count > 0 ? #selector(stopAll) : nil, keyEquivalent: "")
        menu.addItem(stopAll)

        menu.addItem(.separator())
        let classic = NSMenuItem(title: "Classic Invert", action: #selector(selectClassic), keyEquivalent: "")
        classic.state = controller.colorMode == .invert ? .on : .off
        let hue = NSMenuItem(title: "Hue-Preserving Invert", action: #selector(selectHuePreserving), keyEquivalent: "")
        hue.state = controller.colorMode == .huePreserving ? .on : .off
        menu.addItem(classic)
        menu.addItem(hue)

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

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit WindowInvert", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil {
            item.target = self
        }
    }

    @objc private func invertWindow() { controller.toggle(.window) }
    @objc private func invertContent() { controller.toggle(.content) }
    @objc private func stopAll() { controller.stopAll() }
    @objc private func selectClassic() { controller.colorMode = .invert }
    @objc private func selectHuePreserving() { controller.colorMode = .huePreserving }
    @objc private func openScreenRecording() { Settings.openScreenRecording() }
    @objc private func openAccessibility() { Settings.openAccessibility() }
    @objc private func showLog() {
        if !FileManager.default.fileExists(atPath: Log.url.path) { Log.write("log opened") }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { NSWorkspace.shared.open(Log.url) }
    }
    @objc private func quit() { NSApp.terminate(nil) }

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
