import Foundation

public enum TiboFeedClientError: Error, Equatable, Sendable {
    case transport
    case disallowedResponseURL
    case httpStatus(Int)
    case responseTooLarge
    case parser(TiboFeedParserError)
}

@MainActor
public protocol TiboFeedServing: AnyObject {
    var onResult: ((Result<TiboFeedResult, TiboFeedClientError>) -> Void)? { get set }
    func start()
    func stop()
    func refreshNow()
    func handleWake()
}

@MainActor
public final class TiboFeedClient: TiboFeedServing {
    public static let etagKey = "tiboFeedETag"
    public static let lastModifiedKey = "tiboFeedLastModified"
    public static let feedURL = URL(string: "https://codex-reset.com/api/feed?locale=zh")!

    public var onResult: ((Result<TiboFeedResult, TiboFeedClientError>) -> Void)?

    private let transport: any TiboHTTPTransport
    private let defaults: UserDefaults
    private let interval: TimeInterval
    private let minimumSpacing: TimeInterval
    private let now: @Sendable () -> Date
    private let sleeper: @Sendable (TimeInterval) async throws -> Void
    private let userAgent: String

    private var started = false
    private var generation = 0
    private var lastRequestStartedAt: Date?
    private var requestInFlight = false
    private var queuedRefresh = false
    private var requestTask: Task<Void, Never>?
    private var timerTask: Task<Void, Never>?

    public convenience init(defaults: UserDefaults = .standard) {
        self.init(transport: TiboURLSessionTransport(), defaults: defaults)
    }

    public convenience init(
        transport: any TiboHTTPTransport,
        defaults: UserDefaults = .standard
    ) {
        self.init(
            transport: transport,
            defaults: defaults,
            interval: 300,
            minimumSpacing: 300,
            now: { Date() },
            sleeper: { duration in
                try await Task.sleep(nanoseconds: UInt64(max(0, duration) * 1_000_000_000))
            }
        )
    }

    init(
        transport: any TiboHTTPTransport,
        defaults: UserDefaults,
        interval: TimeInterval,
        minimumSpacing: TimeInterval,
        now: @escaping @Sendable () -> Date,
        sleeper: @escaping @Sendable (TimeInterval) async throws -> Void,
        userAgent: String = "CodexUsageOverlay/0.2.0 (+https://github.com/HarryGz/CodexUsageOverlay)"
    ) {
        self.transport = transport
        self.defaults = defaults
        self.interval = interval
        self.minimumSpacing = minimumSpacing
        self.now = now
        self.sleeper = sleeper
        self.userAgent = userAgent
    }

    public func start() {
        guard !started else { return }
        started = true
        generation += 1
        trigger(force: true)
        scheduleTimer()
    }

    public func stop() {
        guard started else { return }
        started = false
        generation += 1
        queuedRefresh = false
        requestInFlight = false
        requestTask?.cancel()
        requestTask = nil
        timerTask?.cancel()
        timerTask = nil
    }

    public func refreshNow() {
        trigger(force: false)
    }

    public func handleWake() {
        let wasDue = isDue(at: now())
        trigger(force: false)
        if wasDue && started { scheduleTimer() }
    }

    private func trigger(force: Bool) {
        guard started else { return }
        let current = now()
        guard force || isDue(at: current) else { return }

        if requestInFlight {
            queuedRefresh = true
            return
        }
        beginRequest(at: current)
    }

    private func isDue(at date: Date) -> Bool {
        guard let lastRequestStartedAt else { return true }
        return date.timeIntervalSince(lastRequestStartedAt) >= minimumSpacing
    }

    private func beginRequest(at startedAt: Date) {
        requestInFlight = true
        lastRequestStartedAt = startedAt
        let activeGeneration = generation
        let request = makeRequest()
        let transport = self.transport

        requestTask = Task { [weak self] in
            guard let self else { return }
            let result: Result<TiboFeedResult?, TiboFeedClientError>
            do {
                let response = try await transport.response(for: request)
                result = self.process(response: response, now: self.now())
            } catch is CancellationError {
                return
            } catch {
                result = .failure(.transport)
            }
            guard !Task.isCancelled else { return }
            self.finish(result, generation: activeGeneration)
        }
    }

    private func finish(
        _ result: Result<TiboFeedResult?, TiboFeedClientError>,
        generation activeGeneration: Int
    ) {
        guard started, generation == activeGeneration else { return }
        requestInFlight = false
        requestTask = nil

        switch result {
        case let .success(.some(feedResult)):
            onResult?(.success(feedResult))
        case .success(.none):
            break
        case let .failure(error):
            onResult?(.failure(error))
        }

        if queuedRefresh {
            queuedRefresh = false
            trigger(force: false)
        }
    }

    private func makeRequest() -> URLRequest {
        var request = URLRequest(url: Self.feedURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        if let etag = defaults.string(forKey: Self.etagKey), !etag.isEmpty {
            request.setValue(etag, forHTTPHeaderField: "If-None-Match")
        }
        if let modified = defaults.string(forKey: Self.lastModifiedKey), !modified.isEmpty {
            request.setValue(modified, forHTTPHeaderField: "If-Modified-Since")
        }
        return request
    }

    private func process(
        response: TiboHTTPResponse,
        now: Date
    ) -> Result<TiboFeedResult?, TiboFeedClientError> {
        guard response.finalURL.scheme?.lowercased() == "https",
              response.finalURL.host?.lowercased() == "codex-reset.com",
              response.finalURL.user == nil,
              response.finalURL.password == nil else {
            return .failure(.disallowedResponseURL)
        }
        guard response.statusCode == 200 || response.statusCode == 304 else {
            return .failure(.httpStatus(response.statusCode))
        }
        if response.statusCode == 304 {
            persistValidators(from: response)
            return .success(nil)
        }
        guard response.body.count <= TiboAlertLimits.feedResponseBytes else {
            return .failure(.responseTooLarge)
        }
        do {
            let parsed = try TiboFeedParser.parse(data: response.body, now: now)
            persistValidators(from: response)
            return .success(parsed)
        } catch let error as TiboFeedParserError {
            return .failure(.parser(error))
        } catch {
            return .failure(.parser(.invalidJSON))
        }
    }

    private func persistValidators(from response: TiboHTTPResponse) {
        if let etag = response.headers["etag"], !etag.isEmpty {
            defaults.set(etag, forKey: Self.etagKey)
        }
        if let lastModified = response.headers["last-modified"], !lastModified.isEmpty {
            defaults.set(lastModified, forKey: Self.lastModifiedKey)
        }
    }

    private func scheduleTimer() {
        timerTask?.cancel()
        let activeGeneration = generation
        let sleeper = self.sleeper
        let interval = self.interval
        timerTask = Task { [weak self] in
            do {
                try await sleeper(interval)
            } catch {
                return
            }
            guard !Task.isCancelled,
                  let self,
                  self.started,
                  self.generation == activeGeneration else { return }
            self.timerTask = nil
            self.trigger(force: false)
            self.scheduleTimer()
        }
    }
}
