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
}
