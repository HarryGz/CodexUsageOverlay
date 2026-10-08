import Foundation
import XCTest
@testable import CodexUsageCore

@MainActor
final class TiboAlertCoordinatorTests: XCTestCase {
    func testFirstMessagePersistsBeforeOnePendingNotificationAndConfirmsWithoutDuplicate() async {
        let defaults = makeDefaults()
        let store = TiboAlertStore(defaults: defaults)
        let feed = CoordinatorFeed()
        let verifier = QueueVerifier(results: [.confirmed(id: "101")])
        let notifier = CoordinatorNotifier(authorized: true)
        let coordinator = makeCoordinator(store: store, feed: feed, verifier: verifier, notifier: notifier)

        coordinator.start()
        feed.emit(.success(result(message: message(id: "101"))))
        let completed = await eventually { store.snapshot.latest?.verification == .confirmed && notifier.delivered.count == 1 }
        XCTAssertTrue(completed)
        coordinator.stop()

        XCTAssertEqual(notifier.authorizationRequests, 1)
        XCTAssertEqual(notifier.delivered.count, 1)
        XCTAssertEqual(notifier.delivered.first?.messageID, "101")
        XCTAssertTrue(notifier.delivered.first?.body.contains("尚未经 X 二次确认") == true)
        XCTAssertTrue(notifier.delivered.first?.body.contains("不代表个人账户额度已到账") == true)
        XCTAssertTrue(store.snapshot.unread)
    }

    func testDeliveryWaitsForAuthorizationRequestToFinish() async {
        let store = TiboAlertStore(defaults: makeDefaults())
        let feed = CoordinatorFeed()
        let notifier = CoordinatorNotifier(authorized: true, suspendAuthorization: true)
        let coordinator = makeCoordinator(
            store: store,
            feed: feed,
            verifier: QueueVerifier(results: [.confirmed(id: "101")]),
            notifier: notifier
        )

        coordinator.start()
        feed.emit(.success(result(message: message(id: "101"))))
        let waiting = await eventually {
            store.snapshot.latest?.id == "101" && notifier.authorizationRequests == 1
        }
        XCTAssertTrue(waiting)
        XCTAssertTrue(notifier.delivered.isEmpty, "delivery must wait for the first authorization decision")

        notifier.resolveAuthorization()
        let delivered = await eventually { notifier.delivered.count == 1 }
        XCTAssertTrue(delivered)
        coordinator.stop()
    }

    func testPermissionRequestedOnlyOnceAcrossStoreReconstructionAndDenialDoesNotStopFeed() async {
        let defaults = makeDefaults()
        let notifier = CoordinatorNotifier(authorized: false)

        let firstFeed = CoordinatorFeed()
        let first = makeCoordinator(
            store: TiboAlertStore(defaults: defaults),
            feed: firstFeed,
            verifier: QueueVerifier(results: [.confirmed(id: "101")]),
            notifier: notifier
        )
        first.start()
        firstFeed.emit(.success(result(message: message(id: "101"))))
        let requested = await eventually { notifier.authorizationRequests == 1 }
        XCTAssertTrue(requested)
        let firstDelivered = await eventually { notifier.delivered.count == 1 }
        XCTAssertTrue(firstDelivered)
        first.stop()

        let reconstructed = TiboAlertStore(defaults: defaults)
        let secondFeed = CoordinatorFeed()
        let second = makeCoordinator(
            store: reconstructed,
            feed: secondFeed,
            verifier: QueueVerifier(results: [.confirmed(id: "102")]),
            notifier: notifier
        )
        second.start()
        secondFeed.emit(.success(result(message: message(id: "102"))))
        let accepted = await eventually { reconstructed.snapshot.latest?.id == "102" && notifier.delivered.count == 2 }
        XCTAssertTrue(accepted)
        second.stop()

        XCTAssertEqual(notifier.authorizationRequests, 1)
        XCTAssertEqual(secondFeed.startCount, 1)
        XCTAssertEqual(notifier.delivered.count, 2, "denial must not disable the in-app alert path")
    }

