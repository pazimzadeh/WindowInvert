import XCTest
@testable import WindowInvert

final class PreferenceTests: XCTestCase {
    func testMissionControlInversionIsEnabledByDefault() throws {
        let name = "WindowInvertTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        InversionController.registerDefaults(in: defaults)

        XCTAssertFalse(defaults.bool(forKey: "hidesInMissionControl"))
        XCTAssertTrue(defaults.bool(forKey: "pausesBehindSheets"))
        XCTAssertNil(defaults.persistentDomain(forName: name)?["hidesInMissionControl"])
    }

    func testSavedMissionControlChoicesArePreserved() throws {
        let name = "WindowInvertTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }

        for hides in [true, false] {
            defaults.set(hides, forKey: "hidesInMissionControl")
            InversionController.registerDefaults(in: defaults)

            XCTAssertEqual(defaults.bool(forKey: "hidesInMissionControl"), hides)
            XCTAssertEqual(defaults.persistentDomain(forName: name)?["hidesInMissionControl"] as? Bool, hides)
        }
    }
}
