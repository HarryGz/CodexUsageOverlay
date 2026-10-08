import Foundation

@MainActor
public protocol TiboNotificationSending: AnyObject {
    var onSelection: ((String) -> Void)? { get set }
    func requestAuthorization() async -> Bool
    func deliver(_ request: TiboNotificationRequest) async
    func removeDelivered(id: String)
}

@MainActor
public final class TiboAlertCoordinator {
    private let store: TiboAlertStore
    private let feed: any TiboFeedServing
    private let verifier: any TiboSourceVerifying
    private let notifier: any TiboNotificationSending
    private let now: @Sendable () -> Date
    private let sleeper: @Sendable (TimeInterval) async throws -> Void

    private var started = false
    private var generation = 0
    private var permissionTask: Task<Void, Never>?
    private var verificationTask: Task<Void, Never>?

    public convenience init(
        store: TiboAlertStore,
        feed: any TiboFeedServing,
        verifier: any TiboSourceVerifying,
        notifier: any TiboNotificationSending
    ) {
        self.init(
            store: store,
            feed: feed,
            verifier: verifier,
            notifier: notifier,
            now: { Date() },
            sleeper: { duration in
                try await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000))
            }
        )
    }

    init(
        store: TiboAlertStore,
        feed: any TiboFeedServing,
        verifier: any TiboSourceVerifying,
        notifier: any TiboNotificationSending,
        now: @escaping @Sendable () -> Date,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void
    ) {
        self.store = store
        self.feed = feed
        self.verifier = verifier
        self.notifier = notifier
        self.now = now
        self.sleeper = sleeper
    }

    public func start() {
        guard !started else { return }
        started = true
        generation += 1
        let activeGeneration = generation

        notifier.onSelection = { [weak self] id in
            guard let self, self.started else { return }
            self.store.requestReveal(id: id)
        }
        feed.onResult = { [weak self] result in
            self?.handleFeedResult(result)
        }

        if !store.snapshot.notificationPermissionRequested {
            store.setNotificationPermissionRequested()
            permissionTask = Task { [weak self] in
                guard let self else { return }
                _ = await self.notifier.requestAuthorization()
                guard self.generation == activeGeneration else { return }
            }
        }

        if let record = store.snapshot.latest,
           record.verification == .pending,
           let message = message(from: record) {
            beginVerification(message)
        }
        feed.start()
    }

    public func stop() {
        guard started else { return }
        started = false
        generation += 1
        feed.stop()
        feed.onResult = nil
        notifier.onSelection = nil
        permissionTask?.cancel()
        permissionTask = nil
        verificationTask?.cancel()
        verificationTask = nil
    }

    public func refreshNow() { feed.refreshNow() }
    public func handleWake() { feed.handleWake() }

    private func handleFeedResult(_ result: Result<TiboFeedResult, TiboFeedClientError>) {
        guard started else { return }
        switch result {
        case let .success(feedResult):
            store.updateHealth(feedResult.health)
            guard let message = feedResult.newestQualifyingMessage else { return }
            let isNew = store.accept(message, checkedAt: now())
            guard isNew else { return }
            verificationTask?.cancel()
            let request = notification(for: message)
            Task { [notifier] in await notifier.deliver(request) }
            beginVerification(message)
        case let .failure(error):
            if error == .parser(.staleFeed) || error == .parser(.feedTooOld) {
                store.updateHealth(.stale(checkedAt: now()))
            } else {
                store.updateHealth(.unavailable(checkedAt: now()))
            }
        }
    }

    private func beginVerification(_ message: TiboMessage) {
        verificationTask?.cancel()
        let activeGeneration = generation
        let verifier = self.verifier
        let sleeper = self.sleeper
        verificationTask = Task { [weak self] in
            guard let self else { return }
            let delays: [TimeInterval] = [900, 3_600, 21_600]
            var retryIndex = 0
            while !Task.isCancelled {
                let result = await verifier.verify(message)
                guard !Task.isCancelled,
                      self.started,
                      self.generation == activeGeneration,
                      result.id == message.id,
                      self.store.snapshot.latest?.id == message.id,
                      self.store.snapshot.latest?.verification == .pending else { return }

                switch result {
                case .confirmed:
                    self.store.markConfirmed(id: message.id)
                    return
                case .anomalous:
                    self.store.markAnomalous(id: message.id, at: self.now())
                    self.notifier.removeDelivered(id: message.id)
                    return
                case .transientFailure:
                    let delay = delays[min(retryIndex, delays.count - 1)]
                    retryIndex += 1
                    do {
                        try await sleeper(delay)
                    } catch {
                        return
                    }
                }
            }
        }
    }

    private func notification(for message: TiboMessage) -> TiboNotificationRequest {
        let category: String
        switch message.category {
        case .resetAnnouncement: category = "重置预告"
        case .resetCompleted: category = "已完成"
        case .bankedReset: category = "备用重置"
        case .strongHint: category = "强烈暗示"
        }
        return TiboNotificationRequest(
            messageID: message.id,
            title: "Tibo 动态：\(category)（等待 X 确认）",
            body: "\(message.localizedSummary)\n尚未经 X 二次确认；这是公开消息，不代表个人账户额度已到账。"
        )
    }

    private func message(from record: TiboAlertRecord) -> TiboMessage? {
        guard let category = record.category,
              let summary = record.localizedSummary,
              let url = record.canonicalURL else { return nil }
        return TiboMessage(
            id: record.id,
            category: category,
            localizedSummary: summary,
            publishedAt: record.publishedAt,
            canonicalURL: url
        )
    }
}
