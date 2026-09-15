import XCTest
@testable import CodexUsageCore

final class AccountUsageParserTests: XCTestCase {
    func testJSONNumericZeroAndOneAreNotBooleans() throws {
        for (literal, expected) in [("0", 0.0), ("1", 1.0), ("0.0", 0.0), ("1.0", 1.0)] {
            let data = Data("{\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":\(literal),\"windowDurationMins\":1,\"resetsAt\":0}}}}".utf8)
            let message = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            let result = AccountUsageParser.parse(message: message, mergingWith: nil)
            XCTAssertEqual(result?.windows.first?.usedPercent, expected, literal)
            XCTAssertEqual(result?.windows.first?.durationMinutes, 1)
            XCTAssertEqual(result?.windows.first?.resetsAt, Date(timeIntervalSince1970: 0))
        }
        for literal in ["true", "false"] {
            let data = Data("{\"result\":{\"rateLimits\":{\"primary\":{\"usedPercent\":\(literal)}}}}".utf8)
            let message = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertNil(AccountUsageParser.parse(message: message, mergingWith: nil))
        }
    }
    func testParsesPrimaryAndSecondaryWindows() throws {
        let message: [String: Any] = [
            "id": 7,
            "result": [
                "rateLimits": [
                    "primary": ["usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1_800_000_000],
                    "secondary": ["usedPercent": 40, "windowDurationMins": 10_080, "resetsAt": 1_800_604_800],
                    "planType": "plus"
                ]
            ]
        ]
        let result = AccountUsageParser.parse(message: message, mergingWith: nil, now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(result?.windows.map(\.remainingPercent), [75, 60])
        XCTAssertEqual(result?.planType, "plus")
        XCTAssertEqual(result?.windows.map(\.resetsAt), [Date(timeIntervalSince1970: 1_800_000_000), Date(timeIntervalSince1970: 1_800_604_800)])
    }

    func testSparseNotificationPreservesMissingWeeklyWindow() {
        let old = AccountUsageSnapshot(
            windows: [
                QuotaWindow(usedPercent: 25, durationMinutes: 300, resetsAt: nil),
                QuotaWindow(usedPercent: 40, durationMinutes: 10_080, resetsAt: nil)
            ], planType: "plus", updatedAt: Date(timeIntervalSince1970: 1))
        let message: [String: Any] = [
            "method": "account/rateLimits/updated",
            "params": ["rateLimits": ["primary": ["usedPercent": 30, "windowDurationMins": 300]]]
        ]
        let result = AccountUsageParser.parse(message: message, mergingWith: old, now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(result?.windows.map(\.usedPercent), [30, 40])
        XCTAssertEqual(result?.planType, "plus")
    }

    func testEmptyAndInvalidUpdatesDoNotManufactureFreshness() {
        let old = AccountUsageSnapshot(windows: [
            QuotaWindow(usedPercent: 25, durationMinutes: 300, resetsAt: nil)
        ], planType: "plus", updatedAt: Date(timeIntervalSince1970: 1))
        let payloads: [[String: Any]] = [
            [:], ["primary": [:]], ["primary": ["usedPercent": "bad"]],
            ["primary": ["resetsAt": "bad"]], ["primary": ["windowDurationMins": true]]
        ]
        for payload in payloads {
            for key in ["params", "result"] {
                XCTAssertNil(AccountUsageParser.parse(message: [key: ["rateLimits": payload]],
                    mergingWith: old, now: Date(timeIntervalSince1970: 9)), "\(key): \(payload)")
            }
        }
    }

    func testAuthoritativeReadRemovesAbsentWindowsAndDoesNotInheritFields() {
        let old = AccountUsageSnapshot(windows: [
            QuotaWindow(usedPercent: 25, durationMinutes: 300, resetsAt: Date(timeIntervalSince1970: 500)),
            QuotaWindow(usedPercent: 40, durationMinutes: 10_080, resetsAt: nil)
        ], planType: "plus", updatedAt: Date(timeIntervalSince1970: 1))
        let result = AccountUsageParser.parse(message: ["result": ["rateLimits": [
            "primary": ["usedPercent": 30, "windowDurationMins": 300]
        ]]], mergingWith: old, now: Date(timeIntervalSince1970: 9))
        XCTAssertEqual(result?.windows.map(\.usedPercent), [30])
        XCTAssertNil(result?.windows.first?.resetsAt)
        XCTAssertNil(result?.planType)
        XCTAssertEqual(result?.updatedAt, Date(timeIntervalSince1970: 9))
    }

    func testValidSparseResetUpdatePreservesPercentAndOtherWindows() {
        let old = AccountUsageSnapshot(windows: [
            QuotaWindow(usedPercent: 25, durationMinutes: 300, resetsAt: nil),
            QuotaWindow(usedPercent: 40, durationMinutes: 10_080, resetsAt: nil)
        ], planType: nil, updatedAt: Date(timeIntervalSince1970: 1))
        let result = AccountUsageParser.parse(message: ["params": ["rateLimits": [
            "primary": ["resetsAt": 500]
        ]]], mergingWith: old, now: Date(timeIntervalSince1970: 9))
        XCTAssertEqual(result?.windows.map(\.usedPercent), [25, 40])
        XCTAssertEqual(result?.windows.first?.resetsAt, Date(timeIntervalSince1970: 500))
        XCTAssertEqual(result?.updatedAt, Date(timeIntervalSince1970: 9))
    }

    func testParsesWeeklyOnlyByLimitIDPayload() {
        let message: [String: Any] = ["params": ["rateLimitsByLimitId": ["codex": [
            "secondary": ["usedPercent": 12.5, "windowDurationMins": 10_080]
        ]]]]
        let result = AccountUsageParser.parse(message: message, mergingWith: nil, now: Date(timeIntervalSince1970: 9))
        XCTAssertEqual(result?.windows.count, 1)
        XCTAssertEqual(result?.windows.first?.usedPercent, 12.5)
        XCTAssertEqual(result?.windows.first?.durationMinutes, 10_080)
    }

    func testMalformedPercentagesAreRejectedAndDoNotCreateSnapshot() {
        let message: [String: Any] = ["result": ["rateLimits": [
            "primary": ["usedPercent": "25", "windowDurationMins": 300],
            "secondary": ["usedPercent": 40, "windowDurationMins": 0]
        ]]]
        XCTAssertNil(AccountUsageParser.parse(message: message, mergingWith: nil))
    }

    func testOutOfRangeOrFractionalDurationIsRejected() {
        let message: [String: Any] = ["result": ["rateLimits": [
            "primary": ["usedPercent": 25, "windowDurationMins": 1e100],
            "secondary": ["usedPercent": 40, "windowDurationMins": 10.5]
        ]]]
        XCTAssertNil(AccountUsageParser.parse(message: message, mergingWith: nil))
    }
}
