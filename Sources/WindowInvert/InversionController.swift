import AppKit
import ScreenCaptureKit
import ApplicationServices
import QuartzCore

/// Owns all active inversions and drives window tracking from a display link.
final class InversionController {
    private(set) var sessions: [CGWindowID: InversionSession] = [:]
    private var displayLink: CADisplayLink?
    private var focusObservers: [pid_t: AXObserver] = [:]
    private var missionControlTrace: MissionControlTrace?
    var isTracingMissionControl: Bool { missionControlTrace != nil }
    var onChange: (() -> Void)?

    var colorMode: ColorMode {
        didSet {
            UserDefaults.standard.set(Int(colorMode.rawValue), forKey: "colorMode")
            sessions.values.forEach { $0.colorMode = colorMode }
        }
    }

    var contrast: Contrast {
        didSet {
            UserDefaults.standard.set(contrast.rawValue, forKey: "contrast")
            sessions.values.forEach { $0.contrast = contrast }
        }
    }

    var pausesBehindSheets: Bool {
        didSet {
            UserDefaults.standard.set(pausesBehindSheets, forKey: "pausesBehindSheets")
            sessions.values.forEach { $0.pausesBehindSheets = pausesBehindSheets }
        }
    }

    var hidesInMissionControl: Bool {
        didSet {
            UserDefaults.standard.set(hidesInMissionControl, forKey: "hidesInMissionControl")
            sessions.values.forEach { $0.hidesInMissionControl = hidesInMissionControl }
        }
    }

    static func registerDefaults(in defaults: UserDefaults) {
        defaults.register(defaults: ["pausesBehindSheets": true, "hidesInMissionControl": false])
    }

