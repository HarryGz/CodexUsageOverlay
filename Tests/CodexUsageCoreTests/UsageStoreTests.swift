import Foundation
import XCTest
@testable import CodexUsageCore

@MainActor
final class UsageStoreTests: XCTestCase {
    private let timestamp = Date(timeIntervalSince1970: 100)

    private var account: AccountUsageSnapshot {
        AccountUsageSnapshot(windows: [QuotaWindow(usedPercent: 25, durationMinutes: 300, resetsAt: nil)], planType: "plus", updatedAt: timestamp)
    }

    private var context: ContextUsageSnapshot {
        ContextUsageSnapshot(threadID: "synthetic-thread", usedTokens: 100, windowTokens: 1_000, updatedAt: timestamp, provenance: .selectedThread)
    }

    func testAccountUpdateDoesNotEraseLiveContext() {
        let store = UsageStore()
        store.updateContext(context)
        store.updateAccount(account)
        guard case .live(let value) = store.snapshot.context else { return XCTFail("context was lost") }
        XCTAssertEqual(value, context)
    }

    func testContextFailureDoesNotEraseLiveAccount() {
        let store = UsageStore()
        store.updateAccount(account)
        store.failContext("IPC unavailable")
        guard case .live(let value) = store.snapshot.account else { return XCTFail("account was lost") }
        XCTAssertEqual(value, account)
        guard case .unavailable(let reason) = store.snapshot.context else { return XCTFail("context should be unavailable") }
        XCTAssertEqual(reason, "IPC unavailable")
    }

    func testFailureTurnsExistingValueStaleAndPreservesTimestamp() {
        let store = UsageStore()
        store.updateAccount(account)
        store.failAccount("server unavailable")
        guard case .stale(let value, let reason) = store.snapshot.account else { return XCTFail("account should be stale") }
        XCTAssertEqual(value, account)
        XCTAssertEqual(value.updatedAt, timestamp)
        XCTAssertEqual(reason, "server unavailable")
    }

    func testFailureWithoutPriorValueBecomesUnavailable() {
        let store = UsageStore()
        store.failContext("no log")
        guard case .unavailable(let reason) = store.snapshot.context else { return XCTFail("context should be unavailable") }
        XCTAssertEqual(reason, "no log")
    }

    func testRefreshStalenessMarksValuesOlderThanFiveMinutesAndKeepsTimestamp() {
        let store = UsageStore()
        let old = AccountUsageSnapshot(windows: [], planType: nil, updatedAt: Date(timeIntervalSince1970: 100))
        store.updateAccount(old)
        store.refreshStaleness(now: Date(timeIntervalSince1970: 401))
        guard case .stale(let value, let reason) = store.snapshot.account else { return XCTFail("account should be stale") }
        XCTAssertEqual(value.updatedAt, old.updatedAt)
        XCTAssertEqual(reason, "Snapshot is older than five minutes.")
    }

    func testNewLiveUpdateReplacesStaleState() {
        let store = UsageStore()
        store.updateAccount(account)
        store.failAccount("temporary")
        let fresh = AccountUsageSnapshot(windows: [], planType: "pro", updatedAt: Date(timeIntervalSince1970: 200))
        store.updateAccount(fresh)
        guard case .live(let value) = store.snapshot.account else { return XCTFail("account should be live") }
        XCTAssertEqual(value, fresh)
    }

    func testOnChangeFiresOnlyWhenCombinedSnapshotChanges() {
        let store = UsageStore()
        var changes = 0
        store.onChange = { _ in changes += 1 }
        store.failAccount("unknown")
        store.failAccount("unknown")
        store.updateContext(context)
        store.updateContext(context)
        XCTAssertEqual(changes, 2)
    }
}
