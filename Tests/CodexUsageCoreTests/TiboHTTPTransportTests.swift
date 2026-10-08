import Foundation
import XCTest
@testable import CodexUsageCore

final class TiboHTTPTransportTests: XCTestCase {
    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    func testRejectsDeclaredOversizeResponseBeforeReturningBody() async {
        StubURLProtocol.configure(body: Data(repeating: 0x41, count: 64), declaredLength: 64)
        let transport = makeTransport()
        let request = URLRequest(url: URL(string: "https://codex-reset.com/api/feed?locale=zh")!)

        do {
            _ = try await transport.response(for: request, maximumBodyBytes: 16)
            XCTFail("expected streaming byte limit failure")
        } catch let error as TiboHTTPTransportError {
            XCTAssertEqual(error, .bodyTooLarge)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testSharedTransportHandlesConcurrentFirstRequestsWithOneEagerSession() async throws {
        StubURLProtocol.configure(body: Data("{}".utf8), declaredLength: 2)
        let transport = makeTransport()
        let request = URLRequest(url: URL(string: "https://codex-reset.com/api/feed?locale=zh")!)

        let counts = try await withThrowingTaskGroup(of: Int.self) { group in
            for _ in 0..<12 {
                group.addTask {
                    try await transport.response(for: request, maximumBodyBytes: 16).body.count
                }
            }
            var values: [Int] = []
            for try await value in group { values.append(value) }
            return values
        }

        XCTAssertEqual(counts, Array(repeating: 2, count: 12))
        XCTAssertEqual(StubURLProtocol.requestCount, 12)
    }

    private func makeTransport() -> TiboURLSessionTransport {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return TiboURLSessionTransport(configuration: configuration)
    }
}

private final class StubURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var body = Data()
    private static var declaredLength = 0
    private static var requests = 0

    static var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }

    static func configure(body: Data, declaredLength: Int) {
        lock.lock()
        self.body = body
        self.declaredLength = declaredLength
        requests = 0
        lock.unlock()
    }

    static func reset() { configure(body: Data(), declaredLength: 0) }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lock.lock()
        let responseBody = Self.body
        let length = Self.declaredLength
        Self.requests += 1
        Self.lock.unlock()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json", "Content-Length": String(length)]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: responseBody)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
