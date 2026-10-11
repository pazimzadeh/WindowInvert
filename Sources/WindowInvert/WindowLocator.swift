import AppKit
import ApplicationServices

@_silgen_name("_AXUIElementGetWindow")
private func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: UnsafeMutablePointer<CGWindowID>) -> AXError


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
    let isOrderedIn: Bool
    var presentedBounds: CGRect? = nil

    var isVisibleInItsSpace: Bool {
        isOrderedIn && bounds.width > 1 && bounds.height > 1
    }

    var hasOverviewScale: Bool {
        guard isOnScreen, isVisibleInItsSpace, let presentedBounds,
              bounds.width.isFinite, bounds.height.isFinite,
              presentedBounds.width > 1, presentedBounds.height > 1,
              presentedBounds.width < bounds.width, presentedBounds.height < bounds.height else { return false }
        // Public bounds round to whole points. Require a uniform shrink within that rounding.
        let minimumScale = max((presentedBounds.width - 1) / bounds.width,
                               (presentedBounds.height - 1) / bounds.height)
        let maximumScale = min((presentedBounds.width + 1) / bounds.width,
                               (presentedBounds.height + 1) / bounds.height)
        return minimumScale <= maximumScale
    }

    func displayBounds(for rect: CGRect, inMissionControl: Bool) -> CGRect {
        guard inMissionControl, let presentedBounds, bounds.width > 0, bounds.height > 0 else { return rect }
        let sx = presentedBounds.width / bounds.width
        let sy = presentedBounds.height / bounds.height
        return CGRect(x: presentedBounds.minX + (rect.minX - bounds.minX) * sx,
                      y: presentedBounds.minY + (rect.minY - bounds.minY) * sy,
                      width: rect.width * sx, height: rect.height * sy)
    }
}

struct MissionControlState {
    var overviewVisible = false
    var spacesStripVisible = false

    func isActive(for window: WindowState, wasActive: Bool) -> Bool {
        // The overview surface arrives after an interactive gesture has already begun.
        // Latch through the return animation, including cancelled partial gestures.
        overviewVisible || (spacesStripVisible && (wasActive || window.hasOverviewScale))
    }
}

