import XCTest
@testable import WindowInvert

final class WindowStateTests: XCTestCase {
    private let bounds = CGRect(x: 100, y: 100, width: 800, height: 600)

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
            XCTAssertTrue(WindowLocator.isMissionControlActive(in: [surface], bundleIdentifierForPID: bundleID))
        }
        XCTAssertFalse(WindowLocator.isMissionControlActive(in: [], bundleIdentifierForPID: bundleID))
    }

    func testMissionControlIgnoresDockBarSpaceStripsAndOtherOwners() {
        for (pid, layer) in [(101, 20), (101, 19), (202, 14), (202, 0), (202, 18),
                             (303, 18), (303, 19), (404, 19), (0, 18), (-1, 19)] {
            let window: [String: Any] = [kCGWindowOwnerPID as String: NSNumber(value: pid),
                                         kCGWindowLayer as String: layer,
                                         kCGWindowOwnerName as String: "Dock"]
            XCTAssertFalse(WindowLocator.isMissionControlActive(in: [window], bundleIdentifierForPID: bundleID))
        }
        XCTAssertFalse(WindowLocator.isMissionControlActive(in: [[:]], bundleIdentifierForPID: bundleID))
    }

    func testMissionControlResolvesTheCurrentProcessInsteadOfCachingItsPID() {
        let window: [String: Any] = [kCGWindowOwnerPID as String: NSNumber(value: 505), kCGWindowLayer as String: 19]
        XCTAssertTrue(WindowLocator.isMissionControlActive(in: [window]) { pid in
            XCTAssertEqual(pid, 505)
            return "com.apple.WindowManager"
        })
        XCTAssertFalse(WindowLocator.isMissionControlActive(in: [window]) { _ in nil })
    }

    private func bundleID(for pid: pid_t) -> String? {
        [101: "com.apple.dock", 202: "com.apple.WindowManager", 303: "com.apple.Preview"][pid]
    }
}
