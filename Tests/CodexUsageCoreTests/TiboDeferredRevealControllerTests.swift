import Foundation
import XCTest
@testable import CodexUsageCore

@MainActor
final class TiboDeferredRevealControllerTests: XCTestCase {
    func testPendingRevealSurvivesFailedPresentationAndConsumesAfterRetry() {
        let suite = "TiboDeferredRevealControllerTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = TiboAlertStore(defaults: defaults)
        let message = TiboMessage(
            id: "101",
            category: .resetAnnouncement,
            localizedSummary: "公开消息：将进行一次额度重置。",
            publishedAt: Date(timeIntervalSince1970: 100),
            canonicalURL: URL(string: "https://x.com/thsottiaux/status/101")!
        )
        XCTAssertTrue(store.accept(message, checkedAt: Date(timeIntervalSince1970: 200)))
        store.requestReveal(id: "101")

        var presentationAllowed = false
        var presentationAttempts = 0
        let controller = TiboDeferredRevealController(store: store) {
            presentationAttempts += 1
            return presentationAllowed
        }

        controller.attempt()
        XCTAssertEqual(store.snapshot.pendingRevealID, "101")
        XCTAssertEqual(presentationAttempts, 1)

        presentationAllowed = true
        controller.attempt()
        XCTAssertNil(store.snapshot.pendingRevealID)
        XCTAssertEqual(presentationAttempts, 2)

        controller.attempt()
        XCTAssertEqual(presentationAttempts, 2, "a consumed reveal must not replay")
    }
}
