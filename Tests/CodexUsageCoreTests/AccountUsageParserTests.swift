import XCTest
@testable import CodexUsageCore

final class AccountUsageParserTests: XCTestCase {
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
}
