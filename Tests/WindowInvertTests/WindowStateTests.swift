import XCTest
@testable import WindowInvert

final class WindowStateTests: XCTestCase {
    private let bounds = CGRect(x: 100, y: 100, width: 800, height: 600)

    func testSettingsAndOtherAppsLowerTheOverlay() {
        let overlay = WindowLocator.StackedWindow(id: 1, pid: 20, layer: 0, bounds: bounds, title: "")
        for pid in [pid_t(20), pid_t(30)] {
            let covering = WindowLocator.StackedWindow(id: 2, pid: pid, layer: 0, bounds: bounds, title: "")
            XCTAssertEqual(WindowLocator.overlayLevel(above: [overlay, covering], targetPID: 10,
                                                       overlayWindowIDs: [1]), .normal)
        }
    }

    func testOtherInversionOverlaysDoNotLowerTheOverlay() {
        let overlays = [1, 2].map {
            WindowLocator.StackedWindow(id: CGWindowID($0), pid: 20, layer: 0, bounds: bounds, title: "")
        }
        XCTAssertEqual(WindowLocator.overlayLevel(above: overlays, targetPID: 10,
                                                   overlayWindowIDs: [1, 2]), .floating)
        XCTAssertEqual(WindowLocator.overlayLevel(above: [], targetPID: 10,
                                                   overlayWindowIDs: [1, 2]), .floating)
    }

    func testLeavingTheScreenForAnotherSpaceDoesNotHideTheOverlay() {
        for onScreen in [true, false] {
            let state = WindowState(bounds: bounds, isOnScreen: onScreen, isOrderedIn: true)
            XCTAssertTrue(state.isVisibleInItsSpace)
        }
    }

    func testHiddenOrMinimizedWindowsStillHideTheOverlay() {
        for onScreen in [true, false] {
            let state = WindowState(bounds: bounds, isOnScreen: onScreen, isOrderedIn: false)
            XCTAssertFalse(state.isVisibleInItsSpace)
        }
    }

    func testDegenerateWindowsDoNotShowAnOverlay() {
        for rect in [CGRect.zero, CGRect(x: 0, y: 0, width: 1, height: 600),
                     CGRect(x: 0, y: 0, width: 800, height: 1)] {
            XCTAssertFalse(WindowState(bounds: rect, isOnScreen: true, isOrderedIn: true).isVisibleInItsSpace)
        }
    }

    func testSpaceSlideDoesNotChangeOverlayGeometry() {
        let state = WindowState(bounds: bounds, isOnScreen: true, isOrderedIn: true,
                                presentedBounds: bounds.offsetBy(dx: -400, dy: 0))
        XCTAssertEqual(state.displayBounds(for: bounds, inMissionControl: false), bounds)
    }

    func testMissionControlProjectsWholeWindowAndContentInsets() {
        let presented = CGRect(x: 20, y: 200, width: 400, height: 300)
        let state = WindowState(bounds: bounds, isOnScreen: true, isOrderedIn: true, presentedBounds: presented)
        XCTAssertEqual(state.displayBounds(for: bounds, inMissionControl: true), presented)
        let content = CGRect(x: 200, y: 150, width: 700, height: 550)
        XCTAssertEqual(state.displayBounds(for: content, inMissionControl: true),
                       CGRect(x: 70, y: 225, width: 350, height: 275))
        XCTAssertEqual(state.displayBounds(for: content, inMissionControl: false), content)
    }

