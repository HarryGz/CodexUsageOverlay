import Darwin
import Foundation
import Network

public struct SocketFileAttributes {
    public let mode: mode_t
    public let ownerID: uid_t
    public let directoryMode: mode_t
    public let directoryOwnerID: uid_t

    public init(mode: mode_t, ownerID: uid_t, directoryMode: mode_t, directoryOwnerID: uid_t) {
        self.mode = mode; self.ownerID = ownerID
        self.directoryMode = directoryMode; self.directoryOwnerID = directoryOwnerID
    }
}

public enum SocketSecurityValidator {
    public static func validate(socketURL: URL, currentUserID: uid_t, attributes: SocketFileAttributes) -> Bool {
        let path = socketURL.path
        return socketURL.isFileURL && path.hasPrefix("/") && !path.utf8.contains(0)
            && path.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path)
            && attributes.mode & mode_t(S_IFMT) == mode_t(S_IFSOCK)
            && attributes.ownerID == currentUserID
            && attributes.directoryMode & mode_t(S_IFMT) == mode_t(S_IFDIR)
            && attributes.directoryOwnerID == currentUserID
            && attributes.directoryMode & 0o022 == 0
    }

    /// lstat rejects socket and immediate-parent symlinks. Never changes the filesystem.
    static func isSafe(_ url: URL, currentUserID: uid_t = getuid()) -> Bool {
        var socketInfo = stat()
        var directoryInfo = stat()
        guard lstat(url.path, &socketInfo) == 0,
              lstat(url.deletingLastPathComponent().path, &directoryInfo) == 0 else { return false }
        return validate(socketURL: url, currentUserID: currentUserID, attributes: SocketFileAttributes(
            mode: socketInfo.st_mode, ownerID: socketInfo.st_uid,
            directoryMode: directoryInfo.st_mode, directoryOwnerID: directoryInfo.st_uid))
    }
}

/// Incremental little-endian framing. Oversized JSON bodies are drained without
/// buffering; a wire length above the protocol cap terminates the connection.
struct IPCFrameDecoder {
    static let maximumWireBytes = 256 * 1024 * 1024
    static let maximumJSONBytes = 4 * 1024 * 1024
    private var header = Data()
    private var payload = Data()
    private var remaining = 0
    private var discarding = false

    mutating func append(_ data: Data) throws -> [Data] {
        var frames: [Data] = []
        var offset = data.startIndex
        while offset < data.endIndex {
            if remaining == 0 {
                let size = min(4 - header.count, data.endIndex - offset)
                header.append(data[offset..<(offset + size)])
                offset += size
                guard header.count == 4 else { break }
                let length = header.enumerated().reduce(UInt32(0)) { $0 | (UInt32($1.element) << ($1.offset * 8)) }
                header.removeAll(keepingCapacity: true)
                guard length <= Self.maximumWireBytes else { throw CodexIPCError.frameTooLarge }
                remaining = Int(length)
                discarding = remaining > Self.maximumJSONBytes
                if remaining == 0 { continue }
            }
            let size = min(remaining, data.endIndex - offset)
            if !discarding { payload.append(data[offset..<(offset + size)]) }
            remaining -= size
            offset += size
            if remaining == 0, !discarding {
                frames.append(payload)
                payload = Data()
            }
        }
        return frames
    }
}

/// Local IPC subscriber. It performs the protocol's registration handshake, then
/// only receives routing broadcasts. Install callbacks before start; callbacks
/// arrive on main. AppDelegate owns the status-to-context-monitor selection policy.
public final class CodexIPCClient {
    public var onStatus: ((ActiveThreadStatus) -> Void)?
    private let candidates: [URL]
    private let queue = DispatchQueue(label: "CodexUsageCore.CodexIPCClient")
    private let queueKey = DispatchSpecificKey<Void>()
    private var router = ActiveThreadRouter()
    private var decoder = IPCFrameDecoder()
    private var connection: NWConnection?
    private var retryWork: DispatchWorkItem?
    private var timeoutWork: DispatchWorkItem?
    private var running = false
    private var candidateIndex = 0
    private var retryAttempt = 0
    private var generation: UInt64 = 0
    private var initializeRequestID: String?
    private var initialized = false

    public init(socketCandidates: [URL] = CodexIPCClient.socketCandidates()) {
        candidates = socketCandidates
        queue.setSpecific(key: queueKey, value: ())
    }

    deinit { performSync { stopLocked(publish: false) } }

    public static func socketCandidates(environment: [String: String] = ProcessInfo.processInfo.environment,
                                        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) -> [URL] {
        var result: [URL] = []
        if let path = environment["CODEX_HOME"], path.hasPrefix("/") {
            result.append(URL(fileURLWithPath: path).appendingPathComponent("ipc/ipc.sock"))
        }
        result.append(homeDirectory.appendingPathComponent(".codex/ipc/ipc.sock"))
        if let path = environment["TMPDIR"], path.hasPrefix("/") {
            result.append(URL(fileURLWithPath: path).appendingPathComponent("codex-ipc/ipc.sock"))
        }
        result.append(URL(fileURLWithPath: "/tmp/codex-ipc/ipc.sock"))
        return result
    }

    public func start() {
        queue.async { [weak self] in
            guard let self, !self.running else { return }
            self.running = true
            self.generation &+= 1
            self.candidateIndex = 0
            self.retryAttempt = 0
            self.tryNextCandidate()
        }
    }

