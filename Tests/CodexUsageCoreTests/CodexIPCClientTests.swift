import Darwin
import Network
import XCTest
@testable import CodexUsageCore

final class CodexIPCClientTests: XCTestCase {
    func testClientInitializesBeforePublishingReplayedRoute() throws {
        let server = try SyntheticIPCServer()
        let receivedInitialize = expectation(description: "initialize request received")
        server.requestHandler = { [framedFollow] frame in
            guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
                  object["type"] as? String == "request",
                  object["method"] as? String == "initialize",
                  object["sourceClientId"] as? String == "initializing-client",
                  object["version"] as? Int == 0,
                  let requestID = object["requestId"] as? String,
                  let params = object["params"] as? [String: Any],
                  params["clientType"] as? String == "codex-usage-overlay" else { return nil }
            receivedInitialize.fulfill()
            return Self.frame([
                "type": "response",
                "requestId": requestID,
                "method": "initialize",
                "resultType": "success",
                "result": ["clientId": "overlay-client"]
            ]) + framedFollow
        }

        let client = CodexIPCClient(socketCandidates: [server.socketURL])
        let selected = expectation(description: "replayed route selected")
        client.onStatus = { status in
            if status.threadID == "11111111-1111-1111-1111-111111111111" { selected.fulfill() }
        }
        client.start()
        wait(for: [receivedInitialize, selected], timeout: 3)
        client.onStatus = nil
        client.stop()
    }

    func testClientIgnoresRoutingBroadcastBeforeInitializationCompletes() throws {
        let server = try SyntheticIPCServer()
        server.preRequestPayload = framedFollow
        server.requestHandler = { frame in
            guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
                  let requestID = object["requestId"] as? String else { return nil }
            return Self.frame([
                "type": "response",
                "requestId": requestID,
                "method": "initialize",
                "resultType": "success",
                "result": ["clientId": "overlay-client"]
            ])
        }

        let client = CodexIPCClient(socketCandidates: [server.socketURL])
        let initializedWithoutRoute = expectation(description: "initialized without accepting early route")
        client.onStatus = { status in
            XCTAssertNil(status.threadID)
            if status.connected { initializedWithoutRoute.fulfill() }
        }
        client.start()
        wait(for: [initializedWithoutRoute], timeout: 3)
        client.onStatus = nil
        client.stop()
    }

    func testClientRejectsInitializeResponseWithEmptyClientID() throws {
        let server = try SyntheticIPCServer()
        server.requestHandler = { frame in
            guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
                  let requestID = object["requestId"] as? String else { return nil }
            return Self.frame([
                "type": "response",
                "requestId": requestID,
                "method": "initialize",
                "resultType": "success",
                "result": ["clientId": "  "]
            ])
        }

        let client = CodexIPCClient(socketCandidates: [server.socketURL])
        let rejected = expectation(description: "empty client ID rejected")
        var didReject = false
        client.onStatus = { status in
            XCTAssertFalse(status.connected)
            XCTAssertNil(status.threadID)
            if status.error == .connectionFailed, !didReject {
                didReject = true
                rejected.fulfill()
            }
        }
        client.start()
        wait(for: [rejected], timeout: 3)
        client.onStatus = nil
        client.stop()
    }

    func testCodecAcceptsLittleEndianSplitAndCoalescedFrames() throws {
        var codec = IPCFrameDecoder()
        XCTAssertEqual(try codec.append(Data([2, 0])), [])
        XCTAssertEqual(try codec.append(Data([0, 0, 123])), [])
        XCTAssertEqual(try codec.append(Data([125, 2, 0, 0, 0, 91, 93])), [Data("{}".utf8), Data("[]".utf8)])
    }

    func testCodecRejectsWireLengthAbove256MiBWithoutPayload() {
        var codec = IPCFrameDecoder()
        XCTAssertThrowsError(try codec.append(Data([1, 0, 0, 16]))) { error in
            XCTAssertEqual(error as? CodexIPCError, .frameTooLarge)
        }
    }

    func testCodecDiscardsOversizedJSONAndResumesAtNextFrame() throws {
        var codec = IPCFrameDecoder()
        XCTAssertEqual(try codec.append(Data([1, 0, 64, 0])), [])
        let chunk = Data(repeating: 32, count: 64 * 1024)
        for _ in 0..<64 { XCTAssertEqual(try codec.append(chunk), []) }
        XCTAssertEqual(try codec.append(Data([32, 2, 0, 0, 0, 123, 125])), [Data("{}".utf8)])
    }