    func testTransientVerificationRetriesAtBoundedSequence() async {
        let store = TiboAlertStore(defaults: makeDefaults())
        let feed = CoordinatorFeed()
        let verifier = QueueVerifier(results: [
            .transientFailure(id: "101"),
            .transientFailure(id: "101"),
            .transientFailure(id: "101"),
            .confirmed(id: "101")
        ])
        let notifier = CoordinatorNotifier(authorized: true)
        let sleeper = CoordinatorSleeper()
        let coordinator = TiboAlertCoordinator(
            store: store,
            feed: feed,
            verifier: verifier,
            notifier: notifier,
            now: { Date() },
            sleeper: { duration in try await sleeper.sleep(duration) }
        )

        coordinator.start()
        feed.emit(.success(result(message: message(id: "101"))))
        let confirmed = await eventually { store.snapshot.latest?.verification == .confirmed }
        XCTAssertTrue(confirmed)
        coordinator.stop()

        let durations = await sleeper.durations
        XCTAssertEqual(durations, [900, 3_600, 21_600])
        XCTAssertEqual(notifier.delivered.count, 1)
    }

    func testAnomalyRemovesNotificationHidesContentAndSelectionOnlyRequestsReveal() async {
        let store = TiboAlertStore(defaults: makeDefaults())
        let feed = CoordinatorFeed()
        let notifier = CoordinatorNotifier(authorized: true)
        let coordinator = makeCoordinator(
            store: store,
            feed: feed,
            verifier: QueueVerifier(results: [.anomalous(id: "101")]),
            notifier: notifier
        )
        coordinator.start()
        feed.emit(.success(result(message: message(id: "101"))))
        let anomalous = await eventually { store.snapshot.latest?.verification == .anomalous }
        XCTAssertTrue(anomalous)

        XCTAssertEqual(notifier.removedIDs, ["101"])
        XCTAssertNil(store.snapshot.latest?.localizedSummary)
        XCTAssertNil(store.snapshot.latest?.canonicalURL)

        feed.emit(.success(result(message: message(id: "102"))))
        let delivered = await eventually { notifier.delivered.count == 2 }
        XCTAssertTrue(delivered)
        notifier.select(id: "102")
        XCTAssertEqual(store.snapshot.pendingRevealID, "102")
        XCTAssertTrue(store.snapshot.unread)
        coordinator.stop()
    }

    func testAnomalyRemovalRunsAfterHeldDeliveryCompletes() async {
        let store = TiboAlertStore(defaults: makeDefaults())
        let feed = CoordinatorFeed()
        let notifier = CoordinatorNotifier(authorized: true, suspendDelivery: true)
        let coordinator = makeCoordinator(
            store: store,
            feed: feed,
            verifier: QueueVerifier(results: [.anomalous(id: "101")]),
            notifier: notifier
        )

        coordinator.start()
        feed.emit(.success(result(message: message(id: "101"))))
        let raced = await eventually {
            store.snapshot.latest?.verification == .anomalous
                && notifier.deliveryStartedIDs == ["101"]
        }
        XCTAssertTrue(raced)
        XCTAssertTrue(notifier.removedIDs.isEmpty, "removal before delivery finishes can be undone by the late delivery")

        notifier.releaseDelivery(id: "101")
        let removed = await eventually { notifier.removedIDs == ["101"] }
        XCTAssertTrue(removed)
        XCTAssertEqual(notifier.delivered.map(\.messageID), ["101"])
        coordinator.stop()
    }

    func testOldVerificationCompletionCannotMutateNewerAlert() async {
        let store = TiboAlertStore(defaults: makeDefaults())
        let feed = CoordinatorFeed()
        let verifier = HoldingVerifier()
        let notifier = CoordinatorNotifier(authorized: true)
        let coordinator = makeCoordinator(store: store, feed: feed, verifier: verifier, notifier: notifier)
        coordinator.start()

        feed.emit(.success(result(message: message(id: "101"))))
        let firstStarted = await eventually { await verifier.requestedIDs.contains("101") }
        XCTAssertTrue(firstStarted)
        feed.emit(.success(result(message: message(id: "102"))))
        let secondStarted = await eventually { await verifier.requestedIDs.contains("102") }
        XCTAssertTrue(secondStarted)

        await verifier.complete(id: "102", result: .confirmed(id: "102"))
        let confirmed = await eventually { store.snapshot.latest?.verification == .confirmed }
        XCTAssertTrue(confirmed)
        await verifier.complete(id: "101", result: .anomalous(id: "101"))
        try? await Task.sleep(nanoseconds: 20_000_000)
        coordinator.stop()

        XCTAssertEqual(store.snapshot.latest?.id, "102")
        XCTAssertEqual(store.snapshot.latest?.verification, .confirmed)
        XCTAssertTrue(notifier.removedIDs.isEmpty)
    }

