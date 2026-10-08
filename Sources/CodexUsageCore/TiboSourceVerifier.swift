import Foundation

public enum TiboVerificationResult: Equatable, Sendable {
    case confirmed(id: String)
    case transientFailure(id: String)
    case anomalous(id: String)

    public var id: String {
        switch self {
        case let .confirmed(id), let .transientFailure(id), let .anomalous(id): return id
        }
    }
}

public protocol TiboSourceVerifying: Sendable {
    func verify(_ message: TiboMessage) async -> TiboVerificationResult
}

public struct TiboSourceVerifier: TiboSourceVerifying, Sendable {
    private let transport: any TiboHTTPTransport
    private let userAgent: String

    public init(
        transport: any TiboHTTPTransport = TiboURLSessionTransport(),
        userAgent: String = "CodexUsageOverlay/0.2.0 (+https://github.com/HarryGz/CodexUsageOverlay)"
    ) {
        self.transport = transport
        self.userAgent = userAgent
    }

    public func verify(_ message: TiboMessage) async -> TiboVerificationResult {
        guard let url = requestURL(for: message) else { return .anomalous(id: message.id) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let response: TiboHTTPResponse
        do {
            response = try await transport.response(for: request)
        } catch {
            return .transientFailure(id: message.id)
        }

        guard response.statusCode == 200,
              response.finalURL.scheme?.lowercased() == "https",
              response.finalURL.host?.lowercased() == "publish.x.com",
              response.body.count <= TiboAlertLimits.oEmbedResponseBytes,
              let payload = try? JSONDecoder().decode(OEmbedIdentity.self, from: response.body) else {
            return .transientFailure(id: message.id)
        }

        guard payload.providerName == "X",
              payload.authorName == "Tibo",
              normalizedAuthorURL(payload.authorURL) == "https://x.com/thsottiaux",
              payload.url == message.canonicalURL.absoluteString else {
            return .anomalous(id: message.id)
        }
        return .confirmed(id: message.id)
    }

    private func requestURL(for message: TiboMessage) -> URL? {
        guard message.canonicalURL.absoluteString == "https://x.com/thsottiaux/status/\(message.id)" else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "publish.x.com"
        components.path = "/oembed"
        components.queryItems = [
            URLQueryItem(name: "url", value: message.canonicalURL.absoluteString),
            URLQueryItem(name: "omit_script", value: "true")
        ]
        return components.url
    }

    private func normalizedAuthorURL(_ value: String) -> String? {
        guard var components = URLComponents(string: value),
              components.scheme?.lowercased() == "https",
              components.host?.lowercased() == "x.com",
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else { return nil }
        var path = components.path
        while path.count > 1 && path.hasSuffix("/") { path.removeLast() }
        guard path == "/thsottiaux" else { return nil }
        components.scheme = "https"
        components.host = "x.com"
        components.path = path
        return components.url?.absoluteString
    }
}

private struct OEmbedIdentity: Decodable {
    let providerName: String
    let authorName: String
    let authorURL: String
    let url: String

    enum CodingKeys: String, CodingKey {
        case providerName = "provider_name"
        case authorName = "author_name"
        case authorURL = "author_url"
        case url
    }
}