    func testSpaceSwipeInsideOverviewDoesNotApplyDesktopTranslationTwice() {
        let native = CGRect(x: 862, y: 33, width: 864, height: 1084)
        let thumbnail = CGRect(x: 1264, y: 110, width: 446, height: 560)
        let desktop = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let content = native.insetBy(dx: 40, dy: 80)
        let resting = WindowState(bounds: native, isOnScreen: true, isOrderedIn: true, presentedBounds: thumbnail)
        // macOS 27 trace: partial swipe/cancel, completed swipe, off-Space, then return.
        for (targetX, desktopX, onScreen) in [(1146.0, -118.0, true), (1677, 413, true),
                                             (3055, 1791, true), (1264, 0, false),
                                             (3030, 1766, true), (2907, 1643, true), (1264, 0, true)] {
            let translation = WindowLocator.spaceTranslation(native: desktop, presented: desktop.offsetBy(dx: desktopX, dy: 0))
            let state = WindowState(bounds: native, isOnScreen: onScreen, isOrderedIn: true,
                                    presentedBounds: CGRect(x: targetX, y: 110, width: 446, height: 560),
                                    spaceTranslation: translation)
            XCTAssertEqual(state.displayBounds(for: native, inMissionControl: true), thumbnail)
            XCTAssertEqual(state.displayBounds(for: content, inMissionControl: true),
                           resting.displayBounds(for: content, inMissionControl: true))
            XCTAssertEqual(state.displayBounds(for: native, inMissionControl: false), native)
            XCTAssertEqual(state.displayBounds(for: content, inMissionControl: false), content)
        }
    }

    func testSpaceTranslationRejectsScaledOrMissingReferenceGeometry() {
        let desktop = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        for presented in [CGRect.null, .zero, CGRect(x: 100, y: 20, width: 864, height: 558)] {
            XCTAssertNil(WindowLocator.spaceTranslation(native: desktop, presented: presented))
        }
        XCTAssertNil(WindowLocator.spaceTranslation(native: .null, presented: desktop))
    }

    func testShowDesktopTracksWindowAndContentWithoutAnOverviewSignal() {
        let content = bounds.insetBy(dx: 30, dy: 50)
        for offset in [CGPoint(x: -300, y: -80), CGPoint(x: -900, y: -200),
                       CGPoint(x: -300, y: -80), .zero] {
            let state = WindowState(bounds: bounds, isOnScreen: offset.x > -800, isOrderedIn: true,
                                    presentedBounds: bounds.offsetBy(dx: offset.x, dy: offset.y),
                                    spaceTranslation: .zero)
            XCTAssertEqual(state.hasDesktopDisplacement, offset != .zero)
            XCTAssertEqual(state.displayBounds(for: bounds, inMissionControl: false),
                           bounds.offsetBy(dx: offset.x, dy: offset.y))
            XCTAssertEqual(state.displayBounds(for: content, inMissionControl: false),
                           content.offsetBy(dx: offset.x, dy: offset.y))
        }
    }

    func testShowDesktopSeparatesWindowMotionFromSpaceMotion() {
        for slide in [-1700.0, -200, 0, 200, 1700] {
            var state = WindowState(bounds: bounds, isOnScreen: true, isOrderedIn: true,
                                    presentedBounds: bounds.offsetBy(dx: slide, dy: 0),
                                    spaceTranslation: CGPoint(x: slide, y: 0))
            XCTAssertFalse(state.hasDesktopDisplacement)
            XCTAssertEqual(state.displayBounds(for: bounds, inMissionControl: false), bounds)
            state.presentedBounds = bounds.offsetBy(dx: slide - 500, dy: -100)
            XCTAssertTrue(state.hasDesktopDisplacement)
            XCTAssertEqual(state.displayBounds(for: bounds, inMissionControl: false),
                           bounds.offsetBy(dx: -500, dy: -100))
        }
    }

    func testDesktopDisplacementRequiresAReferenceAndIgnoresThumbnailScaleAndRounding() {
        var state = WindowState(bounds: bounds, isOnScreen: true, isOrderedIn: true,
                                presentedBounds: bounds.offsetBy(dx: -500, dy: -100))
        XCTAssertFalse(state.hasDesktopDisplacement)
        XCTAssertEqual(state.displayBounds(for: bounds, inMissionControl: false), bounds)
        state.spaceTranslation = .zero
        state.presentedBounds = CGRect(x: 20, y: 200, width: 400, height: 300)
        XCTAssertFalse(state.hasDesktopDisplacement)
        state.presentedBounds = bounds.offsetBy(dx: 1, dy: -1)
        XCTAssertFalse(state.hasDesktopDisplacement)
    }

