import AppKit

/// AppKit cannot query another app's Space membership or its pre-animation bounds.
/// Resolve these WindowServer functions at runtime so an unavailable symbol doesn't prevent launch.
enum WindowServer {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias GetBounds = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32
    private typealias IsOrderedIn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Bool>) -> Int32
    private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias ChangeSpaces = @convention(c) (Int32, CFArray, CFArray) -> Void

    private static let library = dlopen("/System/Library/PrivateFrameworks/SkyLight.framework/SkyLight", RTLD_LAZY)
    private static func load<T>(_ name: String, as type: T.Type) -> T? {
        guard let library, let symbol = dlsym(library, name) else { return nil }
        return unsafeBitCast(symbol, to: type)
    }

    private static let connection = load("SLSMainConnectionID", as: MainConnection.self)?()
    private static let getBounds = load("SLSGetWindowBounds", as: GetBounds.self)
    private static let isOrderedIn = load("SLSWindowIsOrderedIn", as: IsOrderedIn.self)
    private static let copySpaces = load("SLSCopySpacesForWindows", as: CopySpaces.self)
    private static let addSpaces = load("SLSAddWindowsToSpaces", as: ChangeSpaces.self)
    private static let removeSpaces = load("SLSRemoveWindowsFromSpaces", as: ChangeSpaces.self)

    static var isAvailable: Bool {
        connection != nil && getBounds != nil && isOrderedIn != nil
            && copySpaces != nil && addSpaces != nil && removeSpaces != nil
    }

    static func bounds(of window: CGWindowID) -> CGRect? {
        guard let connection, let getBounds else { return nil }
        var bounds = CGRect.zero
        guard getBounds(connection, window, &bounds) == 0,
              !bounds.isNull, !bounds.isInfinite, bounds.width > 0, bounds.height > 0 else { return nil }
        return bounds
    }

    static func orderedIn(_ window: CGWindowID) -> Bool? {
        guard let connection, let isOrderedIn else { return nil }
        var ordered = false
        guard isOrderedIn(connection, window, &ordered) == 0 else { return nil }
        return ordered
    }

    static func spaces(of window: CGWindowID) -> Set<UInt64>? {
        guard let connection, let copySpaces,
              let values = copySpaces(connection, 7, [NSNumber(value: window)] as CFArray)?.takeRetainedValue()
                as? [NSNumber], !values.isEmpty else { return nil }
        return Set(values.map(\.uint64Value))
    }

    static func matchSpaces(of overlay: CGWindowID, to target: CGWindowID) {
        guard let connection, let addSpaces, let removeSpaces,
              let desired = spaces(of: target), let current = spaces(of: overlay), current != desired else { return }
        let windows = [NSNumber(value: overlay)] as CFArray
        let missing = desired.subtracting(current)
        if !missing.isEmpty {
            addSpaces(connection, windows, missing.map { NSNumber(value: $0) } as CFArray)
        }
        // Don't remove the old membership unless the destination accepted the overlay.
        guard let updated = spaces(of: overlay), desired.isSubset(of: updated) else { return }
        let extra = updated.subtracting(desired)
        if !extra.isEmpty {
            removeSpaces(connection, windows, extra.map { NSNumber(value: $0) } as CFArray)
        }
    }
}
