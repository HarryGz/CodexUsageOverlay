import Foundation
import XCTest
@testable import CodexUsageCore

final class TiboDisplayFormatterTests: XCTestCase {
    func testFormatsCategoriesBeijingTimeAndVisibleAttribution() throws {
        let expected: [(TiboMessageCategory, String)] = [
            (.resetAnnouncement, "重置预告"),
            (.resetCompleted, "已完成"),
            (.bankedReset, "备用重置"),
            (.strongHint, "强烈暗示")
        ]
        for (category, label) in expected {
            let detail = try XCTUnwrap(TiboDisplayFormatter.detail(
                snapshot: snapshot(category: category),
                now: date(1_000),
                timeZone: TimeZone(identifier: "Asia/Shanghai")!
            ))
            XCTAssertEqual(detail.categoryLabel, label)
            XCTAssertEqual(detail.publishedText, "1970-01-01 08:01")
            XCTAssertEqual(detail.attributionLabel, "Data: codex-reset.com")
            XCTAssertEqual(detail.attributionURL.absoluteString, "https://codex-reset.com/")
        }
    }

    func testFormatsExactVerificationLabelsWithoutPersonalDeliveryClaim() throws {
        let states: [(TiboVerificationState, String)] = [
            (.pending, "… 等待 X 确认"),
            (.confirmed, "✓ X 已确认"),
            (.anomalous, "⚠ 来源异常")
        ]
        for (state, expected) in states {
            let detail = try XCTUnwrap(TiboDisplayFormatter.detail(snapshot: snapshot(verification: state), now: date(1_000)))
            XCTAssertEqual(detail.verificationLabel, expected)
            XCTAssertFalse(detail.verificationLabel.contains("账户已重置"))
            XCTAssertFalse(detail.summary?.contains("账户已重置") == true)
        }
    }

    func testFormatsHealthyStaleUnavailableAndNeverCheckedHealth() throws {
        let cases: [(TiboFeedHealth, String)] = [
            (.healthy(checkedAt: date(900), fetchedAt: date(890)), "最近检查"),
            (.stale(checkedAt: date(900)), "数据源已过期"),
            (.unavailable(checkedAt: date(900)), "数据源暂不可用"),
            (.neverChecked, "尚未检查数据源")
        ]
        for (health, fragment) in cases {
            let detail = try XCTUnwrap(TiboDisplayFormatter.detail(snapshot: snapshot(health: health), now: date(1_000)))
            XCTAssertTrue(detail.healthText.contains(fragment))
        }
    }

    func testAnomalousRecordOmitsUntrustedSummaryCategoryAndPostLink() throws {
        let detail = try XCTUnwrap(TiboDisplayFormatter.detail(snapshot: snapshot(verification: .anomalous), now: date(1_000)))
        XCTAssertNil(detail.categoryLabel)
        XCTAssertNil(detail.summary)
        XCTAssertNil(detail.postURL)
        XCTAssertEqual(detail.verificationLabel, "⚠ 来源异常")
    }

    func testNoRetainedRecordProducesNoDetail() {
        XCTAssertNil(TiboDisplayFormatter.detail(snapshot: TiboAlertSnapshot(), now: date(1_000)))
    }

    func testExtremeFiniteHealthDateFormatsWithoutIntegerTrap() throws {
        let detail = try XCTUnwrap(TiboDisplayFormatter.detail(
            snapshot: snapshot(health: .unavailable(checkedAt: Date(timeIntervalSince1970: -1e100))),
            now: date(1_000)
        ))

        XCTAssertTrue(detail.healthText.contains("很久以前"))
    }

    private func snapshot(
        category: TiboMessageCategory = .resetAnnouncement,
        verification: TiboVerificationState = .pending,
        health: TiboFeedHealth? = nil
    ) -> TiboAlertSnapshot {
        let message = TiboMessage(
            id: "101",
            category: category,
            localizedSummary: "公开消息：可能进行额度重置。",
            publishedAt: date(60),
            canonicalURL: URL(string: "https://x.com/thsottiaux/status/101")!
        )
        var record = TiboAlertRecord(message: message, verification: verification, verificationUpdatedAt: date(100))
        if verification == .anomalous {
            record.category = nil
            record.localizedSummary = nil
            record.canonicalURL = nil
        }
        return TiboAlertSnapshot(
            latest: record,
            unread: true,
            health: health ?? .healthy(checkedAt: date(900), fetchedAt: date(890))
        )
    }

    private func date(_ seconds: Double) -> Date { Date(timeIntervalSince1970: seconds) }
}
