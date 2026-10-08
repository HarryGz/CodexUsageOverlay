import Foundation

public struct TiboHTTPResponse: Equatable, Sendable {
    public let statusCode: Int
    public let finalURL: URL
    public let headers: [String: String]
    public let body: Data

    public init(statusCode: Int, finalURL: URL, headers: [String: String], body: Data) {
        self.statusCode = statusCode
        self.finalURL = finalURL
        self.headers = Dictionary(uniqueKeysWithValues: headers.map { ($0.key.lowercased(), $0.value) })
        self.body = body
    }
}

public protocol TiboHTTPTransport: Sendable {
    func response(for request: URLRequest) async throws -> TiboHTTPResponse
}

public final class TiboURLSessionTransport: NSObject, TiboHTTPTransport, @unchecked Sendable {
    public static let allowedHosts: Set<String> = ["codex-reset.com", "publish.x.com"]

    private let redirectDelegate: TiboRedirectDelegate
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 20
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpMaximumConnectionsPerHost = 1
        configuration.requestCachePolicy = .useProtocolCachePolicy
        configuration.urlCache = URLCache(memoryCapacity: 2 * 1_048_576, diskCapacity: 0)
        return URLSession(configuration: configuration, delegate: redirectDelegate, delegateQueue: nil)
    }()

    public override init() {
        redirectDelegate = TiboRedirectDelegate(allowedHosts: Self.allowedHosts)
        super.init()
    }

    public func response(for request: URLRequest) async throws -> TiboHTTPResponse {
        guard Self.isAllowed(request.url) else { throw TiboHTTPTransportError.disallowedURL }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse,
              let finalURL = response.url,
              Self.isAllowed(finalURL) else {
            throw TiboHTTPTransportError.invalidResponse
        }
        var headers: [String: String] = [:]
        for (key, value) in response.allHeaderFields {
            guard let key = key as? String else { continue }
            headers[key.lowercased()] = String(describing: value)
        }
        return TiboHTTPResponse(
            statusCode: response.statusCode,
            finalURL: finalURL,
            headers: headers,
            body: data
        )
    }

    private static func isAllowed(_ url: URL?) -> Bool {
        guard let url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              allowedHosts.contains(host),
              url.user == nil,
              url.password == nil else { return false }
        return true
    }
}

public enum TiboHTTPTransportError: Error, Equatable, Sendable {
    case disallowedURL
    case invalidResponse
}

private final class TiboRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let allowedHosts: Set<String>

    init(allowedHosts: Set<String>) {
        self.allowedHosts = allowedHosts
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        guard let url = request.url,
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(),
              allowedHosts.contains(host),
              url.user == nil,
              url.password == nil else {
            completionHandler(nil)
            return
        }
        completionHandler(request)
    }
}