enum WindowLocator {
    static func frontmostWindow() -> TargetWindow? {
        // On macOS 27 NSWorkspace sometimes reports no front app (or WindowInvert) while Preview is in front.
        let reported = NSWorkspace.shared.frontmostApplication.flatMap { $0.processIdentifier == getpid() ? nil : $0 }
        var pid: pid_t
        if let reported {
            guard let resolved = resolvePID(of: reported) else {
                Log.write("could not resolve a process for \(reported.bundleIdentifier ?? "?") (reported pid \(reported.processIdentifier))")
                return nil
            }
            pid = resolved
        } else if let owner = frontWindowOwner() {
            Log.write("no other frontmost app reported; using front window owner pid \(owner)")
            pid = owner
        } else {
            Log.write("no frontmost app (or WindowInvert itself is frontmost)")
            return nil
        }
        let app = reported ?? NSRunningApplication(processIdentifier: pid)
        var candidates = onScreenWindows(of: pid)
        // The bundle-ID lookup can land on a helper process with no windows; use the window list then.
        if (app?.processIdentifier ?? 0) <= 0, !candidates.contains(where: isDocumentWindow), let owner = frontWindowOwner(), owner != pid {
            Log.write("pid \(pid) has no usable window; using front window owner pid \(owner)")
            pid = owner
            candidates = onScreenWindows(of: pid)
        }
        Log.write("frontmost app \(app?.bundleIdentifier ?? "?") pid=\(pid) (reported \(app?.processIdentifier ?? 0)); on-screen windows: "
                  + candidates.map { "\($0.id) layer=\($0.layer) \($0.bounds) '\($0.title)'" }.joined(separator: "; "))

        var axWindows: [AXUIElement] = []
        if AXIsProcessTrusted() {
            let axApp = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(axApp, 0.5)
            let focused: AXUIElement? = copyAttribute(axApp, kAXFocusedWindowAttribute)
            let main: AXUIElement? = copyAttribute(axApp, kAXMainWindowAttribute)
            let all: [AXUIElement] = copyAttribute(axApp, kAXWindowsAttribute) ?? []
            axWindows = [main, focused].compactMap { $0 } + all
            // Prefer the main (document) window over the focused one, which may be a sheet or panel,
            // but only if the window server says it's a visible, normal window.
            for window in [main, focused].compactMap({ $0 }) {
                let id = windowID(of: window)
                Log.write("AX focused/main window id=\(id)")
                if id != 0, candidates.contains(where: { $0.id == id && $0.layer == 0 }) {
                    return TargetWindow(windowID: id, pid: pid, axWindow: window)
                }
            }
        }

        // Fallback: the front-most normal-layer window owned by the front app (list is front to back).
        guard let pick = candidates.first(where: isDocumentWindow) else {
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
        return frontWindowOwner()
    }

    private static func isDocumentWindow(_ window: WindowInfo) -> Bool {
        window.layer == 0 && window.bounds.width > 40 && window.bounds.height > 40
    }

    private static func frontWindowOwner() -> pid_t? {
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
        // The public bounds include the Spaces slide. Applying them to an overlay that the
        // compositor is also sliding moves it twice; use the window's underlying bounds instead.
        return WindowState(bounds: WindowServer.bounds(of: windowID) ?? bounds, isOnScreen: onScreen,
                           isOrderedIn: WindowServer.orderedIn(windowID) ?? onScreen, presentedBounds: bounds)
    }

    static func missionControlState() -> MissionControlState {
        guard let windows = CGWindowListCopyWindowInfo(.optionOnScreenOnly, kCGNullWindowID) as? [[String: Any]] else {
            return MissionControlState()
        }
        return missionControlState(in: windows) { pid in
            NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
        }
    }

    static func missionControlState(in windows: [[String: Any]],
                                    bundleIdentifierForPID: (pid_t) -> String?) -> MissionControlState {
        // macOS 27 moved the overview from Dock (18) to WindowManager (19).
        // Resolve the actual owner: display names are localized and processes can restart.
        var state = MissionControlState()
        for window in windows {
            guard let layer = window[kCGWindowLayer as String] as? Int, [14, 18, 19].contains(layer),
                  let pid = window[kCGWindowOwnerPID as String] as? pid_t, pid > 0,
                  let bundleID = bundleIdentifierForPID(pid) else { continue }
            if (layer == 18 && bundleID == "com.apple.dock") || (layer == 19 && bundleID == "com.apple.WindowManager") {
                state.overviewVisible = true
            }
            if layer == 14 && bundleID == "com.apple.WindowManager" {
                state.spacesStripVisible = true
            }
        }
        return state
    }

    struct StackedWindow {
        let id: CGWindowID
        let pid: pid_t
        let layer: Int
        let bounds: CGRect
        let title: String
    }

    /// On-screen windows that are above `windowID`, ordered front to back.
    static func windowsAbove(_ windowID: CGWindowID) -> [StackedWindow] {
        guard let list = CGWindowListCopyWindowInfo(.optionOnScreenAboveWindow, windowID) as? [[String: Any]] else {
            return []
        }
        return list.compactMap { info in
            guard let id = info[kCGWindowNumber as String] as? CGWindowID,
                  let pid = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict) else { return nil }
            return StackedWindow(id: id, pid: pid, layer: info[kCGWindowLayer as String] as? Int ?? 0,
                                 bounds: WindowServer.bounds(of: id) ?? bounds,
                                 title: info[kCGWindowName as String] as? String ?? "")
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

    /// Points (global, top-left origin) in the margin beside a document's pages, e.g. Preview's dark
    /// background around PDF pages, so that colour can be left un-inverted. Empty if there are no
    /// AXPage elements or no usable margin.
    /// Points in the gutter beside the pages of a PDF view, plus the scroll area they belong to.
    static func backgroundSamplePoints(in window: AXUIElement) -> (points: [CGPoint], area: CGRect) {
        AXUIElementSetMessagingTimeout(window, 0.2)
        var queue: [(element: AXUIElement, depth: Int, scroll: CGRect?)] = [(window, 0, nil)]
        var visited = 0
        var pageScroll: CGRect?
        var pages: [CGRect] = []
        while !queue.isEmpty, visited < 300 {
            let (element, depth, scroll) = queue.removeFirst()
            visited += 1
            let role: String? = copyAttribute(element, kAXRoleAttribute)
            if role == "AXPage" {
                if let scroll, pageScroll == nil || pageScroll == scroll, let page = frame(of: element) {
                    pageScroll = scroll
                    pages.append(page)
                }
                continue
            }
            let childScroll = role == "AXScrollArea" ? frame(of: element) : scroll
            guard depth < 6, let children: [AXUIElement] = copyAttribute(element, kAXChildrenAttribute) else { continue }
            queue.append(contentsOf: children.map { ($0, depth + 1, childScroll) })
        }
        guard let absScroll = pageScroll, let win = frame(of: window) else { return ([], .null) }
        // Relative to the window's top-left, so the points stay valid while the window moves.
        let scroll = absScroll.offsetBy(dx: -win.minX, dy: -win.minY)
        let relPages = pages.map { $0.offsetBy(dx: -win.minX, dy: -win.minY) }
        let visible = relPages.filter { $0.intersects(scroll) }
        guard let minX = visible.map(\.minX).min(), let maxX = visible.map(\.maxX).max() else { return ([], .null) }
        let left = minX - scroll.minX
        let right = scroll.maxX - maxX
        if max(left, right) >= 6 {
            let x = left >= right ? scroll.minX + left / 2 : scroll.maxX - right / 2
            return ([0.25, 0.5, 0.75].map { CGPoint(x: x, y: scroll.minY + scroll.height * $0) }, scroll)
        }
        // Pages fill the width: sample the gap between two pages instead.
        let sorted = visible.sorted { $0.minY < $1.minY }
        for (upper, lower) in zip(sorted, sorted.dropFirst()) where lower.minY - upper.maxY >= 6 {
            let y = (upper.maxY + lower.minY) / 2
            guard y > scroll.minY + 2, y < scroll.maxY - 2 else { continue }
            return ([0.25, 0.5, 0.75].map { CGPoint(x: scroll.minX + scroll.width * $0, y: y) }, scroll)
        }
        return ([], scroll)
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
