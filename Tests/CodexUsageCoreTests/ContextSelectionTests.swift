import XCTest
@testable import CodexUsageCore

final class ContextSelectionTests: XCTestCase {
    func testNoConnectionOrRouteUsesExplicitFallback() {
        var router = ActiveThreadRouter()
        XCTAssertEqual(ContextSelection(status: router.status), .fallback)
        router.didConnect()
        XCTAssertEqual(ContextSelection(status: router.status), .fallback)
    }

    func testSelectedRouteSurvivesUnfollowButDisconnectUsesFallback() {
        var router = ActiveThreadRouter()
        let task = "00000000-0000-4000-8000-000000000001"
        func following(_ value: Bool) -> [String: Any] {
            ["type": "broadcast", "method": "thread-stream-following-changed", "sourceClientId": "synthetic-client",
             "params": ["hostId": "synthetic-host", "conversationId": task, "following": value]]
        }
        router.process(frame: following(true))
        XCTAssertEqual(ContextSelection(status: router.status), .selected(task))
        router.process(frame: following(false))
        XCTAssertEqual(ContextSelection(status: router.status), .selected(task))
        router.reset(error: .disconnected)
        XCTAssertEqual(ContextSelection(status: router.status), .fallback)
    }
}