    public func stop() { performSync { stopLocked(publish: true) } }

    private func stopLocked(publish: Bool) {
        running = false
        generation &+= 1
        retryWork?.cancel(); retryWork = nil
        cleanupConnection()
        router.reset()
        if publish { publishStatus() }
    }

    private func tryNextCandidate() {
        guard running, connection == nil else { return }
        while candidateIndex < candidates.count {
            let candidate = candidates[candidateIndex]
            candidateIndex += 1
            guard SocketSecurityValidator.isSafe(candidate) else { continue }
            connect(candidate)
            return
        }
        // Preserve the actual connection/framing error after exhausting candidates.
        // Initial discovery with no validated endpoint has its own generic status.
        if router.status.error == nil {
            router.reset(error: .noSafeSocket)
            publishStatus()
        }
        scheduleRetry()
    }

    private func connect(_ socket: URL) {
        let next = NWConnection(to: .unix(path: socket.path), using: .tcp)
        connection = next
        decoder = IPCFrameDecoder()
        next.stateUpdateHandler = { [weak self, weak next] state in
            guard let self, let next, self.connection === next else { return }
            switch state {
            case .ready:
                self.receive(next)
                self.sendInitialize(on: next)
            case .failed, .waiting:
                self.disconnect(.connectionFailed)
            case .cancelled:
                self.disconnect(.disconnected)
            default: break
            }
        }
        let timeout = DispatchWorkItem { [weak self, weak next] in
            guard let self, let next, self.connection === next else { return }
            self.disconnect(.connectionFailed)
        }
        timeoutWork = timeout
        queue.asyncAfter(deadline: .now() + 3, execute: timeout)
        next.start(queue: queue)
    }

    private func receive(_ source: NWConnection) {
        source.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self, weak source] data, _, complete, error in
            guard let self, let source, self.connection === source else { return }
            if let data, !data.isEmpty {
                do {
                    for frame in try self.decoder.append(data) {
                        switch self.processInitializationFrame(frame) {
                        case .success:
                            self.timeoutWork?.cancel(); self.timeoutWork = nil
                            self.retryAttempt = 0
                            self.router.didConnect()
                            self.publishStatus()
                        case .failure:
                            self.disconnect(.connectionFailed)
                            return
                        case .unrelated:
                            if self.initialized, self.router.process(data: frame) { self.publishStatus() }
                        }
                    }
                } catch {
                    self.disconnect(.frameTooLarge)
                    return
                }
            }
            if complete || error != nil { self.disconnect(.disconnected) }
            else { self.receive(source) }
        }
    }

    private func sendInitialize(on target: NWConnection) {
        let requestID = UUID().uuidString
        initializeRequestID = requestID
        let object: [String: Any] = [
            "type": "request",
            "requestId": requestID,
            "sourceClientId": "initializing-client",
            "version": 0,
            "method": "initialize",
            "params": ["clientType": "codex-usage-overlay"]
        ]
        guard let json = try? JSONSerialization.data(withJSONObject: object),
              json.count <= IPCFrameDecoder.maximumJSONBytes else {
            disconnect(.connectionFailed)
            return
        }
        var length = UInt32(json.count).littleEndian
        let frame = withUnsafeBytes(of: &length) { Data($0) } + json
        target.send(content: frame, completion: .contentProcessed { [weak self, weak target] error in
            guard let self, let target, self.connection === target, error != nil else { return }
            self.disconnect(.connectionFailed)
        })
    }

    private enum InitializationFrameResult { case unrelated, success, failure }

    private func processInitializationFrame(_ data: Data) -> InitializationFrameResult {
        guard !initialized, let requestID = initializeRequestID,
              let response = try? JSONDecoder().decode(IPCInitializeResponse.self, from: data),
              response.type == "response", response.requestId == requestID else { return .unrelated }
        guard response.method == "initialize", response.resultType == "success",
              let clientID = response.result?.clientId,
              !clientID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return .failure }
        initialized = true
        initializeRequestID = nil
        return .success
    }

    private func disconnect(_ error: CodexIPCError) {
        cleanupConnection()
        router.reset(error: error)
        publishStatus()
        if running { tryNextCandidate() }
    }

    private func cleanupConnection() {
        timeoutWork?.cancel(); timeoutWork = nil
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil
        decoder = IPCFrameDecoder()
        initializeRequestID = nil
        initialized = false
    }

    private func scheduleRetry() {
        guard running else { return }
        let delays: [TimeInterval] = [1, 2, 5, 15]
        let delay = delays[min(retryAttempt, delays.count - 1)]
        retryAttempt = min(retryAttempt + 1, delays.count - 1)
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.running else { return }
            self.retryWork = nil
            self.candidateIndex = 0
            self.tryNextCandidate()
        }
        retryWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func publishStatus() {
        let status = router.status
        let callbackGeneration = generation
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            let current = self.queue.sync { self.generation == callbackGeneration }
            if current { self.onStatus?(status) }
        }
    }

    private func performSync(_ work: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { work() }
        else { queue.sync(execute: work) }
    }
}

private struct IPCInitializeResponse: Decodable {
    struct Result: Decodable { let clientId: String? }
    let type: String
    let requestId: String
    let method: String?
    let resultType: String?
    let result: Result?
}
