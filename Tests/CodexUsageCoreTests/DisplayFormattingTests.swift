import XCTest
@testable import CodexUsageCore

final class DisplayFormattingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_000_000)

    func testDurationLabelsUseActualWindowLength() {
        XCTAssertEqual(DisplayFormatter.durationLabel(300), "5h")
        XCTAssertEqual(DisplayFormatter.durationLabel(10_080), "周")
        XCTAssertEqual(DisplayFormatter.durationLabel(120), "2h")
        XCTAssertEqual(DisplayFormatter.durationLabel(90), "90分")
        XCTAssertEqual(DisplayFormatter.durationLabel(nil), "额度")
    }

    func testPercentAndTokensAreLocaleStableAndMissingIsUnknown() {
        XCTAssertEqual(DisplayFormatter.percent(75.4), "75%")
        XCTAssertEqual(DisplayFormatter.percent(nil), "—")
        XCTAssertEqual(DisplayFormatter.percent(.nan), "—")
        XCTAssertEqual(DisplayFormatter.tokens(78_400), "78.4k")
        XCTAssertEqual(DisplayFormatter.tokens(80_000), "80k")
        XCTAssertEqual(DisplayFormatter.tokens(999), "999")
        XCTAssertEqual(DisplayFormatter.tokens(nil), "—")
    }

    func testResetCountdownUsesHoursAndMinutesAndClampsPastReset() {
        XCTAssertEqual(DisplayFormatter.resetCountdown(now.addingTimeInterval(5_400), now: now), "1小时30分")
        XCTAssertEqual(DisplayFormatter.resetCountdown(now.addingTimeInterval(86_460), now: now), "1天1分")
        XCTAssertEqual(DisplayFormatter.resetCountdown(now.addingTimeInterval(-1), now: now), "即将重置")
        XCTAssertEqual(DisplayFormatter.resetCountdown(nil, now: now), "—")
    }

    func testCompleteCompactOutputHasContractOrderAndIndependentColors() {
        let segments = DisplayFormatter.compactSegments(snapshot: snapshot(), now: now)
        XCTAssertEqual(segments.map(\.text).joined(separator: " · "), "5h 72% · 周 84% · 上下文 41%")
        XCTAssertEqual(segments.map(\.color), [.healthy, .healthy, .warning])
    }

    func testUnknownContextIsOmittedFromCompactAndDetailViews() {
        let value = CombinedUsageSnapshot(account: .live(.init(windows: [], planType: nil, updatedAt: now)),
                                          context: .unavailable(reason: "未找到任务"))
        XCTAssertTrue(DisplayFormatter.compactSegments(snapshot: value, now: now).isEmpty)
        let rows = DisplayFormatter.detailRows(snapshot: value, now: now)
        XCTAssertFalse(rows.contains { $0.section == .context })
        XCTAssertEqual(DisplayFormatter.visibleDetailSections(rows: rows), [.account])
    }

    func testUnavailableAccountDoesNotInventQuotaWindows() {
        let value = CombinedUsageSnapshot(account: .unavailable(reason: "未连接"), context: .unavailable(reason: "未找到任务"))
        XCTAssertEqual(DisplayFormatter.compactSegments(snapshot: value, now: now).map(\.text), ["额度 —"])
        XCTAssertTrue(DisplayFormatter.detailRows(snapshot: value, now: now).contains { $0.value == "未连接" })
        XCTAssertFalse(DisplayFormatter.detailRows(snapshot: value, now: now).contains { $0.section == .context })
    }

    func testFallbackContextIsNeverShown() {
        let value = snapshot(provenance: .fallbackThread)
        XCTAssertEqual(DisplayFormatter.compactSegments(snapshot: value, now: now).map(\.text), ["5h 72%", "周 84%"])
        let rows = DisplayFormatter.detailRows(snapshot: value, now: now)
        XCTAssertFalse(rows.contains { $0.section == .context })
    }

    func testAmbiguousWindowContextIsNeverShown() {
        let value = snapshot(provenance: .ambiguousThread)
        XCTAssertEqual(DisplayFormatter.compactSegments(snapshot: value, now: now).map(\.text), ["5h 72%", "周 84%"])
        XCTAssertFalse(DisplayFormatter.detailRows(snapshot: value, now: now).contains { $0.section == .context })
    }

    func testStaleContextIsHiddenWhileStaleAccountRemainsLabeled() {
        let live = snapshot()
        guard case .live(let account) = live.account, case .live(let context) = live.context else { return XCTFail() }
        let value = CombinedUsageSnapshot(account: .stale(account, reason: "连接中断"), context: .stale(context, reason: "日志暂不可用"))
        let segments = DisplayFormatter.compactSegments(snapshot: value, now: now)
        XCTAssertEqual(segments.map(\.text), ["5h 72%（已过期）", "周 84%（已过期）"])
        XCTAssertEqual(segments.map(\.color), [.unavailable, .unavailable])
        let rows = DisplayFormatter.detailRows(snapshot: value, now: now)
        XCTAssertTrue(rows.contains { $0.value == "已过期：连接中断" })
        XCTAssertFalse(rows.contains { $0.section == .context })
    }

    func testOldLiveDataIsAlsoStaleWithoutDependingOnStoreTimer() {
        let segments = DisplayFormatter.compactSegments(snapshot: snapshot(), now: now.addingTimeInterval(301))
        XCTAssertEqual(segments.map(\.text), ["5h 72%（已过期）", "周 84%（已过期）"])
        XCTAssertTrue(segments.allSatisfy { $0.color == .unavailable })
    }

    func testFutureDatedSelectedContextIsHidden() {
        let context = ContextUsageSnapshot(threadID: "01234567-1234-5678-1234-012389abcdef",
            usedTokens: 59_000, windowTokens: 100_000, updatedAt: now.addingTimeInterval(3_600),
            provenance: .selectedThread)
        let value = CombinedUsageSnapshot(account: snapshot().account, context: .live(context))

        XCTAssertEqual(DisplayFormatter.compactSegments(snapshot: value, now: now).map(\.text), ["5h 72%", "周 84%"])
        XCTAssertFalse(DisplayFormatter.detailRows(snapshot: value, now: now).contains { $0.section == .context })
    }

    func testSelectedContextWithoutACompleteTokenSnapshotIsHidden() {
        let context = ContextUsageSnapshot(threadID: "01234567-1234-5678-1234-012389abcdef",
            usedTokens: nil, windowTokens: 100_000, updatedAt: now, provenance: .selectedThread)
        let value = CombinedUsageSnapshot(account: snapshot().account, context: .live(context))
        XCTAssertEqual(DisplayFormatter.compactSegments(snapshot: value, now: now).map(\.text), ["5h 72%", "周 84%"])
        XCTAssertFalse(DisplayFormatter.detailRows(snapshot: value, now: now).contains { $0.section == .context })
    }

    func testDetailRowsSeparateSectionsAndIncludeRemainingTokensAndReset() {
        let rows = DisplayFormatter.detailRows(snapshot: snapshot(), now: now)
        XCTAssertTrue(rows.contains { $0.section == .account && $0.label == "5h 重置" && $0.value == "1小时30分" })
        XCTAssertTrue(rows.contains { $0.section == .context && $0.label == "剩余 tokens" && $0.value == "41k / 100k" })
    }

    func testDetailsIncludeUsedTokensLocalResetAndIndependentSuccessAges() {
        let value = CombinedUsageSnapshot(
            account: .live(.init(windows: [.init(usedPercent: 20, durationMinutes: 300,
                resetsAt: Date(timeIntervalSince1970: 3_600))], planType: nil,
                updatedAt: Date(timeIntervalSince1970: 0))),
            context: .live(.init(threadID: "synthetic-task", usedTokens: 59_000, windowTokens: 100_000,
                updatedAt: Date(timeIntervalSince1970: 60), provenance: .selectedThread)))
        let rows = DisplayFormatter.detailRows(snapshot: value, now: Date(timeIntervalSince1970: 120),
            timeZone: TimeZone(secondsFromGMT: 28_800)!)
        XCTAssertEqual(rows.first { $0.section == .context && $0.label == "已用 tokens" }?.value, "59k")
        XCTAssertEqual(rows.first { $0.section == .account && $0.label == "5h 本地重置时间" }?.value, "1970-01-01 09:00:00")
        XCTAssertEqual(rows.first { $0.section == .account && $0.label == "最后成功更新" }?.value, "1970-01-01 08:00:00（2分前）")
        XCTAssertEqual(rows.first { $0.section == .context && $0.label == "最后成功更新" }?.value, "1970-01-01 08:01:00（1分前）")
        XCTAssertTrue(rows.contains { $0.section == .account && $0.label == "最后成功更新" && $0.value.hasSuffix("（2分前）") })
        XCTAssertTrue(rows.contains { $0.section == .context && $0.label == "最后成功更新" && $0.value.hasSuffix("（1分前）") })
    }

    private func snapshot(provenance: SnapshotProvenance = .selectedThread) -> CombinedUsageSnapshot {
        CombinedUsageSnapshot(account: .live(.init(windows: [
            .init(usedPercent: 16, durationMinutes: 10_080, resetsAt: nil),
            .init(usedPercent: 28, durationMinutes: 300, resetsAt: now.addingTimeInterval(5_400))
        ], planType: "pro", updatedAt: now)), context: .live(.init(
            threadID: "01234567-1234-5678-1234-012389abcdef", usedTokens: 59_000,
            windowTokens: 100_000, updatedAt: now, provenance: provenance)))
    }
}
