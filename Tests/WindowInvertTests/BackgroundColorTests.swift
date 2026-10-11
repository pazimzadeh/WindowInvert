import XCTest
@testable import WindowInvert

final class BackgroundColorTests: XCTestCase {
    private func rgb(_ r: Float, _ g: Float, _ b: Float) -> SIMD3<Float> {
        SIMD3(r, g, b) / 255
    }

    func testAcceptsBlueTintThatPreviouslyFailedNeutralGreyCheck() {
        let colour = rgb(35, 41, 48)
        XCTAssertGreaterThan(colour.max() - colour.min(), 0.05)
        XCTAssertEqual(InversionSession.backgroundColor(from: [colour, colour, colour]), SIMD4(colour, 1))
    }

    func testAcceptsExistingDarkGreysWithTwoAgreeingSamples() {
        for colour in [rgb(40, 40, 40), rgb(29, 34, 40)] {
            XCTAssertEqual(InversionSession.backgroundColor(from: [colour, rgb(255, 255, 255), colour]),
                           SIMD4(colour, 1))
        }
    }

    func testRejectsBlackLightAndStronglyColouredSamples() {
        for colour in [rgb(0, 0, 0), rgb(242, 242, 242), rgb(10, 20, 80)] {
            XCTAssertEqual(InversionSession.backgroundColor(from: [colour, colour, colour]), .zero)
        }
    }

    func testRequiresAtLeastTwoSamplesAndAMajority() {
        let colour = rgb(35, 41, 48)
        let cases: [[SIMD3<Float>]] = [[], [colour], [rgb(25, 25, 25), rgb(50, 50, 50), rgb(75, 75, 75)]]
        for samples in cases {
            XCTAssertEqual(InversionSession.backgroundColor(from: samples), .zero)
        }
    }
}
