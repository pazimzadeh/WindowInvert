import XCTest
@testable import WindowInvert

final class MissionControlTraceTests: XCTestCase {
    func testRecordsDistinctGeometryAndOnlyWhitelistedMetadata() throws {
        let native = CGRect(x: 100, y: 50, width: 800, height: 600)
        let presented = CGRect(x: 200, y: 150, width: 400, height: 300)
        let info: [String: Any] = [kCGWindowNumber as String: NSNumber(value: 123),
                                   kCGWindowOwnerPID as String: NSNumber(value: 456),
                                   kCGWindowLayer as String: 0,
                                   kCGWindowIsOnscreen as String: true,
                                   kCGWindowAlpha as String: 1.0,
                                   kCGWindowBounds as String: presented.dictionaryRepresentation,
                                   kCGWindowName as String: "Private document title",
                                   kCGWindowOwnerName as String: "Private owner name"]
        let transform = CGAffineTransform(a: 2, b: 0, c: 0, d: 2, tx: -400, ty: -300)
        let row = MissionControlTrace.windowRecord(info: info, role: "target", nativeBounds: native,
                                                   transform: transform, orderedIn: true)
        let data = try JSONSerialization.data(withJSONObject: row)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(decoded["publicBounds"] as? [Double], [200, 150, 400, 300])
        XCTAssertEqual(decoded["nativeBounds"] as? [Double], [100, 50, 800, 600])
        XCTAssertEqual(decoded["transform"] as? [Double], [2, 0, 0, 2, -400, -300])
        XCTAssertEqual(decoded["id"] as? Int, 123)
        XCTAssertEqual(decoded["onScreen"] as? Bool, true)
        XCTAssertEqual(decoded["orderedIn"] as? Bool, true)
        XCTAssertEqual(Set(decoded.keys), ["role", "publicBounds", "nativeBounds", "transform", "orderedIn",
                                           "id", "pid", "layer", "onScreen", "alpha"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Private"))
    }

    func testUnavailableAndNonfiniteValuesRemainNullRatherThanLookingLikeMeasurements() throws {
        let invalid = CGAffineTransform(a: .infinity, b: 0, c: 0, d: 1, tx: 0, ty: 0)
        for transform in [nil, invalid] {
            let row = MissionControlTrace.windowRecord(info: [:], role: "target", nativeBounds: .null,
                                                       transform: transform, orderedIn: nil)
            XCTAssertTrue(JSONSerialization.isValidJSONObject(row))
            for key in ["publicBounds", "nativeBounds", "transform", "orderedIn", "id", "onScreen"] {
                XCTAssertTrue(row[key] is NSNull, key)
            }
        }
    }
}
