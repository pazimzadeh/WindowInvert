import AppKit

/// AppKit cannot query another app's Space membership or its pre-animation bounds.
/// Resolve these WindowServer functions at runtime so an unavailable symbol doesn't prevent launch.
enum WindowServer {
    private typealias MainConnection = @convention(c) () -> Int32
    private typealias GetBounds = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGRect>) -> Int32
    private typealias IsOrderedIn = @convention(c) (Int32, UInt32, UnsafeMutablePointer<Bool>) -> Int32
    private typealias CopySpaces = @convention(c) (Int32, Int32, CFArray) -> Unmanaged<CFArray>?
    private typealias ChangeSpaces = @convention(c) (Int32, CFArray, CFArray) -> Void
    private typealias SetTransform = @convention(c) (Int32, UInt32, CGAffineTransform) -> Int32
    private typealias GetTransform = @convention(c) (Int32, UInt32, UnsafeMutablePointer<CGAffineTransform>) -> Int32

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
    private static let setTransform = load("SLSSetWindowTransform", as: SetTransform.self)
    private static let getTransform = load("SLSGetWindowTransform", as: GetTransform.self)

    static func transform(of window: CGWindowID) -> CGAffineTransform? {
        guard let connection, let getTransform else { return nil }
        var transform = CGAffineTransform.identity
        guard getTransform(connection, window, &transform) == 0 else { return nil }
        return transform
    }

    static var canTransformWindows: Bool { connection != nil && getBounds != nil && setTransform != nil }

    static func presentationTransform(from source: CGRect, to destination: CGRect) -> CGAffineTransform {
        // WindowServer maps display coordinates back into the window's unscaled surface.
        CGAffineTransform(scaleX: source.width / destination.width, y: source.height / destination.height)
            .translatedBy(x: -destination.minX, y: -destination.minY)
    }

    static func present(_ window: CGWindowID, from source: CGRect, at destination: CGRect) -> Bool {
        guard let connection, let setTransform, source.width > 0, source.height > 0,
              destination.width > 0, destination.height > 0 else { return false }
        return setTransform(connection, window, presentationTransform(from: source, to: destination)) == 0
    }

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
