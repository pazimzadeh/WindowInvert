import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError

/// Cheaper than CGWindowListCopyWindowInfo (IDs only); marked unavailable in the Swift overlay.
@_silgen_name("CGWindowListCreate")
private func _CGWindowListCreate(_ option: UInt32, _ relativeToWindow: CGWindowID) -> Unmanaged<CFArray>?

struct TargetWindow {
    let windowID: CGWindowID
    let pid: pid_t
    let axWindow: AXUIElement?
}

/// Distances (in points) from each window edge to the content area.
struct EdgeInsets: Equatable {
    var top: CGFloat = 0
    var left: CGFloat = 0
    var bottom: CGFloat = 0
    var right: CGFloat = 0
    static let zero = EdgeInsets()
}

/// Current window-server state for a window. `bounds` uses CoreGraphics global coordinates
/// (origin at the top-left of the primary display, y grows downward).
struct WindowState {
    let bounds: CGRect
    let isOnScreen: Bool
}

enum WindowLocator {
    static func frontmostWindow() -> TargetWindow? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.processIdentifier != getpid() else {
            Log.write("no frontmost app (or WindowInvert itself is frontmost)")
            return nil
        }
        guard let pid = resolvePID(of: app) else {
            Log.write("could not resolve a process for \(app.bundleIdentifier ?? "?") (reported pid \(app.processIdentifier))")
            return nil
        }
        let candidates = onScreenWindows(of: pid)
        Log.write("frontmost app \(app.bundleIdentifier ?? "?") pid=\(pid) (reported \(app.processIdentifier)); on-screen windows: "
                  + candidates.map { "\($0.id) layer=\($0.layer) \($0.bounds) '\($0.title)'" }.joined(separator: "; "))

