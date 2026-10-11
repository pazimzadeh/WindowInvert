import XCTest
@testable import WindowInvert

final class OverlayActivationTests: XCTestCase {
    func testActivationBridgesStaleOrderUntilWindowReachesFront() {
        var activation = OverlayActivation()
        XCTAssertEqual(activation.level(aboveWindowsLevel: .normal, at: 0), .normal)
        activation.begin(at: 1)
        XCTAssertEqual(activation.level(aboveWindowsLevel: .normal, at: 1.1), .floating)
        XCTAssertEqual(activation.level(aboveWindowsLevel: .floating, at: 1.12), .floating)
        // Once settled, Settings or another window must cover the inversion immediately.
        XCTAssertEqual(activation.level(aboveWindowsLevel: .normal, at: 1.13), .normal)
    }

    func testCancelledOrFailedActivationCannotKeepOverlayFloating() {
        var activation = OverlayActivation()
        activation.begin(at: 1)
        activation.cancel()
        XCTAssertEqual(activation.level(aboveWindowsLevel: .normal, at: 1.01), .normal)
        activation.begin(at: 2)
        XCTAssertEqual(activation.level(aboveWindowsLevel: .normal, at: 2.25), .normal)
        XCTAssertEqual(activation.level(aboveWindowsLevel: .normal, at: 2.3), .normal)
    }
}