    func testCodecAccepts256MiBWireHeaderWithoutBufferingPayload() throws {
        var codec = IPCFrameDecoder()
        XCTAssertEqual(try codec.append(Data([0, 0, 0, 16])), [])
        XCTAssertEqual(try codec.append(Data(repeating: 0, count: 64 * 1024)), [])
    }

    func testCodecAcceptsExactly4MiBJSON() throws {
        var codec = IPCFrameDecoder()
        let payload = Data(repeating: 32, count: 4 * 1024 * 1024)
        XCTAssertEqual(try codec.append(Data([0, 0, 64, 0]) + payload), [payload])
    }

    func testClientRejectsOversizedWireHeaderAndClearsExistingRoute() throws {
        let server = try SyntheticIPCServer()
        let client = CodexIPCClient(socketCandidates: [server.socketURL])
        let disconnected = expectation(description: "wire cap disconnect")
        client.onStatus = { status in
            if status.threadID != nil { server.send(Data([1, 0, 0, 16])) }
            if status.error == .frameTooLarge {
                XCTAssertFalse(status.connected)
                XCTAssertNil(status.threadID)
                disconnected.fulfill()
            }
        }
        server.payload = framedFollow
        client.start()
        wait(for: [disconnected], timeout: 3)
        client.onStatus = nil
        client.stop()
    }

    func testReconnectDiscardsPreviousPartialFrame() throws {
        let server = try SyntheticIPCServer()
        server.responsePlan = [(Data([100, 0, 0, 0, 123]), true), (framedFollow, false)]
        let client = CodexIPCClient(socketCandidates: [server.socketURL])
        let selected = expectation(description: "replacement frame decoded")
        var disconnectedVersion: UInt64?
        client.onStatus = { status in
            if status.error == .disconnected { disconnectedVersion = status.version }
            if status.threadID != nil {
                XCTAssertNotNil(disconnectedVersion)
                XCTAssertGreaterThan(status.version, disconnectedVersion ?? 0)
                selected.fulfill()
            }
        }
        client.start()
        wait(for: [selected], timeout: 4)
        client.onStatus = nil
        client.stop()
    }

    func testClientPublishesRouteThenClearsItOnEOF() throws {
        let server = try SyntheticIPCServer()
        let client = CodexIPCClient(socketCandidates: [server.socketURL])
        let selected = expectation(description: "route selected")
        let disconnected = expectation(description: "EOF clears route")
        var sawSelection = false
        client.onStatus = { status in
            XCTAssertTrue(Thread.isMainThread)
            if status.threadID == "11111111-1111-1111-1111-111111111111" {
                sawSelection = true
                selected.fulfill()
                server.closePeer()
            } else if sawSelection && !status.connected {
                XCTAssertNil(status.threadID)
                XCTAssertEqual(status.activeWindowCount, 0)
                disconnected.fulfill()
            }
        }
        server.payload = framedFollow
        client.start()
        wait(for: [selected, disconnected], timeout: 3)
        client.onStatus = nil
        client.stop()
    }

    func testClientSkipsRegularFileCandidateAndConnectsToNextSocket() throws {
        let server = try SyntheticIPCServer()
        let regular = server.directory.appendingPathComponent("regular")
        try Data("synthetic".utf8).write(to: regular)
        let client = CodexIPCClient(socketCandidates: [regular, server.socketURL])
        let selected = expectation(description: "valid second candidate selected")
        client.onStatus = { status in if status.threadID != nil { selected.fulfill() } }
        server.payload = framedFollow
        client.start()
        wait(for: [selected], timeout: 3)
        client.onStatus = nil
        client.stop()
        XCTAssertEqual(try Data(contentsOf: regular), Data("synthetic".utf8))
    }

    func testStopPublishesDisconnectedAndClearsSelection() throws {
        let server = try SyntheticIPCServer()
        let client = CodexIPCClient(socketCandidates: [server.socketURL])
        let selected = expectation(description: "route selected")
        let stopped = expectation(description: "stop clears route")
        var sawSelection = false
        client.onStatus = { status in
            if status.threadID != nil { sawSelection = true; selected.fulfill(); client.stop() }
            else if sawSelection && !status.connected { stopped.fulfill() }
        }
        server.payload = framedFollow
        client.start()
        wait(for: [selected, stopped], timeout: 3)
        client.onStatus = nil
    }