        var axWindows: [AXUIElement] = []
        if AXIsProcessTrusted() {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.5)
            let focused: AXUIElement? = copyAttribute(axApp, kAXFocusedWindowAttribute)
            let main: AXUIElement? = copyAttribute(axApp, kAXMainWindowAttribute)
            let all: [AXUIElement] = copyAttribute(axApp, kAXWindowsAttribute) ?? []
            axWindows = [focused, main].compactMap { $0 } + all
            // Prefer the focused/main window, but only if the window server says it's a visible,
            // normal window; some apps report hidden or helper windows as focused.
            for window in [focused, main].compactMap({ $0 }) {
                let id = windowID(of: window)
                Log.write("AX focused/main window id=\(id)")
                if id != 0, candidates.contains(where: { $0.id == id && $0.layer == 0 }) {
                    return TargetWindow(windowID: id, pid: pid, axWindow: window)
                }
            }
        }

        // Fallback: the front-most normal-layer window owned by the front app (list is front to back).
        guard let pick = candidates.first(where: { $0.layer == 0 && $0.bounds.width > 40 && $0.bounds.height > 40 }) else {
            Log.write("no suitable window found for pid \(pid)")
            return nil
        }
        let ax = axWindows.first { windowID(of: $0) == pick.id }
        Log.write("using window-list fallback id=\(pick.id) (AX match: \(ax != nil))")
        return TargetWindow(windowID: pick.id, pid: pid, axWindow: ax)
    }

    /// Some apps (e.g. Preview on macOS 27) are reported by NSWorkspace with pid -1. Fall back to
    /// another running instance with the same bundle ID, then to the owner of the front-most window.
    private static func resolvePID(of app: NSRunningApplication) -> pid_t? {
        if app.processIdentifier > 0 { return app.processIdentifier }
        if let bundleID = app.bundleIdentifier {
            let instances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
                .filter { $0.processIdentifier > 0 }
            if let pid = (instances.first { $0.isActive } ?? instances.first)?.processIdentifier {
                Log.write("resolved \(bundleID) to pid \(pid) via bundle ID")
                return pid
            }
        }
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return nil }
        let me = getpid()
        for info in list {
            guard (info[kCGWindowLayer as String] as? Int) == 0,
                  let owner = info[kCGWindowOwnerPID as String] as? pid_t, owner > 0, owner != me,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width > 40, bounds.height > 40 else { continue }
            Log.write("resolved front app to pid \(owner) ('\(info[kCGWindowOwnerName as String] as? String ?? "?")') via window list")
            return owner
        }
        return nil
    }

    private struct WindowInfo {
        let id: CGWindowID
        let layer: Int
        let bounds: CGRect
        let title: String
    }

    private static func onScreenWindows(of pid: pid_t) -> [WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        return list.compactMap { info in
            guard (info[kCGWindowOwnerPID as String] as? pid_t) == pid,
                  let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            return WindowInfo(id: id, layer: info[kCGWindowLayer as String] as? Int ?? 0, bounds: bounds,
                              title: info[kCGWindowName as String] as? String ?? "")
        }
    }

    private static func windowID(of window: AXUIElement) -> CGWindowID {
        var id: CGWindowID = 0
        return _AXUIElementGetWindow(window, &id) == .success ? id : 0
    }

    static func state(of windowID: CGWindowID) -> WindowState? {
        // The array must hold raw CGWindowID values, not boxed objects.
        var value = UnsafeRawPointer(bitPattern: UInt(windowID))
        guard let ids = CFArrayCreate(nil, &value, 1, nil),
              let list = CGWindowListCreateDescriptionFromArray(ids) as? [[String: Any]],
              let info = list.first,
              let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
        let onScreen = (info[kCGWindowIsOnscreen as String] as? Bool) ?? false
        return WindowState(bounds: bounds, isOnScreen: onScreen)
    }

    /// IDs of on-screen windows that are above `windowID`, ordered front to back.
    static func windowIDsAbove(_ windowID: CGWindowID) -> [CGWindowID] {
        guard let unmanaged = _CGWindowListCreate(CGWindowListOption.optionOnScreenAboveWindow.rawValue, windowID) else {
            return []
        }
        let array = unmanaged.takeRetainedValue()
        // CGWindowListCreate stores the window IDs directly as the array's values.
        return (0..<CFArrayGetCount(array)).map { index in
            CGWindowID(truncatingIfNeeded: UInt(bitPattern: CFArrayGetValueAtIndex(array, index)))
        }
    }

    // MARK: - Content area detection (Accessibility)

    private static let contentRoles: Set<String> = [
        "AXScrollArea", "AXWebArea", "AXTextArea", "AXBrowser", "AXTable", "AXOutline", "AXLayoutArea",
    ]

    /// Finds the main document area of a window (e.g. the PDF view in Preview) and returns its
    /// insets from the window edges. Falls back to excluding the title bar / toolbar.
    static func contentInsets(for window: AXUIElement, windowBounds: CGRect) -> EdgeInsets {
        AXUIElementSetMessagingTimeout(window, 0.3)
        guard windowBounds.width > 0, windowBounds.height > 0 else { return .zero }

        var best: CGRect?
        var toolbarBottom: CGFloat?
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var visited = 0
        let windowArea = windowBounds.width * windowBounds.height

        while !queue.isEmpty, visited < 600 {
            let (element, depth) = queue.removeFirst()
            visited += 1
            let role: String? = copyAttribute(element, kAXRoleAttribute)
            if element != window, let role, let frame = frame(of: element) {
                let clipped = frame.intersection(windowBounds)
                if role == "AXToolbar", !clipped.isNull {
                    toolbarBottom = max(toolbarBottom ?? 0, clipped.maxY)
                }
                if contentRoles.contains(role), !clipped.isNull,
                   clipped.width * clipped.height >= windowArea * 0.2,
                   clipped.width * clipped.height > (best.map { $0.width * $0.height } ?? 0) {
                    best = clipped
                    // Don't descend into the document itself; its children are content.
                    continue
                }
            }
            guard depth < 8, let children: [AXUIElement] = copyAttribute(element, kAXChildrenAttribute) else { continue }
            queue.append(contentsOf: children.map { ($0, depth + 1) })
        }

        if let best {
            return EdgeInsets(top: best.minY - windowBounds.minY,
                              left: best.minX - windowBounds.minX,
                              bottom: windowBounds.maxY - best.maxY,
                              right: windowBounds.maxX - best.maxX)
        }
        let defaultTitleBar: CGFloat = 28
        let top = toolbarBottom.map { max($0 - windowBounds.minY, defaultTitleBar) } ?? defaultTitleBar
        return EdgeInsets(top: min(top, windowBounds.height / 2))
    }

    static func frame(of element: AXUIElement) -> CGRect? {
        guard let posValue: AXValue = copyAttribute(element, kAXPositionAttribute),
              let sizeValue: AXValue = copyAttribute(element, kAXSizeAttribute) else { return nil }
        var point = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(posValue, .cgPoint, &point), AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: point, size: size)
    }

    private static func copyAttribute<T>(_ element: AXUIElement, _ attribute: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value else { return nil }
        if T.self == AXUIElement.self || T.self == AXValue.self {
            return (value as! T)
        }
        return value as? T
    }
}

extension CGRect {
    /// Converts a CoreGraphics global rect (top-left origin) to AppKit screen coordinates (bottom-left origin).
    var flippedToCocoa: CGRect {
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: minX, y: primaryHeight - maxY, width: width, height: height)
    }

    func inset(by insets: EdgeInsets) -> CGRect {
        CGRect(x: minX + insets.left, y: minY + insets.top,
               width: max(1, width - insets.left - insets.right),
               height: max(1, height - insets.top - insets.bottom))
    }
}
