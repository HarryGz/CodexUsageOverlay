import XCTest
@testable import CodexUsageCore

final class UsageModelsTests: XCTestCase {
    func testQuotaRemainingClampsServerUsedPercent() {
        XCTAssertEqual(QuotaWindow(usedPercent: 25, durationMinutes: 300, resetsAt: nil).remainingPercent, 75)
        XCTAssertEqual(QuotaWindow(usedPercent: -5, durationMinutes: 300, resetsAt: nil).remainingPercent, 100)
        XCTAssertEqual(QuotaWindow(usedPercent: 140, durationMinutes: 300, resetsAt: nil).remainingPercent, 0)
    }

    func testContextRemainingUsesLatestRequestTotal() {
        let snapshot = ContextUsageSnapshot(
            threadID: "thread-1",
            usedTokens: 180_000,
            windowTokens: 258_400,
            updatedAt: Date(timeIntervalSince1970: 100),
            provenance: .selectedThread
        )
        XCTAssertEqual(snapshot.remainingTokens, 78_400)
        XCTAssertEqual(snapshot.remainingPercent!, 30.34, accuracy: 0.01)
    }

    func testUnknownContextLimitKeepsRemainingUnknown() {
        let snapshot = ContextUsageSnapshot(
            threadID: "thread-1",
            usedTokens: 10,
            windowTokens: nil,
            updatedAt: Date(),
            provenance: .selectedThread
        )
        XCTAssertNil(snapshot.remainingTokens)
        XCTAssertNil(snapshot.remainingPercent)
    }
}
