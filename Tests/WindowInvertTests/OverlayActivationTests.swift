import XCTest
@testable import WindowInvert

final class OverlayActivationTests: XCTestCase {
    private let preview = TargetWindow(windowID: 51275, pid: 2928, axWindow: nil,
                                       bundleIdentifier: "com.apple.Preview")

    func testActivationUsesKnownWindowOwnerWhenWorkspaceReportsInvalidPID() {
        XCTAssertEqual(WindowLocator.activationPIDs(reportedPID: -1, bundleIdentifier: "com.apple.Preview",
            runningPIDs: [-1], knownTargets: [preview]), [2928])
    }

    func testActivationIncludesKnownOwnerAlongsideWindowlessHelperProcess() {
        XCTAssertEqual(WindowLocator.activationPIDs(reportedPID: 99, bundleIdentifier: "com.apple.Preview",
            runningPIDs: [99, -1], knownTargets: [preview]), [99, 2928])
    }

    func testActivationDoesNotBorrowAnotherAppsWindowOwnerOrMatchUnknownIdentity() {
        XCTAssertEqual(WindowLocator.activationPIDs(reportedPID: 50, bundleIdentifier: "com.apple.finder",
            runningPIDs: [50], knownTargets: [preview]), [50])
        let unknown = TargetWindow(windowID: 9, pid: 90, axWindow: nil, bundleIdentifier: nil)
        XCTAssertTrue(WindowLocator.activationPIDs(reportedPID: -1, bundleIdentifier: nil,
            runningPIDs: [], knownTargets: [preview, unknown]).isEmpty)
    }

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