    func testWindowManagerSpaceReferenceMatchesSpaceAndScreenAndIgnoresDock() {
        let desktop = CGRect(x: 0, y: 0, width: 1728, height: 1117)
        let wallpaperLevel = Int(CGWindowLevelForKey(.desktopWindow)) - 1
        let candidates: [[String: Any]] = [(1, 101, wallpaperLevel), (2, 202, wallpaperLevel),
                                          (3, 303, wallpaperLevel), (4, 202, 19), (5, 202, wallpaperLevel)].map { id, pid, layer in
            [kCGWindowNumber as String: NSNumber(value: id),
             kCGWindowOwnerPID as String: NSNumber(value: pid),
             kCGWindowLayer as String: layer]
        }
        let spaces: [CGWindowID: Set<UInt64>] = [1: [11], 2: [22], 3: [33], 4: [33], 5: [22]]
        func reference(for targetSpaces: Set<UInt64>) -> CGWindowID? {
            WindowLocator.spaceReferenceWindow(in: candidates, targetSpaces: targetSpaces, targetBounds: bounds,
                                              bundleIdentifierForPID: bundleID,
                                              boundsForWindow: { $0 == 2 ? desktop.offsetBy(dx: 1728, dy: 0) : desktop },
                                              spacesForWindow: { spaces[$0] })
        }
        XCTAssertNil(reference(for: [11]))
        XCTAssertEqual(reference(for: [22]), 5)
        XCTAssertNil(reference(for: [33]))
        XCTAssertNil(reference(for: []))
    }

    func testWindowServerTransformMapsThumbnailBackToNativeSurface() {
        let thumbnail = CGRect(x: 20, y: 200, width: 400, height: 300)
        let transform = WindowServer.presentationTransform(from: bounds, to: thumbnail)
        XCTAssertEqual(thumbnail.applying(transform), CGRect(origin: .zero, size: bounds.size))
        XCTAssertEqual(CGRect(origin: .zero, size: bounds.size).applying(transform.inverted()), thumbnail)
    }

    func testRestoringWindowServerTransformRemovesOverviewScale() {
        let transform = WindowServer.presentationTransform(from: bounds, to: bounds)
        XCTAssertEqual(transform.a, 1)
        XCTAssertEqual(transform.d, 1)
        XCTAssertEqual(bounds.applying(transform), CGRect(origin: .zero, size: bounds.size))
    }

    func testMissionControlRecognizesBothCompositorsWithoutEnglishNames() {
        for (pid, layer) in [(101, 18), (202, 19)] {
            let surface: [String: Any] = [kCGWindowOwnerPID as String: NSNumber(value: pid),
                                          kCGWindowLayer as String: layer,
                                          kCGWindowOwnerName as String: "Localized name",
                                          kCGWindowName as String: "Overview"]
            XCTAssertTrue(WindowLocator.missionControlState(in: [surface], bundleIdentifierForPID: bundleID).overviewVisible)
        }
        XCTAssertFalse(WindowLocator.missionControlState(in: [], bundleIdentifierForPID: bundleID).overviewVisible)
    }

    func testMissionControlIgnoresDockBarSpaceStripsAndOtherOwners() {
        for (pid, layer) in [(101, 20), (101, 19), (202, 14), (202, 0), (202, 18),
                             (303, 18), (303, 19), (404, 19), (0, 18), (-1, 19)] {
            let window: [String: Any] = [kCGWindowOwnerPID as String: NSNumber(value: pid),
                                         kCGWindowLayer as String: layer,
                                         kCGWindowOwnerName as String: "Dock"]
            XCTAssertFalse(WindowLocator.missionControlState(in: [window], bundleIdentifierForPID: bundleID).overviewVisible)
        }
        XCTAssertFalse(WindowLocator.missionControlState(in: [[:]], bundleIdentifierForPID: bundleID).overviewVisible)
    }

    func testMissionControlResolvesTheCurrentProcessInsteadOfCachingItsPID() {
        let window: [String: Any] = [kCGWindowOwnerPID as String: NSNumber(value: 505), kCGWindowLayer as String: 19]
        XCTAssertTrue(WindowLocator.missionControlState(in: [window]) { pid in
            XCTAssertEqual(pid, 505)
            return "com.apple.WindowManager"
        }.overviewVisible)
        XCTAssertFalse(WindowLocator.missionControlState(in: [window]) { _ in nil }.overviewVisible)
    }

