import AppKit
import XCTest
import CodexUsageCore
@testable import CodexUsageOverlay

@MainActor
final class ExpandedOverlayViewTests: XCTestCase {
    func testConstructingExpandedViewWithTiboDetailDoesNotRaiseConstraintException() {
        let detail = TiboDetailPresentation(
            categoryLabel: "重置预告",
            summary: "未来 28 天将发布新能力或重置额度。",
            publishedText: "2026-10-08 12:00",
            verificationLabel: "✓ X 已确认",
            postURL: URL(string: "https://x.com/thsottiaux/status/1"),
            attributionLabel: "Data: codex-reset.com",
            attributionURL: URL(string: "https://codex-reset.com/")!,
            healthText: "最近检查：刚刚（12:00）"
        )

        let view = ExpandedOverlayView(
            rows: [],
            tibo: detail,
            openLink: { _ in },
            refresh: {},
            collapse: {}
        )

        XCTAssertFalse(view.subviews.isEmpty)
    }
}
