import XCTest
@testable import VibeBarCore

final class DotResponseParserTests: XCTestCase {
    func testDevicesFromABareArray() throws {
        let json = #"[{"id":"0000AAAA0000","edition":2,"model":"quote_0","series":"quote","alias":"Desk"}]"#
        let devices = try DotResponseParser.devices(Data(json.utf8))
        XCTAssertEqual(devices, [DotDevice(id: "0000AAAA0000", alias: "Desk", model: "quote_0", series: "quote", edition: 2)])
        XCTAssertEqual(devices[0].profile, .quote0)
    }

    func testDevicesFromEveryKnownEnvelope() throws {
        for key in ["devices", "result", "data", "items"] {
            let json = "{\"\(key)\":[{\"id\":\"0000AAAA0000\"}]}"
            XCTAssertEqual(try DotResponseParser.devices(Data(json.utf8)).first?.id, "0000AAAA0000", key)
        }
    }

    func testUnknownModelLeavesTheProfileNil() throws {
        let devices = try DotResponseParser.devices(Data(#"[{"id":"0000AAAA0000","model":"quote_9"}]"#.utf8))
        XCTAssertNil(devices.first?.profile)
    }

    func testStatusFixture() throws {
        let json = """
        {
          "deviceId": "0000AAAA0000",
          "alias": "Desk",
          "location": null,
          "status": {"version": "2.0.8", "current": "Active on power",
                     "description": "ready", "battery": "On power", "wifi": "-49 dBm"},
          "renderInfo": {
            "last": "2026-01-01 05:14",
            "current": {"rotated": false, "border": 0,
                        "image": ["https://cdn.example.test/render/a.png", "https://cdn.example.test/render/b.png"]},
            "next": {"battery": "2026-01-01 08:14", "power": "2026-01-01 05:19"}
          }
        }
        """
        let status = try DotResponseParser.status(Data(json.utf8), deviceID: "fallback")
        XCTAssertEqual(status.deviceID, "0000AAAA0000")
        XCTAssertEqual(status.alias, "Desk")
        XCTAssertEqual(status.firmwareVersion, "2.0.8")
        XCTAssertEqual(status.current, "Active on power")
        XCTAssertEqual(status.battery, "On power")
        XCTAssertEqual(status.wifi, "-49 dBm")
        XCTAssertEqual(status.currentImageURL?.absoluteString, "https://cdn.example.test/render/a.png")
        XCTAssertEqual(status.lastRenderedLabel, "2026-01-01 05:14")
        XCTAssertEqual(status.nextPowerRefreshLabel, "2026-01-01 05:19")
        XCTAssertEqual(status.nextBatteryRefreshLabel, "2026-01-01 08:14")
    }

    func testStatusFallsBackToTheRequestedDeviceIDAndToleratesMissingSections() throws {
        let status = try DotResponseParser.status(Data("{}".utf8), deviceID: "0000AAAA0000")
        XCTAssertEqual(status.deviceID, "0000AAAA0000")
        XCTAssertNil(status.currentImageURL)
        XCTAssertEqual(status.battery, "")
    }

    func testTasksFixture() throws {
        let json = #"[{"key":"S0000AAAA0000","type":"CANVAS_API","taskAlias":"Vibe Bar"},{"type":"TEXT_API"}]"#
        let tasks = try DotResponseParser.tasks(Data(json.utf8))
        XCTAssertEqual(tasks.count, 1, "an entry without a key is not a usable task")
        XCTAssertEqual(tasks[0], DotTask(key: "S0000AAAA0000", type: "CANVAS_API", alias: "Vibe Bar"))
        XCTAssertTrue(tasks[0].isCanvasAPI)
    }

    func testMessageExtraction() {
        XCTAssertEqual(DotResponseParser.message(Data(#"{"message":"ok"}"#.utf8)), "ok")
        XCTAssertEqual(DotResponseParser.message(Data("garbage".utf8)), "")
    }

    func testNonJSONThrows() {
        XCTAssertThrowsError(try DotResponseParser.devices(Data("<html>".utf8))) { error in
            XCTAssertEqual(error as? DotResponseParser.ParseError, .notJSON)
        }
        XCTAssertThrowsError(try DotResponseParser.status(Data("[1,2]".utf8), deviceID: "x")) { error in
            XCTAssertEqual(error as? DotResponseParser.ParseError, .unexpectedShape)
        }
    }
}
