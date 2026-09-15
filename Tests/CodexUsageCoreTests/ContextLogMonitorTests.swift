import Darwin
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
        monitor.start()
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
        monitor.start()
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

    @MainActor
    func testSelectionAndProvenanceChangesInvalidateBeforePublishingAnotherSnapshot() {
        let store = UsageStore()
        let initial = expectation(description: "initial snapshot")
        let invalidated = expectation(description: "provenance invalidated")
        let replacement = expectation(description: "fallback snapshot")
        let monitor = ContextLogMonitor(codexHome: codexHome, now: { Date(timeIntervalSince1970: 100) })
        monitor.start()
        var changing = false
        var didInvalidate = false
        monitor.onError = { error in
            if changing, case .unavailable = error as? ContextLogMonitorError {
                store.invalidateContext(error.localizedDescription)
                XCTAssertFalse(DisplayFormatter.compactSegments(snapshot: store.snapshot, now: Date(timeIntervalSince1970: 100))
                    .contains { $0.text.hasPrefix("上下文") })
                didInvalidate = true
                invalidated.fulfill()
            }
        }
        monitor.onSnapshot = { snapshot in
            store.updateContext(snapshot)
            if changing {
                XCTAssertTrue(didInvalidate, "old provenance must become unavailable first")
                XCTAssertEqual(snapshot.provenance, .fallbackThread)
                replacement.fulfill()
            } else { initial.fulfill() }
        }
        monitor.select(threadID: threadID, provenance: .selectedThread)
        wait(for: [initial], timeout: 2)
        changing = true
        monitor.select(threadID: threadID, provenance: .fallbackThread)
        wait(for: [invalidated, replacement], timeout: 2)
        monitor.stop()
    }

    @MainActor
    func testSelectingMissingTaskReportsInvalidationInsteadOfRetainingOldIdentity() {
        let store = UsageStore()
        let initial = expectation(description: "initial")
        let invalidated = expectation(description: "invalidated missing task")
        let monitor = ContextLogMonitor(codexHome: codexHome, now: { Date(timeIntervalSince1970: 100) })
        monitor.start()
        monitor.onSnapshot = { store.updateContext($0); initial.fulfill() }
        monitor.select(threadID: threadID, provenance: .selectedThread)
        wait(for: [initial], timeout: 2)
        monitor.onError = { error in
            if case .unavailable = error as? ContextLogMonitorError {
                store.invalidateContext(error.localizedDescription)
                invalidated.fulfill()
            }
        }
        monitor.select(threadID: "223E4567-E89B-12D3-A456-426614174000", provenance: .selectedThread)
        wait(for: [invalidated], timeout: 1)
        guard case .unavailable = store.snapshot.context else { return XCTFail("old task value was retained") }
        XCTAssertFalse(DisplayFormatter.compactSegments(snapshot: store.snapshot, now: Date(timeIntervalSince1970: 100))
            .contains { $0.text.hasPrefix("上下文") })
        monitor.stop()
    }

    @MainActor
    func testCompactionClearsStoreAndDisplayUntilDistinctPostCompactionCount() throws {
        let store = UsageStore()
        let initial = expectation(description: "initial context")
        let invalidated = expectation(description: "compaction makes context unknown")
        let recovered = expectation(description: "distinct count")
        let monitor = ContextLogMonitor(codexHome: codexHome, now: { Date(timeIntervalSince1970: 100) })
        monitor.start()
        var compacted = false
        monitor.onSnapshot = { value in
            store.updateContext(value)
            if value.usedTokens == 20 { recovered.fulfill() } else { initial.fulfill() }
        }
        monitor.onError = { error in
            if case .unavailable(let reason) = error as? ContextLogMonitorError {
                store.invalidateContext(reason)
                if compacted { invalidated.fulfill() }
            } else { store.failContext(error.localizedDescription) }
        }
        monitor.select(threadID: threadID, provenance: .selectedThread)
        wait(for: [initial], timeout: 2)
        store.failContext("same context temporary read failure")
        guard case .stale(let retained, _) = store.snapshot.context else { return XCTFail("same identity failure must retain stale value") }
        XCTAssertEqual(retained.usedTokens, 10)
        compacted = true
        let path = codexHome.appendingPathComponent("sessions/2026/09/15/rollout-\(threadID).jsonl")
        let file = try FileHandle(forWritingTo: path)
        defer { try? file.close(); monitor.stop() }
        try file.seekToEnd()
        try file.write(contentsOf: Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"contextCompaction\"}}\n".utf8))
        wait(for: [invalidated], timeout: 2)
        guard case .unavailable = store.snapshot.context else { return XCTFail("pre-compaction value leaked") }
        XCTAssertFalse(DisplayFormatter.compactSegments(snapshot: store.snapshot, now: Date(timeIntervalSince1970: 100))
            .contains { $0.text.hasPrefix("上下文") })
        compacted = false
        try file.write(contentsOf: Data("{\"timestamp\":\"1970-01-01T00:01:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":20},\"model_context_window\":100}}}\n".utf8))
        wait(for: [recovered], timeout: 2)
        guard case .live(let value) = store.snapshot.context else { return XCTFail("fresh count must recover") }
        XCTAssertEqual(value.remainingPercent, 80)
    }

    // Break caught: delivering a queued snapshot or error after monitoring has stopped.
    func testStopInvalidatesQueuedCallbacksBeforeMainDelivery() {
        let noCallback = expectation(description: "no callback")
        noCallback.isInverted = true
        let monitor = ContextLogMonitor(codexHome: codexHome, now: { Date(timeIntervalSince1970: 1_000) })
        monitor.start()
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

    func testMissingSelectedRolloutIsDiscoveredAfterCreation() throws {
        let missingID = "323E4567-E89B-12D3-A456-426614174000"
        let available = expectation(description: "newly created rollout")
        let monitor = ContextLogMonitor(codexHome: codexHome, now: { Date(timeIntervalSince1970: 100) })
        defer { monitor.stop() }
        monitor.start()
        monitor.onSnapshot = { value in
            XCTAssertEqual(value.threadID, missingID)
            XCTAssertEqual(value.usedTokens, 30)
            available.fulfill()
        }
        monitor.select(threadID: missingID, provenance: .selectedThread)
        try writeRollout(threadID: missingID, tokens: 30)
        wait(for: [available], timeout: 2)
    }

    func testRefreshNowRetriesMissingResolution() throws {
        let missingID = "423E4567-E89B-12D3-A456-426614174000"
        let available = expectation(description: "manual discovery")
        let monitor = ContextLogMonitor(codexHome: codexHome, now: { Date(timeIntervalSince1970: 100) })
        defer { monitor.stop() }
        monitor.start()
        monitor.onSnapshot = { value in XCTAssertEqual(value.usedTokens, 40); available.fulfill() }
        monitor.select(threadID: missingID, provenance: .selectedThread)
        try writeRollout(threadID: missingID, tokens: 40)
        monitor.refreshNow()
        wait(for: [available], timeout: 0.5)
    }

    func testDelayedReplacementAfterRotationIsDiscovered() throws {
        let initial = expectation(description: "initial rollout")
        let missing = expectation(description: "rotation gap")
        let replaced = expectation(description: "replacement rollout")
        let monitor = ContextLogMonitor(codexHome: codexHome, now: { Date(timeIntervalSince1970: 100) })
        defer { monitor.stop() }
        monitor.start()
        monitor.onSnapshot = { value in
            if value.usedTokens == 20 { replaced.fulfill() } else { initial.fulfill() }
        }
        monitor.select(threadID: threadID, provenance: .selectedThread)
        wait(for: [initial], timeout: 2)
        monitor.onError = { _ in missing.fulfill() }
        let original = codexHome.appendingPathComponent("sessions/2026/09/15/rollout-\(threadID).jsonl")
        try FileManager.default.moveItem(at: original, to: original.appendingPathExtension("rotated"))
        wait(for: [missing], timeout: 2)
        monitor.onError = nil
        try writeRollout(threadID: threadID, tokens: 20)
        wait(for: [replaced], timeout: 2)
    }

    func testBackgroundDisconnectCannotRestartWatchingAndForegroundResumesIntent() {
        let initial = expectation(description: "foreground reading")
        let background = expectation(description: "no background reading")
        background.isInverted = true
        background.assertForOverFulfill = false
        let resumed = expectation(description: "foreground fallback reading")
        let monitor = ContextLogMonitor(codexHome: codexHome, now: { Date(timeIntervalSince1970: 100) })
        defer { monitor.stop() }
        monitor.start()
        monitor.onSnapshot = { _ in initial.fulfill() }
        monitor.select(threadID: threadID, provenance: .selectedThread)
        wait(for: [initial], timeout: 2)
        monitor.stop()
        monitor.onSnapshot = { _ in background.fulfill() }
        monitor.onError = { _ in background.fulfill() }
        monitor.selectFallbackRootSession(provenance: .fallbackThread)
        monitor.refreshNow()
        wait(for: [background], timeout: 0.2)
        monitor.onError = nil
        monitor.onSnapshot = { value in
            XCTAssertEqual(value.provenance, .fallbackThread)
            resumed.fulfill()
        }
        monitor.start()
        wait(for: [resumed], timeout: 2)
    }

    func testSelectionDoesNotMonitorBeforeForegroundStart() {
        let background = expectation(description: "no reading before foreground")
        background.isInverted = true
        background.assertForOverFulfill = false
        let monitor = ContextLogMonitor(codexHome: codexHome, now: { Date(timeIntervalSince1970: 100) })
        defer { monitor.stop() }
        monitor.onSnapshot = { _ in background.fulfill() }
        monitor.onError = { _ in background.fulfill() }
        monitor.select(threadID: threadID, provenance: .selectedThread)
        wait(for: [background], timeout: 0.2)
    }

    func testBackgroundStopClosesOwnedRolloutDescriptor() {
        let worker = DispatchQueue(label: "ContextLogMonitorTests.descriptor")
        let monitor = ContextLogMonitor(codexHome: codexHome, now: { Date(timeIntervalSince1970: 100) }, workerQueue: worker)
        let path = codexHome.appendingPathComponent("sessions/2026/09/15/rollout-\(threadID).jsonl")
        monitor.start()
        monitor.select(threadID: threadID, provenance: .selectedThread)
        XCTAssertEqual(descriptors(for: path).count, 1)
        monitor.stop()
        let drained = expectation(description: "watcher cancellation drained")
        worker.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)
        XCTAssertTrue(descriptors(for: path).isEmpty, "background must close its rollout descriptor")
    }

    // Break caught: retaining or reopening a guessed rollout after routing becomes uncertain.
    func testClearSelectionClosesTheRolloutAndPreventsRefreshFromReopeningIt() {
        let worker = DispatchQueue(label: "ContextLogMonitorTests.clear-selection")
        let monitor = ContextLogMonitor(codexHome: codexHome, now: { Date(timeIntervalSince1970: 100) }, workerQueue: worker)
        let path = codexHome.appendingPathComponent("sessions/2026/09/15/rollout-\(threadID).jsonl")
        monitor.start()
        monitor.select(threadID: threadID, provenance: .selectedThread)
        XCTAssertEqual(descriptors(for: path).count, 1)

        monitor.clearSelection()
        monitor.refreshNow()
        let drained = expectation(description: "clear selection drained")
        worker.async { drained.fulfill() }
        wait(for: [drained], timeout: 1)

        XCTAssertTrue(descriptors(for: path).isEmpty)
        monitor.stop()
    }

    func testStoppingMissingDiscoveryCancelsRetryUntilForegroundReturns() throws {
        let missingID = "523E4567-E89B-12D3-A456-426614174000"
        let unavailable = expectation(description: "initial missing log")
        let quiet = expectation(description: "no retry in background")
        quiet.isInverted = true
        quiet.assertForOverFulfill = false
        let resumed = expectation(description: "resumed missing selection")
        let monitor = ContextLogMonitor(codexHome: codexHome, now: { Date(timeIntervalSince1970: 100) })
        defer { monitor.stop() }
        monitor.onError = { _ in unavailable.fulfill() }
        monitor.start()
        monitor.select(threadID: missingID, provenance: .selectedThread)
        wait(for: [unavailable], timeout: 1)
        monitor.stop()
        monitor.onError = { _ in quiet.fulfill() }
        monitor.onSnapshot = { _ in quiet.fulfill() }
        try writeRollout(threadID: missingID, tokens: 50)
        wait(for: [quiet], timeout: 1.2)
        let path = codexHome.appendingPathComponent("sessions/2026/09/15/rollout-\(missingID).jsonl")
        XCTAssertTrue(descriptors(for: path).isEmpty)
        monitor.onError = nil
        monitor.onSnapshot = { value in XCTAssertEqual(value.usedTokens, 50); resumed.fulfill() }
        monitor.start()
        wait(for: [resumed], timeout: 1)
    }

    func testMissingFallbackIsDiscoveredAfterFirstRolloutAppears() throws {
        let original = codexHome.appendingPathComponent("sessions/2026/09/15/rollout-\(threadID).jsonl")
        try FileManager.default.removeItem(at: original)
        let available = expectation(description: "new fallback")
        let monitor = ContextLogMonitor(codexHome: codexHome, now: { Date(timeIntervalSince1970: 100) })
        defer { monitor.stop() }
        monitor.start()
        monitor.onSnapshot = { value in
            XCTAssertEqual(value.provenance, .fallbackThread)
            XCTAssertEqual(value.usedTokens, 70)
            available.fulfill()
        }
        monitor.selectFallbackRootSession(provenance: .fallbackThread)
        try writeRollout(threadID: threadID, tokens: 70)
        wait(for: [available], timeout: 2)
    }

    /// Inspect only metadata of this test process's descriptors; match the
    /// synthetic fixture's device/inode without reading any descriptor content.
    private func descriptors(for path: URL) -> [Int32] {
        var expected = stat()
        guard lstat(path.path, &expected) == 0 else { return [] }
        return (0..<getdtablesize()).filter { descriptor in
            var actual = stat()
            return fstat(descriptor, &actual) == 0 &&
                actual.st_dev == expected.st_dev && actual.st_ino == expected.st_ino
        }
    }

    private func writeRollout(threadID: String, tokens: Int) throws {
        let directory = codexHome.appendingPathComponent("sessions/2026/09/15", isDirectory: true)
        let contents = "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(threadID)\"}}\n" +
            "{\"timestamp\":\"1970-01-01T00:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":\(tokens)},\"model_context_window\":100}}}\n"
        try Data(contents.utf8).write(to: directory.appendingPathComponent("rollout-\(threadID).jsonl"))
    }
}
