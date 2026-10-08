import Foundation
import XCTest
@testable import CodexUsageCore

@MainActor
final class TiboAlertStoreTests: XCTestCase {
    func testFirstAcceptancePersistsPendingUnreadRecordBeforeReturning() throws {
        let defaults = makeDefaults()
        let store = TiboAlertStore(defaults: defaults)
        let message = makeMessage(id: "101")

        XCTAssertTrue(store.accept(message, checkedAt: date(200)))
        XCTAssertEqual(store.snapshot.latest?.id, "101")
        XCTAssertEqual(store.snapshot.latest?.verification, .pending)
        XCTAssertTrue(store.snapshot.unread)

        let reconstructed = TiboAlertStore(defaults: defaults)
        XCTAssertEqual(reconstructed.snapshot, store.snapshot)
        XCTAssertFalse(reconstructed.accept(message, checkedAt: date(300)))
        XCTAssertTrue(reconstructed.snapshot.unread)
    }

    func testSeenRingKeepsNewestThirtyTwoAndPreventsReorderedReplay() {
        let defaults = makeDefaults()
        let store = TiboAlertStore(defaults: defaults)
        for id in 1...33 {
            XCTAssertTrue(store.accept(makeMessage(id: String(id)), checkedAt: date(Double(id))))
        }

        XCTAssertFalse(store.accept(makeMessage(id: "2", summary: "翻译已更新"), checkedAt: date(100)))
        XCTAssertEqual(store.snapshot.latest?.id, "33")

        let reconstructed = TiboAlertStore(defaults: defaults)
        XCTAssertFalse(reconstructed.accept(makeMessage(id: "33", summary: "新的翻译"), checkedAt: date(101)))
        XCTAssertEqual(reconstructed.snapshot.latest?.localizedSummary, "新的翻译")
        XCTAssertTrue(reconstructed.snapshot.unread)

        XCTAssertTrue(reconstructed.accept(makeMessage(id: "1"), checkedAt: date(102)), "oldest ID should be evicted from the bounded ring")
    }

    func testCorruptTiboStateIsIsolatedFromUnrelatedDefaults() {
        let defaults = makeDefaults()
        defaults.set(37.5, forKey: "overlay.offsetX")
        defaults.set(Data([0xFF, 0x00]), forKey: "tiboAlertState.v1")

        let store = TiboAlertStore(defaults: defaults)

        XCTAssertNil(store.snapshot.latest)
        XCTAssertEqual(store.snapshot.health, .neverChecked)
        XCTAssertEqual(defaults.double(forKey: "overlay.offsetX"), 37.5)
    }

    func testVerificationMutationsAreScopedToCurrentIDAndAnomalyHidesContent() {
        let defaults = makeDefaults()
        let store = TiboAlertStore(defaults: defaults)
        XCTAssertTrue(store.accept(makeMessage(id: "101"), checkedAt: date(200)))
        XCTAssertTrue(store.accept(makeMessage(id: "102"), checkedAt: date(201)))

        store.markConfirmed(id: "101")
        XCTAssertEqual(store.snapshot.latest?.verification, .pending)

        store.markConfirmed(id: "102")
        XCTAssertEqual(store.snapshot.latest?.verification, .confirmed)

        store.markAnomalous(id: "101", at: date(250))
        XCTAssertEqual(store.snapshot.latest?.verification, .confirmed)

        store.markAnomalous(id: "102", at: date(251))
        XCTAssertEqual(store.snapshot.latest?.id, "102")
        XCTAssertEqual(store.snapshot.latest?.publishedAt, date(100))
        XCTAssertEqual(store.snapshot.latest?.verification, .anomalous)
        XCTAssertEqual(store.snapshot.latest?.verificationUpdatedAt, date(251))
        XCTAssertNil(store.snapshot.latest?.category)
        XCTAssertNil(store.snapshot.latest?.localizedSummary)
        XCTAssertNil(store.snapshot.latest?.canonicalURL)
        XCTAssertFalse(store.snapshot.unread)
    }

    func testRevealPersistsConsumesOnceAndReadChangesOnlyWhenExplicit() {
        let defaults = makeDefaults()
        let store = TiboAlertStore(defaults: defaults)
        XCTAssertTrue(store.accept(makeMessage(id: "101"), checkedAt: date(200)))

        store.requestReveal(id: "other")
        XCTAssertNil(store.snapshot.pendingRevealID)
        store.requestReveal(id: "101")
        XCTAssertEqual(store.snapshot.pendingRevealID, "101")
        XCTAssertTrue(store.snapshot.unread)

        let reconstructed = TiboAlertStore(defaults: defaults)
        XCTAssertTrue(reconstructed.consumePendingReveal(for: "101"))
        XCTAssertFalse(reconstructed.consumePendingReveal(for: "101"))
        XCTAssertTrue(reconstructed.snapshot.unread)

        reconstructed.markRead()
        XCTAssertFalse(reconstructed.snapshot.unread)
        reconstructed.markRead()
        XCTAssertFalse(reconstructed.snapshot.unread)
    }

    func testHealthPermissionAndOnChangeOnlyPublishRealSnapshotChanges() {
        let defaults = makeDefaults()
        let store = TiboAlertStore(defaults: defaults)
        var changes: [TiboAlertSnapshot] = []
        store.onChange = { changes.append($0) }

        store.updateHealth(.unavailable(checkedAt: date(20)))
        store.updateHealth(.unavailable(checkedAt: date(20)))
        store.setNotificationPermissionRequested()
        store.setNotificationPermissionRequested()

        XCTAssertEqual(changes.count, 2)
        XCTAssertTrue(store.snapshot.notificationPermissionRequested)
        XCTAssertTrue(TiboAlertStore(defaults: defaults).snapshot.notificationPermissionRequested)
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "TiboAlertStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeMessage(id: String, summary: String = "将进行一次额度重置") -> TiboMessage {
        TiboMessage(
            id: id,
            category: .resetAnnouncement,
            localizedSummary: summary,
            publishedAt: date(100),
            canonicalURL: URL(string: "https://x.com/thsottiaux/status/\(id)")!
        )
    }

    private func date(_ seconds: Double) -> Date {
        Date(timeIntervalSince1970: seconds)
    }
}