    init() {
        Self.registerDefaults(in: .standard)
        pausesBehindSheets = UserDefaults.standard.bool(forKey: "pausesBehindSheets")
        hidesInMissionControl = UserDefaults.standard.bool(forKey: "hidesInMissionControl")
        contrast = Contrast(rawValue: UserDefaults.standard.integer(forKey: "contrast")) ?? .high
        colorMode = ColorMode(rawValue: Int32(UserDefaults.standard.integer(forKey: "colorMode"))) ?? .invert
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(applicationActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification, object: nil)
        // Warm up Metal and the ScreenCaptureKit connection so the first inversion starts quickly.
        if hasScreenRecordingPermission {
            _ = InvertRenderer.shared
            Task { _ = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) }
        }
    }

    var hasScreenRecordingPermission: Bool { CGPreflightScreenCaptureAccess() }

    @objc private func applicationActivated(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        let pids = WindowLocator.activationPIDs(for: app, knownTargets: sessions.values.map(\.target))
        applicationActivated(pids: pids, source: "Workspace \(app.bundleIdentifier ?? "?") reported pid=\(app.processIdentifier)")
    }

    private func applicationActivated(pids: Set<pid_t>, source: String) {
        guard !sessions.isEmpty else { return }
        let id = WindowLocator.frontDocumentWindow(of: pids)
        Log.write("activation: \(source), pids=\(pids.sorted()), window=\(id.map(String.init) ?? "unresolved")")
        prepareForActivation(windowID: id, activePIDs: pids)
    }

    private func prepareForActivation(windowID: CGWindowID?, activePIDs: Set<pid_t>) {
        for session in sessions.values {
            if session.target.windowID == windowID {
                session.prepareForActivation()
            } else if windowID != nil || !activePIDs.contains(session.target.pid) {
                session.cancelActivation()
            }
        }
    }

    private func focusedWindowChanged(_ element: AXUIElement) {
        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success else { return }
        let activePIDs = NSWorkspace.shared.frontmostApplication.map {
            WindowLocator.activationPIDs(for: $0, knownTargets: sessions.values.map(\.target))
        } ?? []
        let isActive = activePIDs.isEmpty ? NSRunningApplication(processIdentifier: pid)?.isActive == true : activePIDs.contains(pid)
        guard isActive else {
            Log.write("focus event ignored: pid=\(pid), active pids=\(activePIDs.sorted())")
            return
        }
        guard let id = WindowLocator.focusedWindowID(of: pid) else {
            Log.write("focus lookup unresolved: pid=\(pid); retaining activation hold")
            return
        }
        prepareForActivation(windowID: id, activePIDs: [pid])
    }

    private func updateFocusObservers() {
        let pids = Set(sessions.values.map(\.target.pid))
        for pid in Array(focusObservers.keys) where !pids.contains(pid) {
            if let observer = focusObservers.removeValue(forKey: pid) {
                CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
            }
        }
        guard AXIsProcessTrusted() else { return }
        for pid in pids where focusObservers[pid] == nil {
            var observer: AXObserver?
            let callback: AXObserverCallback = { _, element, notification, context in
                guard let context else { return }
                let controller = Unmanaged<InversionController>.fromOpaque(context).takeUnretainedValue()
                if notification as String == kAXApplicationActivatedNotification {
                    var pid: pid_t = 0
                    guard AXUIElementGetPid(element, &pid) == .success, pid > 0 else { return }
                    controller.applicationActivated(pids: [pid], source: "Accessibility")
                } else {
                    controller.focusedWindowChanged(element)
                }
            }
            guard AXObserverCreate(pid, callback, &observer) == .success, let observer else { continue }
            var registered = false
            for notification in [kAXFocusedWindowChangedNotification, kAXApplicationActivatedNotification] {
                let result = AXObserverAddNotification(observer, AXUIElementCreateApplication(pid),
                    notification as CFString, Unmanaged.passUnretained(self).toOpaque())
                if result == .success { registered = true }
                else { Log.write("AX observer pid=\(pid) \(notification) failed: \(result.rawValue)") }
            }
            guard registered else { continue }
            focusObservers[pid] = observer
            CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for observer in focusObservers.values {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .commonModes)
        }
    }
    var hasAccessibilityPermission: Bool { AXIsProcessTrusted() }

    func toggle(_ scope: InvertScope) {
        guard hasScreenRecordingPermission else {
            CGRequestScreenCaptureAccess()
            PermissionAlert.showScreenRecording()
            return
        }
        if !hasAccessibilityPermission {
            // Content-only mode needs Accessibility to find the document area; whole-window mode
            // works without it but Accessibility gives more accurate focused-window detection.
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
        }
        guard let target = WindowLocator.frontmostWindow() else {
            Log.write("toggle ignored: no front window")
            return
        }
        Log.write("toggle \(scope) on window \(target.windowID) (AX element: \(target.axWindow != nil))")

        if let existing = sessions[target.windowID] {
            if existing.scope == scope {
                existing.stop()
                sessions[target.windowID] = nil
                updateDisplayLink()
                onChange?()
            } else {
                existing.scope = scope
            }
            return
        }

        let session = InversionSession(target: target, scope: scope, colorMode: colorMode, contrast: contrast)
        session.pausesBehindSheets = pausesBehindSheets
        session.hidesInMissionControl = hidesInMissionControl
        session.onEnded = { [weak self] ended in
            guard let self, self.sessions[ended.target.windowID] === ended else { return }
            self.sessions[ended.target.windowID] = nil
            self.updateDisplayLink()
            self.onChange?()
        }
        sessions[target.windowID] = session
        updateDisplayLink()
        onChange?()

        Task { @MainActor in
            do {
                try await session.start()
            } catch {
                Log.write("failed to start capture: \(error)")
                session.stop()
                if self.sessions[target.windowID] === session {
                    self.sessions[target.windowID] = nil
                    self.updateDisplayLink()
                    self.onChange?()
                }
                FailureAlert.show("WindowInvert couldn't capture this window.\n\n\(error.localizedDescription)")
            }
        }
    }

    func stopAll() {
        sessions.values.forEach { $0.stop() }
        sessions.removeAll()
        updateDisplayLink()
        onChange?()
    }

    private func updateDisplayLink() {
        updateFocusObservers()
        if sessions.isEmpty {
            displayLink?.invalidate()
            displayLink = nil
        } else if displayLink == nil, let screen = NSScreen.main ?? NSScreen.screens.first {
            let link = screen.displayLink(target: self, selector: #selector(tick))
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
    }

    @objc private func tick() {
        let missionControl = WindowLocator.missionControlState()
        for session in Array(sessions.values) {
            session.tick(missionControl: missionControl)
        }
        missionControlTrace?.recordTrackingTick(missionControl: missionControl,
            activeTargets: sessions.values.filter(\.isInMissionControl).map(\.target.windowID))
    }

    func traceMissionControl() {
        guard missionControlTrace == nil, !sessions.isEmpty else { return }
        let trace = MissionControlTrace(targets: sessions.mapValues(\.overlayWindowID),
                                        hidesInMissionControl: hidesInMissionControl)
        missionControlTrace = trace
        Log.write("Mission Control diagnostic capture started (20 seconds; geometry only)")
        trace.start { [weak self] result in
            self?.missionControlTrace = nil
            switch result {
            case .success(let url):
                Log.write("Mission Control diagnostic capture saved to \(url.path)")
                NSWorkspace.shared.activateFileViewerSelecting([url])
            case .failure(let error):
                Log.write("Mission Control diagnostic capture failed: \(error)")
                let alert = NSAlert(error: error)
                alert.runModal()
            }
        }
    }
}

enum FailureAlert {
    static func show(_ message: String) {
        NSSound.beep()
        let alert = NSAlert()
        alert.messageText = "Couldn't invert window"
        alert.informativeText = message + "\n\nThe diagnostic log has details you can send to the developer."
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Show Log")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertSecondButtonReturn {
            NSWorkspace.shared.open(Log.url)
        }
    }
}

enum PermissionAlert {
    static func showScreenRecording() {
        let alert = NSAlert()
        alert.messageText = "Screen Recording permission needed"
        alert.informativeText = """
        WindowInvert draws an inverted copy of the window, so it needs to capture it.

        Enable WindowInvert in System Settings → Privacy & Security → Screen & System Audio Recording, \
        then quit and reopen WindowInvert.
        """
        alert.addButton(withTitle: "Open System Settings")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            Settings.openScreenRecording()
        }
    }
}

enum Settings {
    static func openScreenRecording() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
    }

    static func openAccessibility() {
        open("x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
    }

    private static func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
