import Foundation
import XCTest
@testable import CodexUsageCore

final class TiboSourceVerifierTests: XCTestCase {
    func testBuildsExactOEmbedRequestAndConfirmsMatchingIdentity() async throws {
        let transport = VerifierTransport(response: response(json: [
            "provider_name": "X",
            "author_name": "Tibo",
            "author_url": "https://x.com/thsottiaux/",
            "url": "https://x.com/thsottiaux/status/2106845241357824205",
            "html": "<script>must never be interpreted</script>"
        ]))
        let verifier = TiboSourceVerifier(transport: transport)

        let result = await verifier.verify(message())

        XCTAssertEqual(result, .confirmed(id: message().id))
        let request = await transport.lastRequest
        let components = try XCTUnwrap(URLComponents(url: try XCTUnwrap(request?.url), resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.scheme, "https")
        XCTAssertEqual(components.host, "publish.x.com")
        XCTAssertEqual(components.path, "/oembed")
        XCTAssertEqual(Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value ?? "") }), [
            "url": message().canonicalURL.absoluteString,
            "omit_script": "true"
        ])
        XCTAssertEqual(request?.value(forHTTPHeaderField: "Accept"), "application/json")
    }

    func testSuccessfulIdentityMismatchIsAnomalous() async {
        let mismatches: [[String: Any]] = [
            ["provider_name": "Twitter", "author_name": "Tibo", "author_url": "https://x.com/thsottiaux", "url": message().canonicalURL.absoluteString],
            ["provider_name": "X", "author_name": "Someone", "author_url": "https://x.com/thsottiaux", "url": message().canonicalURL.absoluteString],
            ["provider_name": "X", "author_name": "Tibo", "author_url": "https://x.com/other", "url": message().canonicalURL.absoluteString],
            ["provider_name": "X", "author_name": "Tibo", "author_url": "https://x.com/thsottiaux", "url": "https://x.com/thsottiaux/status/999"]
        ]

        for payload in mismatches {
            let verifier = TiboSourceVerifier(transport: VerifierTransport(response: response(json: payload)))
            let result = await verifier.verify(message())
            XCTAssertEqual(result, .anomalous(id: message().id))
        }
    }

    func testTimeoutRateLimitServerErrorOversizeAndMalformedBodyStayTransient() async {
        let responses: [VerifierTransport.Mode] = [
            .failure(URLError(.timedOut)),
            .response(response(status: 429, data: Data())),
            .response(response(status: 503, data: Data())),
            .response(response(status: 200, data: Data(repeating: 0x20, count: TiboAlertLimits.oEmbedResponseBytes + 1))),
            .response(response(status: 200, data: Data("not-json".utf8))),
            .response(response(status: 200, data: Data(), finalURL: URL(string: "https://example.com/oembed")!))
        ]

        for mode in responses {
            let verifier = TiboSourceVerifier(transport: VerifierTransport(mode: mode))
            let result = await verifier.verify(message())
            XCTAssertEqual(result, .transientFailure(id: message().id))
        }
    }

    private func message() -> TiboMessage {
        TiboMessage(
            id: "2106845241357824205",
            category: .strongHint,
            localizedSummary: "接下来 28 天每天发布改进或完整重置。",
            publishedAt: Date(timeIntervalSince1970: 100),
            canonicalURL: URL(string: "https://x.com/thsottiaux/status/2106845241357824205")!
        )
    }

    private func response(
        status: Int = 200,
        json: [String: Any]
    ) -> TiboHTTPResponse {
        response(status: status, data: try! JSONSerialization.data(withJSONObject: json))
    }

    private func response(
        status: Int,
        data: Data,
        finalURL: URL = URL(string: "https://publish.x.com/oembed")!
    ) -> TiboHTTPResponse {
        TiboHTTPResponse(statusCode: status, finalURL: finalURL, headers: [:], body: data)
    }
}

private actor VerifierTransport: TiboHTTPTransport {
    enum Mode {
        case response(TiboHTTPResponse)
        case failure(Error)
    }

    private(set) var lastRequest: URLRequest?
    private let mode: Mode

    init(response: TiboHTTPResponse) { mode = .response(response) }
    init(mode: Mode) { self.mode = mode }

    func response(for request: URLRequest, maximumBodyBytes: Int) async throws -> TiboHTTPResponse {
        lastRequest = request
        switch mode {
        case let .response(response): return response
        case let .failure(error): throw error
        }
    }
}
