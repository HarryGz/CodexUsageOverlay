import AppKit
import XCTest
import CodexUsageCore
@testable import CodexUsageOverlay

@MainActor
final class ExpandedOverlayViewTests: XCTestCase {
    func testConstructingExpandedViewWithTiboDetailDoesNotRaiseConstraintException() {
        let view = ExpandedOverlayView(
            rows: [],
            tibo: detail(),
            openLink: { _ in },
            copyLink: { _ in },
            refresh: {},
            collapse: {}
        )

        XCTAssertFalse(view.subviews.isEmpty)
    }

    func testTiboLinksUseVisibleButtonsAndOpenExactURLs() throws {
        var opened: [URL] = []
        let view = ExpandedOverlayView(
            rows: [],
            tibo: detail(),
            openLink: { opened.append($0) },
            copyLink: { _ in },
            refresh: {},
            collapse: {}
        )

        let buttons = allButtons(in: view)
        let post = try XCTUnwrap(buttons.first { $0.title == "打开原帖" })
        let source = try XCTUnwrap(buttons.first { $0.title == "打开数据源" })
        XCTAssertTrue(post.isBordered)
        XCTAssertTrue(source.isBordered)

        post.performClick(nil)
        source.performClick(nil)

        XCTAssertEqual(opened.map(\.absoluteString), [
            "https://x.com/thsottiaux/status/1",
            "https://codex-reset.com/"
        ])
    }

    func testTiboCopyButtonsSendExactURLsToClipboardAction() throws {
        var copied: [URL] = []
        let view = ExpandedOverlayView(
            rows: [],
            tibo: detail(),
            openLink: { _ in },
            copyLink: { copied.append($0) },
            refresh: {},
            collapse: {}
        )
        let buttons = allButtons(in: view)

        let copyPost = try XCTUnwrap(buttons.first { $0.title == "复制原帖" })
        copyPost.performClick(nil)
        let copySource = try XCTUnwrap(buttons.first { $0.title == "复制来源" })
        copySource.performClick(nil)

        XCTAssertEqual(copied.map(\.absoluteString), [
            "https://x.com/thsottiaux/status/1",
            "https://codex-reset.com/"
        ])
    }

    private func detail() -> TiboDetailPresentation {
        TiboDetailPresentation(
            categoryLabel: "重置预告",
            summary: "未来 28 天将发布新能力或重置额度。",
            publishedText: "2026-10-08 12:00",
            verificationLabel: "✓ X 已确认",
            postURL: URL(string: "https://x.com/thsottiaux/status/1"),
            attributionLabel: "Data: codex-reset.com",
            attributionURL: URL(string: "https://codex-reset.com/")!,
            healthText: "最近检查：刚刚（12:00）"
        )
    }

    private func allButtons(in view: NSView) -> [NSButton] {
        view.subviews.flatMap { child in
            (child as? NSButton).map { [$0] } ?? allButtons(in: child)
        }
    }

}
