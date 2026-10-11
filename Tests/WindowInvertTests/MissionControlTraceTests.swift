import XCTest
@testable import WindowInvert

final class MissionControlTraceTests: XCTestCase {
    func testActivationTraceSerializesSessionStateAndEventsAndFinishes() {
        let finished = expectation(description: "Trace finishes and writes valid JSON")
        let trace = MissionControlTrace(targets: [123: 456], hidesInMissionControl: false, freezesImage: true)
        trace.recordSessionState(target: 123, state: ["submittedDraws": 17, "freezeRequested": true,
                                                     "lastDrawSubmitted": NSNull()])
        trace.recordActivation(source: "test", pids: [789], window: 123)
        trace.start { result in
            do {
                let url = try result.get()
                defer { try? FileManager.default.removeItem(at: url) }
                let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
                XCTAssertEqual(json["formatVersion"] as? Int, 3)
                XCTAssertEqual(json["freezesImage"] as? Bool, true)
                XCTAssertEqual(json["sampleInterval"] as? Double, 1.0 / 120)
                let events = try XCTUnwrap(json["activationEvents"] as? [[String: Any]])
                XCTAssertEqual(events.count, 1)
                XCTAssertEqual(events.first?["window"] as? Int, 123)
                XCTAssertEqual(events.first?["pids"] as? [Int], [789])
                let samples = try XCTUnwrap(json["samples"] as? [[String: Any]])
                XCTAssertFalse(samples.isEmpty)
                for sample in samples {
                    let states = try XCTUnwrap(sample["sessionStates"] as? [[String: Any]])
                    XCTAssertEqual(states.first?["target"] as? Int, 123)
                    XCTAssertEqual(states.first?["submittedDraws"] as? Int, 17)
                    XCTAssertEqual(states.first?["freezeRequested"] as? Bool, true)
                }
            } catch { XCTFail("\(error)") }
            finished.fulfill()
        }
        wait(for: [finished], timeout: 30)
        withExtendedLifetime(trace) {}
    }

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
                                                   transform: transform, orderedIn: true, orderIndex: 7)
        let data = try JSONSerialization.data(withJSONObject: row)
        let decoded = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(decoded["publicBounds"] as? [Double], [200, 150, 400, 300])
        XCTAssertEqual(decoded["nativeBounds"] as? [Double], [100, 50, 800, 600])
        XCTAssertEqual(decoded["transform"] as? [Double], [2, 0, 0, 2, -400, -300])
        XCTAssertEqual(decoded["id"] as? Int, 123)
        XCTAssertEqual(decoded["onScreen"] as? Bool, true)
        XCTAssertEqual(decoded["orderedIn"] as? Bool, true)
        XCTAssertEqual(decoded["orderIndex"] as? Int, 7)
        XCTAssertEqual(Set(decoded.keys), ["role", "publicBounds", "nativeBounds", "transform", "orderedIn",
                                           "id", "pid", "layer", "onScreen", "alpha", "orderIndex"])
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("Private"))
    }

    func testUnavailableAndNonfiniteValuesRemainNullRatherThanLookingLikeMeasurements() throws {
        let invalid = CGAffineTransform(a: .infinity, b: 0, c: 0, d: 1, tx: 0, ty: 0)
        for transform in [nil, invalid] {
            let row = MissionControlTrace.windowRecord(info: [:], role: "target", nativeBounds: .null,
                                                       transform: transform, orderedIn: nil)
            XCTAssertTrue(JSONSerialization.isValidJSONObject(row))
            for key in ["publicBounds", "nativeBounds", "transform", "orderedIn", "id", "onScreen", "orderIndex"] {
                XCTAssertTrue(row[key] is NSNull, key)
            }
        }
    }

    func testFrozenDiagnosticReusesOnlyAnExistingVisibleImageAtTheSameSizeAndPosition() {
        XCTAssertTrue(InversionSession.reusesImageForDiagnostics(requested: true, hasImage: true,
                                                                 visible: true, frameMatches: true))
        for flags in [[false, true, true, true], [true, false, true, true],
                      [true, true, false, true], [true, true, true, false]] {
            XCTAssertFalse(InversionSession.reusesImageForDiagnostics(requested: flags[0], hasImage: flags[1],
                                                                      visible: flags[2], frameMatches: flags[3]))
        }
    }
}
