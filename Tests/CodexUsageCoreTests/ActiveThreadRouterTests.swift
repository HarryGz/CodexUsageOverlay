import XCTest
@testable import CodexUsageCore

final class ActiveThreadRouterTests: XCTestCase {
    private let first = "11111111-1111-1111-1111-111111111111"
    private let second = "22222222-2222-2222-2222-222222222222"

    func testFollowSelectsConversationAndLaterWindowWins() {
        var router = ActiveThreadRouter()
        XCTAssertTrue(router.process(frame: follow(first)))
        XCTAssertEqual(router.status.threadID, first)
        XCTAssertTrue(router.status.connected)
        XCTAssertTrue(router.process(frame: follow(second, client: "client-b")))
        XCTAssertEqual(router.status.threadID, second)
        XCTAssertEqual(router.status.activeWindowCount, 2)
        XCTAssertTrue(router.process(frame: follow(second, client: "client-b", following: false)))
        XCTAssertEqual(router.status.threadID, first)
        XCTAssertEqual(router.status.activeWindowCount, 1)
    }

    func testConnectedUnfollowPreservesSelectionUntilNextFollow() {
        var router = ActiveThreadRouter()
        _ = router.process(frame: follow(first))
        _ = router.process(frame: follow(first, following: false))
        XCTAssertEqual(router.status.threadID, first)
        XCTAssertEqual(router.status.activeWindowCount, 0)
        XCTAssertTrue(router.status.connected)
        _ = router.process(frame: follow(second))
        XCTAssertEqual(router.status.threadID, second)
    }

    func testClientDisconnectRemovesOnlyItsRoutes() {
        var router = ActiveThreadRouter()
        _ = router.process(frame: follow(first, client: "client-b"))
        _ = router.process(frame: follow(second))
        XCTAssertTrue(router.process(frame: ["type": "broadcast", "method": "client-status-changed", "params": ["clientId": "client-a", "status": "disconnected"]]))
        XCTAssertEqual(router.status.threadID, first)
        XCTAssertEqual(router.status.activeWindowCount, 1)
        XCTAssertTrue(router.status.connected)
    }

    func testLastClientDisconnectClearsRouteEvenAfterUnfollowTransition() {
        for unfollowFirst in [false, true] {
            var router = ActiveThreadRouter()
            _ = router.process(frame: follow(first))
            if unfollowFirst { _ = router.process(frame: follow(first, following: false)) }
            XCTAssertTrue(router.process(frame: ["type": "broadcast", "method": "client-status-changed", "params": ["clientId": "client-a", "status": "disconnected"]]))
            XCTAssertNil(router.status.threadID)
            XCTAssertEqual(router.status.activeWindowCount, 0)
            XCTAssertTrue(router.status.connected, "The IPC transport itself is still connected")
        }
    }

    func testResetClearsSelectionAndIncrementsVersion() {
        var router = ActiveThreadRouter()
        _ = router.process(frame: follow(first))
        let version = router.status.version
        router.reset()
        XCTAssertNil(router.status.threadID)
        XCTAssertEqual(router.status.activeWindowCount, 0)
        XCTAssertFalse(router.status.connected)
        XCTAssertEqual(router.status.version, version + 1)
    }

    func testMalformedAndUnrelatedBroadcastsDoNotMutateState() {
        var router = ActiveThreadRouter()
        _ = router.process(frame: follow(first))
        let before = router.status
        let malformed: [[String: Any]] = [
            [:], ["type": "request", "method": "thread-stream-following-changed"],
            ["type": "broadcast", "method": "message", "params": ["text": "synthetic ignored content"]],
            ["type": "broadcast", "method": "thread-stream-following-changed", "sourceClientId": "client-b", "params": ["conversationId": second, "hostId": "local", "following": 1]],
            ["type": "broadcast", "method": "thread-stream-following-changed", "sourceClientId": "", "params": ["conversationId": second, "hostId": "local", "following": true]]
        ]
        for frame in malformed {
            XCTAssertFalse(router.process(frame: frame))
            XCTAssertEqual(router.status, before)
        }
    }

    func testWindowReplacesRouteAndIgnoresStaleUnfollow() {
        var router = ActiveThreadRouter()
        _ = router.process(frame: follow(first))
        _ = router.process(frame: follow(second))
        XCTAssertEqual(router.status.activeWindowCount, 1)
        XCTAssertFalse(router.process(frame: follow(first, following: false)))
        XCTAssertEqual(router.status.threadID, second)
        XCTAssertEqual(router.status.activeWindowCount, 1)
    }

    func testCaseInsensitiveUnfollowRemovesTheMatchingWindow() {
        var router = ActiveThreadRouter()
        _ = router.process(frame: follow("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"))
        XCTAssertTrue(router.process(frame: follow("aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", following: false)))
        XCTAssertEqual(router.status.activeWindowCount, 0)
    }

    func testJSONDecodingIgnoresContentAndRejectsMalformedOrNumericFollowing() {
        var router = ActiveThreadRouter()
        XCTAssertTrue(router.process(data: Data(#"{"type":"broadcast","method":"thread-stream-following-changed","sourceClientId":"a","params":{"conversationId":"synthetic-task","hostId":"local","following":true},"content":{"messages":["synthetic ignored content"]}}"#.utf8)))
        let before = router.status
        let invalid = ["{", "[]", #"{"type":"broadcast","method":"unrelated","params":{}}"#,
                       #"{"type":"broadcast","method":"thread-stream-following-changed","sourceClientId":"a","params":{"conversationId":"other","hostId":"local","following":1}}"#]
        for json in invalid {
            XCTAssertFalse(router.process(data: Data(json.utf8)))
            XCTAssertEqual(router.status, before)
        }
    }

    func testRoutingWireJSONMustBeUTF8() throws {
        var router = ActiveThreadRouter()
        let json = #"{"type":"broadcast","method":"thread-stream-following-changed","sourceClientId":"a","params":{"conversationId":"synthetic-task","hostId":"local","following":true}}"#
        let utf16 = try XCTUnwrap(json.data(using: .utf16LittleEndian))
        XCTAssertFalse(router.process(data: utf16))
        XCTAssertNil(router.status.threadID)
    }

    func testHostsDistinguishRoutesAndClientDisconnectRemovesAllItsHosts() {
        var router = ActiveThreadRouter()
        _ = router.process(frame: follow(first, client: "client-b"))
        _ = router.process(frame: follow(first))
        _ = router.process(frame: ["type": "broadcast", "method": "thread-stream-following-changed", "sourceClientId": "client-a", "params": ["conversationId": second, "hostId": "remote", "following": true]])
        XCTAssertEqual(router.status.activeWindowCount, 3)
        _ = router.process(frame: ["type": "broadcast", "method": "client-status-changed", "params": ["clientId": "client-a", "status": "disconnected"]])
        XCTAssertEqual(router.status.activeWindowCount, 1)
        XCTAssertEqual(router.status.threadID, first)
    }

    private func follow(_ id: String, client: String = "client-a", following: Bool = true) -> [String: Any] {
        ["type": "broadcast", "method": "thread-stream-following-changed", "sourceClientId": client,
         "params": ["conversationId": id, "hostId": "local", "following": following]]
    }
}
