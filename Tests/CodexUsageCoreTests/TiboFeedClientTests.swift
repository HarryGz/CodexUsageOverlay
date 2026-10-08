import Foundation
import XCTest
@testable import CodexUsageCore

@MainActor
final class TiboFeedClientTests: XCTestCase {
    func testBuildsExactConditionalRequestAndPublishesParsedResponseOnMain() async {
        let defaults = makeDefaults()
        defaults.set("\"feed-v1\"", forKey: TiboFeedClient.etagKey)
        defaults.set("Wed, 08 Oct 2026 05:00:00 GMT", forKey: TiboFeedClient.lastModifiedKey)
        let transport = RecordingTransport(response: response(body: validFeed()))
        let clock = LockedClock(date("2026-10-08T05:30:00Z"))
        let client = makeClient(transport: transport, defaults: defaults, clock: clock)
        var results: [Result<TiboFeedResult, TiboFeedClientError>] = []
        client.onResult = {
            XCTAssertTrue(Thread.isMainThread)
            results.append($0)
        }

        client.start()
        let received = await eventually { await transport.requestCount == 1 && results.count == 1 }
        XCTAssertTrue(received)
        client.stop()

        let request = await transport.requests.first
        XCTAssertEqual(request?.url?.absoluteString, "https://codex-reset.com/api/feed?locale=zh")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "If-None-Match"), "\"feed-v1\"")
        XCTAssertEqual(request?.value(forHTTPHeaderField: "If-Modified-Since"), "Wed, 08 Oct 2026 05:00:00 GMT")
        XCTAssertTrue(request?.value(forHTTPHeaderField: "User-Agent")?.contains("CodexUsageOverlay/") == true)
        XCTAssertEqual(try? results.first?.get().newestQualifyingMessage?.id, "2108040921044639779")
    }

    func testStoresValidatorsAndTreats304AsNoChange() async {
        let defaults = makeDefaults()
        let first = response(
            body: validFeed(),
            headers: ["etag": "\"next\"", "last-modified": "Wed, 08 Oct 2026 05:29:00 GMT"]
        )
        let transport = RecordingTransport(responses: [first, response(status: 304, body: Data())])
        let clock = LockedClock(date("2026-10-08T05:30:00Z"))
        let client = makeClient(transport: transport, defaults: defaults, clock: clock)
        var callbackCount = 0
        client.onResult = { _ in callbackCount += 1 }

        client.start()
        let receivedFirst = await eventually { callbackCount == 1 }
        XCTAssertTrue(receivedFirst)
        clock.advance(by: 300)
        client.refreshNow()
        let receivedSecond = await eventually { await transport.requestCount == 2 }
        XCTAssertTrue(receivedSecond)
        client.stop()

        XCTAssertEqual(callbackCount, 1)
        XCTAssertEqual(defaults.string(forKey: TiboFeedClient.etagKey), "\"next\"")
        XCTAssertEqual(defaults.string(forKey: TiboFeedClient.lastModifiedKey), "Wed, 08 Oct 2026 05:29:00 GMT")
        let second = await transport.requests[1]
        XCTAssertEqual(second.value(forHTTPHeaderField: "If-None-Match"), "\"next\"")
    }

    func testRejectsOversizeHTTPAndNonAllowlistedFinalURLs() async {
        let cases: [(TiboHTTPResponse, TiboFeedClientError)] = [
            (response(body: Data(repeating: 0x20, count: TiboAlertLimits.feedResponseBytes + 1)), .responseTooLarge),
            (response(body: validFeed(), finalURL: URL(string: "http://codex-reset.com/api/feed")!), .disallowedResponseURL),
            (response(body: validFeed(), finalURL: URL(string: "https://example.com/api/feed")!), .disallowedResponseURL),
            (response(status: 503, body: Data()), .httpStatus(503))
        ]

        for (httpResponse, expected) in cases {
            let transport = RecordingTransport(response: httpResponse)
            let client = makeClient(
                transport: transport,
                defaults: makeDefaults(),
                clock: LockedClock(date("2026-10-08T05:30:00Z"))
            )
            var result: Result<TiboFeedResult, TiboFeedClientError>?
            client.onResult = { result = $0 }
            client.start()
            let received = await eventually { result != nil }
            XCTAssertTrue(received)
            client.stop()
            guard case let .failure(error) = result else {
                return XCTFail("expected failure for \(httpResponse)")
            }
            XCTAssertEqual(error, expected)
        }
    }

    func testStartRunsImmediatelyThenUsesThreeHundredSecondInterval() async {
        let transport = RecordingTransport(response: response(body: validFeed()))
        let clock = LockedClock(date("2026-10-08T05:30:00Z"))
        let sleeper = AdvancingSleeper(clock: clock, successfulSleeps: 1)
        let client = TiboFeedClient(
            transport: transport,
            defaults: makeDefaults(),
            interval: 300,
            minimumSpacing: 300,
            now: { clock.now },
            sleeper: { duration in try await sleeper.sleep(duration) }
        )
        var callbackCount = 0
        client.onResult = { _ in callbackCount += 1 }

        client.start()
        let received = await eventually { await transport.requestCount == 2 && callbackCount == 2 }
        XCTAssertTrue(received)
        client.stop()

        let durations = await sleeper.recordedDurations
        let maximumActive = await transport.maximumActiveRequests
        XCTAssertEqual(durations, [300, 300])
        XCTAssertEqual(maximumActive, 1)
    }

    func testManualAndWakeRespectMinimumSpacingAndDueWakeRestartsTimer() async {
        let transport = RecordingTransport(response: response(body: validFeed()))
        let clock = LockedClock(date("2026-10-08T05:30:00Z"))
        let sleeper = RecordingCancellationSleeper()
        let client = TiboFeedClient(
            transport: transport,
            defaults: makeDefaults(),
            interval: 300,
            minimumSpacing: 300,
            now: { clock.now },
            sleeper: { duration in try await sleeper.sleep(duration) }
        )

        client.start()
        let receivedFirst = await eventually { await transport.requestCount == 1 }
        XCTAssertTrue(receivedFirst)
        client.refreshNow()
        client.handleWake()
        let earlyRepeat = await eventually(timeout: 0.08) { await transport.requestCount > 1 }
        XCTAssertFalse(earlyRepeat)

        clock.advance(by: 300)
        client.handleWake()
        let receivedSecond = await eventually { await transport.requestCount == 2 }
        XCTAssertTrue(receivedSecond)
        client.stop()
        let durationCount = await sleeper.recordedDurations.count
        XCTAssertGreaterThanOrEqual(durationCount, 2, "due wake must restart the interval")
    }

    func testStopCancelsFutureChecks() async {
        let transport = RecordingTransport(response: response(body: validFeed()))
        let client = makeClient(
            transport: transport,
            defaults: makeDefaults(),
            clock: LockedClock(date("2026-10-08T05:30:00Z"))
        )
        client.start()
        let received = await eventually { await transport.requestCount == 1 }
        XCTAssertTrue(received)
        client.stop()
        client.refreshNow()
        client.handleWake()
        let repeated = await eventually(timeout: 0.08) { await transport.requestCount > 1 }
        XCTAssertFalse(repeated)
    }

    func testConcurrentTriggersCoalesceWhileRequestIsInFlight() async {
        let transport = RecordingTransport(response: response(body: validFeed()), held: true)
        let clock = LockedClock(date("2026-10-08T05:30:00Z"))
        let client = makeClient(transport: transport, defaults: makeDefaults(), clock: clock)
        var callbackCount = 0
        client.onResult = { _ in callbackCount += 1 }

        client.start()
        let receivedFirst = await eventually { await transport.requestCount == 1 }
        XCTAssertTrue(receivedFirst)
        clock.advance(by: 300)
        client.refreshNow()
        client.handleWake()
        client.refreshNow()
        let requestCountWhileHeld = await transport.requestCount
        let activeWhileHeld = await transport.maximumActiveRequests
        XCTAssertEqual(requestCountWhileHeld, 1)
        XCTAssertEqual(activeWhileHeld, 1)

        await transport.releaseOne()
        let receivedSecond = await eventually { await transport.requestCount == 2 }
        XCTAssertTrue(receivedSecond)
        let maximumActive = await transport.maximumActiveRequests
        XCTAssertEqual(maximumActive, 1)
        await transport.releaseOne()
        let receivedCallbacks = await eventually { callbackCount == 2 }
        XCTAssertTrue(receivedCallbacks)
        client.stop()
        let finalRequestCount = await transport.requestCount
        XCTAssertEqual(finalRequestCount, 2)
    }

    private func makeClient(
        transport: RecordingTransport,
        defaults: UserDefaults,
        clock: LockedClock
    ) -> TiboFeedClient {
        TiboFeedClient(
            transport: transport,
            defaults: defaults,
            interval: 300,
            minimumSpacing: 300,
            now: { clock.now },
            sleeper: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }
        )
    }

    private func response(
        status: Int = 200,
        body: Data,
        headers: [String: String] = [:],
        finalURL: URL = URL(string: "https://codex-reset.com/api/feed?locale=zh")!
    ) -> TiboHTTPResponse {
        TiboHTTPResponse(statusCode: status, finalURL: finalURL, headers: headers, body: body)
    }

    private func validFeed() -> Data {
        let json: [String: Any] = [
            "version": 1,
            "fetched_at": "2026-10-08T05:29:00Z",
            "source": "x-api",
            "source_scope": "timeline",
            "stale": false,
            "profile": ["handle": "thsottiaux", "name": "Tibo"],
            "tweets": [[
                "id": "2108040921044639779",
                "url": "https://x.com/thsottiaux/status/2108040921044639779",
                "text": "Confirmed landed across all accounts.",
                "localized_text": "所有账户均已确认到账。",
                "at": "2026-10-08T05:20:00Z",
                "kind": "other",
                "tibo_lane": "reset_related",
                "banked_state": "available",
                "is_reply": false
            ]]
        ]
        return try! JSONSerialization.data(withJSONObject: json, options: [.sortedKeys])
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "TiboFeedClientTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func date(_ value: String) -> Date {
        ISO8601DateFormatter().date(from: value)!
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

private actor RecordingTransport: TiboHTTPTransport {
    private(set) var requests: [URLRequest] = []
    private(set) var maximumActiveRequests = 0
    private var activeRequests = 0
    private var responses: [TiboHTTPResponse]
    private var held: Bool
    private var releases: [CheckedContinuation<Void, Never>] = []

    var requestCount: Int { requests.count }

    init(response: TiboHTTPResponse, held: Bool = false) {
        responses = [response]
        self.held = held
    }

    init(responses: [TiboHTTPResponse]) {
        self.responses = responses
        held = false
    }

    func response(for request: URLRequest) async throws -> TiboHTTPResponse {
        requests.append(request)
        activeRequests += 1
        maximumActiveRequests = max(maximumActiveRequests, activeRequests)
        if held {
            await withCheckedContinuation { continuation in releases.append(continuation) }
        }
        activeRequests -= 1
        let index = min(requests.count - 1, responses.count - 1)
        return responses[index]
    }

    func releaseOne() {
        guard !releases.isEmpty else { return }
        releases.removeFirst().resume()
    }
}

private final class LockedClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date

    init(_ value: Date) { self.value = value }

    var now: Date {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value = value.addingTimeInterval(interval)
        lock.unlock()
    }
}

private actor AdvancingSleeper {
    private(set) var recordedDurations: [TimeInterval] = []
    private let clock: LockedClock
    private var successfulSleeps: Int

    init(clock: LockedClock, successfulSleeps: Int) {
        self.clock = clock
        self.successfulSleeps = successfulSleeps
    }

    func sleep(_ duration: TimeInterval) async throws {
        recordedDurations.append(duration)
        guard successfulSleeps > 0 else { throw CancellationError() }
        successfulSleeps -= 1
        clock.advance(by: duration)
        await Task.yield()
    }
}

private actor RecordingCancellationSleeper {
    private(set) var recordedDurations: [TimeInterval] = []

    func sleep(_ duration: TimeInterval) async throws {
        recordedDurations.append(duration)
        throw CancellationError()
    }
}