    private var framedFollow: Data {
        let json = Data(#"{"type":"broadcast","method":"thread-stream-following-changed","sourceClientId":"synthetic-client","params":{"conversationId":"11111111-1111-1111-1111-111111111111","hostId":"local","following":true},"ignored":{"content":"synthetic ignored content"}}"#.utf8)
        var length = UInt32(json.count).littleEndian
        return withUnsafeBytes(of: &length) { Data($0) } + json
    }

    private static func frame(_ object: [String: Any]) -> Data {
        let json = try! JSONSerialization.data(withJSONObject: object)
        var length = UInt32(json.count).littleEndian
        return withUnsafeBytes(of: &length) { Data($0) } + json
    }
}

/// All socket creation/removal here is confined to synthetic test fixtures.
private final class SyntheticIPCServer {
    let directory: URL
    let socketURL: URL
    var payload: Data {
        get { queue.sync { storedPayload } }
        set { queue.sync { storedPayload = newValue } }
    }
    var responsePlan: [(Data, Bool)] {
        get { queue.sync { storedPlan } }
        set { queue.sync { storedPlan = newValue } }
    }
    var requestHandler: ((Data) -> Data?)? {
        get { queue.sync { storedRequestHandler } }
        set { queue.sync { storedRequestHandler = newValue } }
    }
    var preRequestPayload: Data {
        get { queue.sync { storedPreRequestPayload } }
        set { queue.sync { storedPreRequestPayload = newValue } }
    }
    private var storedPayload = Data()
    private var storedPlan: [(Data, Bool)] = []
    private var storedRequestHandler: ((Data) -> Data?)?
    private var storedPreRequestPayload = Data()
    private let listener: NWListener
    private let queue = DispatchQueue(label: "SyntheticIPCServer")
    private var peer: NWConnection?

    init() throws {
        // Keep paths below sockaddr_un's limit even with a long workspace path.
        directory = URL(fileURLWithPath: "/tmp").appendingPathComponent("ipc-test-" + UUID().uuidString)
        socketURL = directory.appendingPathComponent("ipc.sock")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .unix(path: socketURL.path)
        listener = try NWListener(using: parameters)
        let ready = XCTestExpectation(description: "synthetic listener ready")
        listener.stateUpdateHandler = { state in if case .ready = state { ready.fulfill() } }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.peer = connection
            connection.start(queue: self.queue)
            if !self.storedPreRequestPayload.isEmpty {
                connection.send(content: self.storedPreRequestPayload, completion: .contentProcessed { _ in })
            }
            self.receiveRequest(from: connection)
        }
        listener.start(queue: queue)
        guard XCTWaiter.wait(for: [ready], timeout: 2) == .completed else {
            throw NSError(domain: "SyntheticIPCServer", code: 1)
        }
    }

    private func receiveRequest(from connection: NWConnection, decoder: IPCFrameDecoder = IPCFrameDecoder()) {
        var decoder = decoder
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, complete, error in
            guard let self else { return }
            if let data, !data.isEmpty, let frames = try? decoder.append(data) {
                for frame in frames {
                    guard let response = self.response(to: frame) else { continue }
                    connection.send(content: response.data, completion: .contentProcessed { _ in
                        if response.close { connection.cancel() }
                    })
                    return
                }
            }
            if !complete, error == nil { self.receiveRequest(from: connection, decoder: decoder) }
        }
    }

    private func response(to frame: Data) -> (data: Data, close: Bool)? {
        if let storedRequestHandler { return storedRequestHandler(frame).map { ($0, false) } }
        guard let object = try? JSONSerialization.jsonObject(with: frame) as? [String: Any],
              object["method"] as? String == "initialize",
              let requestID = object["requestId"] as? String else { return nil }
        let initialize = Self.frame([
            "type": "response",
            "requestId": requestID,
            "method": "initialize",
            "resultType": "success",
            "result": ["clientId": "synthetic-overlay-client"]
        ])
        let planned = storedPlan.isEmpty ? (storedPayload, false) : storedPlan.removeFirst()
        return (initialize + planned.0, planned.1)
    }

    private static func frame(_ object: [String: Any]) -> Data {
        let json = try! JSONSerialization.data(withJSONObject: object)
        var length = UInt32(json.count).littleEndian
        return withUnsafeBytes(of: &length) { Data($0) } + json
    }

    func closePeer() { queue.async { self.peer?.cancel(); self.peer = nil } }

    func send(_ data: Data) {
        queue.async { self.peer?.send(content: data, completion: .contentProcessed { _ in }) }
    }

    deinit {
        listener.cancel()
        peer?.cancel()
        try? FileManager.default.removeItem(at: directory)
    }
}
