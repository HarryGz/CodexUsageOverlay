import XCTest
@testable import CodexUsageCore

final class ContextSelectionTests: XCTestCase {
    func testTwoActiveRoutesCannotClaimTheForegroundTaskWithoutANewBroadcast() {
        var router = ActiveThreadRouter()
        for (client, task) in [("window-a", "task-a"), ("window-b", "task-b")] {
            router.process(frame: ["type": "broadcast", "method": "thread-stream-following-changed",
                "sourceClientId": client, "params": ["hostId": "local", "conversationId": task, "following": true]])
        }
        XCTAssertEqual(router.status.threadID, "task-b")
        XCTAssertEqual(router.status.activeWindowCount, 2)
        XCTAssertEqual(ContextSelection(status: router.status), .hidden)
        // Focus changes without a routing broadcast cannot prove either task current.
        let noNewBroadcast = router.status
        XCTAssertEqual(ContextSelection(status: noNewBroadcast), .hidden)
        router.process(frame: ["type": "broadcast", "method": "thread-stream-following-changed",
            "sourceClientId": "window-b", "params": ["hostId": "local", "conversationId": "task-b", "following": false]])
        XCTAssertEqual(ContextSelection(status: router.status), .selected("task-a"))
    }
    func testNoConnectionOrRouteHidesContext() {
        var router = ActiveThreadRouter()
        XCTAssertEqual(ContextSelection(status: router.status), .hidden)
        router.didConnect()
        XCTAssertEqual(ContextSelection(status: router.status), .hidden)
    }

    func testRouteMustRemainActiveToShowContext() {
        var router = ActiveThreadRouter()
        let task = "00000000-0000-4000-8000-000000000001"
        func following(_ value: Bool) -> [String: Any] {
            ["type": "broadcast", "method": "thread-stream-following-changed", "sourceClientId": "synthetic-client",
             "params": ["hostId": "synthetic-host", "conversationId": task, "following": value]]
        }
        router.process(frame: following(true))
        XCTAssertEqual(ContextSelection(status: router.status), .selected(task))
        router.process(frame: following(false))
        XCTAssertEqual(ContextSelection(status: router.status), .hidden)
        router.reset(error: .disconnected)
        XCTAssertEqual(ContextSelection(status: router.status), .hidden)
    }
}