    private func makeCoordinator(
        store: TiboAlertStore,
        feed: CoordinatorFeed,
        verifier: any TiboSourceVerifying,
        notifier: CoordinatorNotifier
    ) -> TiboAlertCoordinator {
        TiboAlertCoordinator(
            store: store,
            feed: feed,
            verifier: verifier,
            notifier: notifier,
            now: { Date() },
            sleeper: { _ in throw CancellationError() }
        )
    }

    private func result(message: TiboMessage?) -> TiboFeedResult {
        let now = Date(timeIntervalSince1970: 500)
        return TiboFeedResult(fetchedAt: now, health: .healthy(checkedAt: now, fetchedAt: now), newestQualifyingMessage: message)
    }

    private func message(id: String) -> TiboMessage {
        TiboMessage(
            id: id,
            category: .resetAnnouncement,
            localizedSummary: "公开消息：将进行一次额度重置。",
            publishedAt: Date(timeIntervalSince1970: 100),
            canonicalURL: URL(string: "https://x.com/thsottiaux/status/\(id)")!
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "TiboAlertCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func eventually(
        timeout: TimeInterval = 1,
        condition: @escaping @MainActor () async -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return await condition()
    }
}

@MainActor
private final class CoordinatorFeed: TiboFeedServing {
    var onResult: ((Result<TiboFeedResult, TiboFeedClientError>) -> Void)?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var refreshCount = 0
    private(set) var wakeCount = 0

    func start() { startCount += 1 }
    func stop() { stopCount += 1 }
    func refreshNow() { refreshCount += 1 }
    func handleWake() { wakeCount += 1 }
    func emit(_ result: Result<TiboFeedResult, TiboFeedClientError>) { onResult?(result) }
}

private actor QueueVerifier: TiboSourceVerifying {
    private var results: [TiboVerificationResult]
    init(results: [TiboVerificationResult]) { self.results = results }
    func verify(_ message: TiboMessage) async -> TiboVerificationResult {
        guard !results.isEmpty else { return .transientFailure(id: message.id) }
        return results.removeFirst()
    }
}

private actor HoldingVerifier: TiboSourceVerifying {
    private(set) var requestedIDs: [String] = []
    private var continuations: [String: CheckedContinuation<TiboVerificationResult, Never>] = [:]

    func verify(_ message: TiboMessage) async -> TiboVerificationResult {
        requestedIDs.append(message.id)
        return await withCheckedContinuation { continuations[message.id] = $0 }
    }

    func complete(id: String, result: TiboVerificationResult) {
        continuations.removeValue(forKey: id)?.resume(returning: result)
    }
}

@MainActor
private final class CoordinatorNotifier: TiboNotificationSending {
    var onSelection: ((String) -> Void)?
    private(set) var authorizationRequests = 0
    private(set) var delivered: [TiboNotificationRequest] = []
    private(set) var removedIDs: [String] = []
    private(set) var deliveryStartedIDs: [String] = []
    private let authorized: Bool
    private let suspendAuthorization: Bool
    private let suspendDelivery: Bool
    private var authorizationContinuation: CheckedContinuation<Void, Never>?
    private var deliveryContinuations: [String: CheckedContinuation<Void, Never>] = [:]

    init(authorized: Bool, suspendAuthorization: Bool = false, suspendDelivery: Bool = false) {
        self.authorized = authorized
        self.suspendAuthorization = suspendAuthorization
        self.suspendDelivery = suspendDelivery
    }

    func requestAuthorization() async -> Bool {
        authorizationRequests += 1
        if suspendAuthorization {
            await withCheckedContinuation { authorizationContinuation = $0 }
        }
        return authorized
    }

    func deliver(_ request: TiboNotificationRequest) async {
        deliveryStartedIDs.append(request.messageID)
        if suspendDelivery {
            await withCheckedContinuation { deliveryContinuations[request.messageID] = $0 }
        }
        delivered.append(request)
    }

    func removeDelivered(id: String) { removedIDs.append(id) }
    func select(id: String) { onSelection?(id) }
    func resolveAuthorization() {
        authorizationContinuation?.resume()
        authorizationContinuation = nil
    }
    func releaseDelivery(id: String) { deliveryContinuations.removeValue(forKey: id)?.resume() }
}

private actor CoordinatorSleeper {
    private(set) var durations: [TimeInterval] = []
    func sleep(_ duration: TimeInterval) async throws {
        durations.append(duration)
        await Task.yield()
    }
}
