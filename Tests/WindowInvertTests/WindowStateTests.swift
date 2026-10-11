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

    func testMissionControlDetectionRequiresDocksUnnamedOverviewSurface() {
        let surface: [String: Any] = [kCGWindowOwnerName as String: "Dock", kCGWindowLayer as String: 18]
        XCTAssertTrue(WindowLocator.isMissionControlActive(in: [surface]))
        XCTAssertFalse(WindowLocator.isMissionControlActive(in: []))
        for (key, value) in [(kCGWindowOwnerName as String, "Preview" as Any),
                             (kCGWindowLayer as String, 20 as Any),
                             (kCGWindowName as String, "Dock" as Any)] {
            var other = surface
            other[key] = value
            XCTAssertFalse(WindowLocator.isMissionControlActive(in: [other]))
        }
    }
}
