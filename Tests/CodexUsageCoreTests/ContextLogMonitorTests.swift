import Foundation
import XCTest
@testable import CodexUsageCore

final class ContextLogMonitorTests: XCTestCase {
    private let threadID = "123E4567-E89B-12D3-A456-426614174000"
    private var codexHome: URL!

    override func setUpWithError() throws {
        codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageMonitorTests-\(UUID().uuidString)", isDirectory: true)
        let directory = codexHome.appendingPathComponent("sessions/2026/09/15", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fixture = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(threadID)\"}}\n" +
            "{\"timestamp\":\"1970-01-01T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":10},\"model_context_window\":100}}}\n"
        try Data(fixture.utf8).write(to: directory.appendingPathComponent("rollout-\(threadID).jsonl"))
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: codexHome)
    }

    // Break caught: losing an aged usable reading instead of publishing it and signaling staleness.
    func testPublishesStaleSnapshotBeforeReportingStaleness() {
        let snapshot = expectation(description: "snapshot")
        let stale = expectation(description: "stale error")
        var receivedSnapshot = false
        let monitor = ContextLogMonitor(codexHome: codexHome, now: { Date(timeIntervalSince1970: 1_000) })
        monitor.onSnapshot = { value in
            XCTAssertTrue(Thread.isMainThread)
            receivedSnapshot = value.usedTokens == 10
            snapshot.fulfill()
        }
        monitor.onError = { error in
            XCTAssertTrue(Thread.isMainThread)
            guard let monitorError = error as? ContextLogMonitorError,
                  case .staleSnapshot = monitorError else {
                return XCTFail("expected stale error, got \(error)")
            }
            XCTAssertTrue(receivedSnapshot)
            stale.fulfill()
        }

        monitor.select(threadID: threadID, provenance: .selectedThread)

        wait(for: [snapshot, stale], timeout: 2)
        monitor.stop()
    }

    // Break caught: delivering an old selection's queued callback after a rapid reselection.
    func testRapidReselectionInvalidatesQueuedOldSnapshot() throws {
        let secondID = "223E4567-E89B-12D3-A456-426614174000"
        try writeRollout(threadID: secondID, tokens: 20)
        let onlySecond = expectation(description: "second selection")
        let monitor = ContextLogMonitor(codexHome: codexHome, now: { Date(timeIntervalSince1970: 100) })
        monitor.onSnapshot = { value in
            XCTAssertEqual(value.threadID, secondID)
            XCTAssertEqual(value.usedTokens, 20)
            onlySecond.fulfill()
        }

        monitor.select(threadID: threadID, provenance: .selectedThread)
        monitor.select(threadID: secondID, provenance: .selectedThread)

        wait(for: [onlySecond], timeout: 2)
        monitor.stop()
    }

    // Break caught: delivering a queued snapshot or error after monitoring has stopped.
    func testStopInvalidatesQueuedCallbacksBeforeMainDelivery() {
        let noCallback = expectation(description: "no callback")
        noCallback.isInverted = true
        let monitor = ContextLogMonitor(codexHome: codexHome, now: { Date(timeIntervalSince1970: 1_000) })
        monitor.onSnapshot = { _ in noCallback.fulfill() }
        monitor.onError = { _ in noCallback.fulfill() }

        monitor.select(threadID: threadID, provenance: .selectedThread)
        monitor.stop()

        wait(for: [noCallback], timeout: 0.2)
    }

    // Break caught: synchronous teardown deadlocking when the last monitor reference is released on its worker queue.
    func testReleaseDuringQueuedRefreshCompletesTeardownWithoutDeadlock() {
        let worker = DispatchQueue(label: "ContextLogMonitorTests.worker")
        worker.suspend()
        let home = codexHome!
        var monitor: ContextLogMonitor? = ContextLogMonitor(codexHome: home, workerQueue: worker)
        weak let releasedMonitor = monitor
        monitor?.refreshNow()
        monitor = nil
        XCTAssertNotNil(releasedMonitor, "queued refresh must retain the monitor until worker execution")
        worker.resume()

        let released = expectation(description: "deinit after queued refresh")
        let workerCompleted = expectation(description: "worker proceeds after deinit")
        worker.async { workerCompleted.fulfill() }
        func waitForRelease() {
            if releasedMonitor == nil { released.fulfill() }
            else { DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(10), execute: waitForRelease) }
        }
        waitForRelease()
        wait(for: [released, workerCompleted], timeout: 2)
    }

    private func writeRollout(threadID: String, tokens: Int) throws {
        let directory = codexHome.appendingPathComponent("sessions/2026/09/15", isDirectory: true)
        let contents = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(threadID)\"}}\n" +
            "{\"timestamp\":\"1970-01-01T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":\(tokens)},\"model_context_window\":100}}}\n"
        try Data(contents.utf8).write(to: directory.appendingPathComponent("rollout-\(threadID).jsonl"))
    }
}
