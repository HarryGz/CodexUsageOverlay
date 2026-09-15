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
            receivedSnapshot = value.usedTokens == 10
            snapshot.fulfill()
        }
        monitor.onError = { error in
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
}
