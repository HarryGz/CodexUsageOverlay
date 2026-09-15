import CoreFoundation
import Foundation

public enum CodexIPCError: Error, LocalizedError, Equatable {
    case noSafeSocket, connectionFailed, disconnected, frameTooLarge

    public var errorDescription: String? {
        switch self {
        case .noSafeSocket: return "No safe local Codex IPC socket is available."
        case .connectionFailed: return "The local Codex IPC connection failed."
        case .disconnected: return "The local Codex IPC connection closed."
        case .frameTooLarge: return "The local Codex IPC frame exceeds the allowed size."
        }
    }
}

public struct ActiveThreadStatus: Equatable {
    public let threadID: String?
    public let activeWindowCount: Int
    public let connected: Bool
    public let version: UInt64
    public let error: CodexIPCError?
}

/// Pure routing state. A route belongs to one source client and host (app window).
/// No message content is retained. The last selection survives follow/unfollow transitions.
public struct ActiveThreadRouter {
    private struct Route { let threadID: String; let order: UInt64 }
    private var routes: [String: Route] = [:]
    private var order: UInt64 = 0
    public private(set) var status = ActiveThreadStatus(threadID: nil, activeWindowCount: 0, connected: false, version: 0, error: nil)

    public init() {}

    @discardableResult
    public mutating func process(frame: [String: Any]) -> Bool {
        guard frame["type"] as? String == "broadcast",
              let method = frame["method"] as? String,
              let params = frame["params"] as? [String: Any] else { return false }
        var preserveLastSelection = true
        switch method {
        case "thread-stream-following-changed":
            guard let client = identifier(frame["sourceClientId"]),
                  let host = identifier(params["hostId"]),
                  let thread = identifier(params["conversationId"]),
                  let number = params["following"] as? NSNumber,
                  CFGetTypeID(number) == CFBooleanGetTypeID() else { return false }
            let window = client + "\u{001F}" + host
            if number.boolValue {
                order &+= 1
                routes[window] = Route(threadID: thread, order: order)
            } else {
                guard let route = routes[window], route.threadID.caseInsensitiveCompare(thread) == .orderedSame else { return false }
                routes.removeValue(forKey: window)
            }
        case "client-status-changed":
            guard params["status"] as? String == "disconnected",
                  let client = identifier(params["clientId"]) else { return false }
            let remaining = routes.filter { !$0.key.hasPrefix(client + "\u{001F}") }
            guard remaining.count != routes.count || (routes.isEmpty && status.threadID != nil) else { return false }
            routes = remaining
            preserveLastSelection = false
        default: return false
        }
        let selected = routes.values.max { $0.order < $1.order }?.threadID
            ?? (preserveLastSelection ? status.threadID : nil)
        status = ActiveThreadStatus(threadID: selected, activeWindowCount: routes.count, connected: true, version: status.version &+ 1, error: nil)
        return true
    }

    public mutating func reset(error: CodexIPCError? = nil) {
        routes.removeAll()
        order = 0
        status = ActiveThreadStatus(threadID: nil, activeWindowCount: 0, connected: false, version: status.version &+ 1, error: error)
    }

    mutating func didConnect() {
        status = ActiveThreadStatus(threadID: status.threadID, activeWindowCount: routes.count, connected: true, version: status.version &+ 1, error: nil)
    }

    /// Decode only the routing schema; unrelated content has no model or callback.
    mutating func process(data: Data) -> Bool {
        guard data.count <= IPCFrameDecoder.maximumJSONBytes, isUTF8JSON(data),
              let frame = try? JSONDecoder().decode(RoutingFrame.self, from: data) else { return false }
        var params: [String: Any] = [:]
        params["conversationId"] = frame.params?.conversationId
        params["hostId"] = frame.params?.hostId
        params["following"] = frame.params?.following
        params["clientId"] = frame.params?.clientId
        params["status"] = frame.params?.status
        var metadata: [String: Any] = ["type": frame.type, "method": frame.method, "params": params]
        metadata["sourceClientId"] = frame.sourceClientId
        return process(frame: metadata)
    }

    private func identifier(_ value: Any?) -> String? {
        guard let value = value as? String, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private func isUTF8JSON(_ data: Data) -> Bool {
        // JSONDecoder also accepts UTF-16/32. Reject their zero-byte syntax and
        // validate UTF-8 without constructing strings from ignored content.
        var iterator = data.makeIterator()
        var decoder = Unicode.UTF8()
        while true {
            switch decoder.decode(&iterator) {
            case .emptyInput: return true
            case .error: return false
            case let .scalarValue(scalar): if scalar.value == 0 { return false }
            }
        }
    }
}

private struct RoutingFrame: Decodable {
    let type: String
    let method: String
    let sourceClientId: String?
    let params: RoutingParams?
}

private struct RoutingParams: Decodable {
    let conversationId: String?
    let hostId: String?
    let following: Bool?
    let clientId: String?
    let status: String?
}