    func testPartialGestureStartsBeforeOverviewAndStaysActiveUntilStripCloses() {
        let native = CGRect(x: 862, y: 33, width: 864, height: 1084)
        let resting = WindowState(bounds: native, isOnScreen: true, isOrderedIn: true, presentedBounds: native)
        // First shrinking frame from the macOS 27 trace; no layer-19 overview appeared during this gesture.
        let partial = WindowState(bounds: native, isOnScreen: true, isOrderedIn: true,
                                  presentedBounds: CGRect(x: 867, y: 34, width: 859, height: 1078))
        let strip = MissionControlState(spacesStripVisible: true)
        XCTAssertFalse(strip.isActive(for: resting, wasActive: false))
        XCTAssertTrue(strip.isActive(for: partial, wasActive: false))
        XCTAssertTrue(strip.isActive(for: partial, wasActive: true))
        XCTAssertTrue(strip.isActive(for: resting, wasActive: true))
        XCTAssertFalse(MissionControlState().isActive(for: resting, wasActive: true))
    }

    func testOverviewExitTracksReturnAfterOverviewSurfaceDisappears() {
        let resting = WindowState(bounds: bounds, isOnScreen: true, isOrderedIn: true, presentedBounds: bounds)
        let thumbnail = WindowState(bounds: bounds, isOnScreen: true, isOrderedIn: true,
                                    presentedBounds: CGRect(x: 20, y: 200, width: 400, height: 300))
        XCTAssertTrue(MissionControlState(overviewVisible: true).isActive(for: thumbnail, wasActive: false))
        let strip = MissionControlState(spacesStripVisible: true)
        XCTAssertTrue(strip.isActive(for: thumbnail, wasActive: true))
        XCTAssertTrue(strip.isActive(for: resting, wasActive: true))
        XCTAssertFalse(MissionControlState().isActive(for: resting, wasActive: true))
    }

    func testStripAndUniformShrinkAreBothRequiredToStartGesture() {
        let strip = MissionControlState(spacesStripVisible: true)
        for presented in [bounds, bounds.offsetBy(dx: -400, dy: 0),
                          CGRect(x: 100, y: 100, width: 400, height: 500)] {
            let state = WindowState(bounds: bounds, isOnScreen: true, isOrderedIn: true, presentedBounds: presented)
            XCTAssertFalse(strip.isActive(for: state, wasActive: false))
        }
        let resized = CGRect(x: 100, y: 100, width: 400, height: 300)
        let resize = WindowState(bounds: resized, isOnScreen: true, isOrderedIn: true, presentedBounds: resized)
        XCTAssertFalse(strip.isActive(for: resize, wasActive: false))
        let scaled = WindowState(bounds: bounds, isOnScreen: true, isOrderedIn: true, presentedBounds: resized)
        XCTAssertFalse(MissionControlState().isActive(for: scaled, wasActive: false))
        XCTAssertTrue(strip.isActive(for: scaled, wasActive: false))
        XCTAssertFalse(strip.isActive(for: WindowState(bounds: bounds, isOnScreen: true, isOrderedIn: true),
                                      wasActive: false))
    }

    func testWindowManagerStripIsDistinctFromTheSettledOverview() {
        for pid in [101, 202, 303] {
            let strip: [String: Any] = [kCGWindowOwnerPID as String: NSNumber(value: pid),
                                        kCGWindowLayer as String: 14]
            let state = WindowLocator.missionControlState(in: [strip], bundleIdentifierForPID: bundleID)
            XCTAssertEqual(state.spacesStripVisible, pid == 202)
            XCTAssertFalse(state.overviewVisible)
        }
    }

    private func bundleID(for pid: pid_t) -> String? {
        [101: "com.apple.dock", 202: "com.apple.WindowManager", 303: "com.apple.Preview"][pid]
    }
}
