import Foundation
import Darwin

public enum AppServerClientError: Error, Equatable {
    case executableNotFound
    case launchFailed
    case requestEncodingFailed
    case transportFailed
    case initializationFailed
    case requestFailed
}

/// Reads account quota data from a local Codex App Server process.
public final class AppServerClient {
    static let initializationRequest: [String: Any] = [
        "id": 1,
        "method": "initialize",
        "params": [
            "clientInfo": ["name": "codex-usage-overlay", "version": "0.1.0"],
            "capabilities": ["experimentalApi": true]
        ]
    ]

    static let postInitializationRequests: [[String: Any]] = [
        ["method": "initialized"],
        ["id": 2, "method": "account/read", "params": ["refreshToken": false]],
        ["id": 3, "method": "account/rateLimits/read", "params": NSNull()]
    ]

    public var onSnapshot: ((AccountUsageSnapshot) -> Void)?
    public var onError: ((AppServerClientError) -> Void)?

    private let queue = DispatchQueue(label: "local.codex-usage-overlay.app-server")
    private let queueSpecificKey = DispatchSpecificKey<UInt8>()
    private let binaryResolver: () -> String?
    private let refreshInterval: TimeInterval
    private var codec = JSONRPCLineCodec()
    private var process: Process?
    private var input: FileHandle?
    private var output: FileHandle?
    private var refreshTimer: DispatchSourceTimer?
    private var restartWorkItem: DispatchWorkItem?
    private var wantsToRun = false
    private var foregroundActive = false
    private var initialized = false
    private var restartAttempt = 0
    private var latestSnapshot: AccountUsageSnapshot?

    public convenience init(binaryResolver: @escaping () -> String? = { CodexBinaryLocator.resolve() }) {
        self.init(binaryResolver: binaryResolver, refreshInterval: 180)
    }

    init(binaryResolver: @escaping () -> String?, refreshInterval: TimeInterval) {
        self.binaryResolver = binaryResolver
        self.refreshInterval = refreshInterval
        queue.setSpecific(key: queueSpecificKey, value: 1)
    }

    deinit {
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            stopLocked()
        } else {
            queue.sync { stopLocked() }
        }
    }

    public func start() {
        queue.async {
            guard !self.wantsToRun else { return }
            self.wantsToRun = true
            self.launch()
        }
    }

    public func stop() {
        // Application termination cannot leave cleanup waiting on a queued block.
        if DispatchQueue.getSpecific(key: queueSpecificKey) != nil {
            stopLocked()
        } else {
            queue.sync { stopLocked() }
        }
    }

    public func setForegroundActive(_ active: Bool) {
        queue.async {
            self.foregroundActive = active
            self.configureRefreshTimer()
        }
    }

    public func refreshNow() {
        queue.async {
            guard self.initialized else { return }
            self.sendReadOnlyAccountRequests()
        }
    }

    private func stopLocked() {
        wantsToRun = false
        initialized = false
        restartWorkItem?.cancel()
        restartWorkItem = nil
        cancelRefreshTimer()
        cleanupProcess(terminating: true)
        codec = JSONRPCLineCodec()
    }

    private func launch() {
        guard wantsToRun, process == nil else { return }
        guard let executable = binaryResolver() else {
            wantsToRun = false
            publishError(.executableNotFound)
            return
        }

        let nextProcess = Process()
        let inputPipe = Pipe()
        let outputPipe = Pipe()
        nextProcess.executableURL = URL(fileURLWithPath: executable)
        nextProcess.arguments = ["app-server", "--listen", "stdio://"]
        nextProcess.standardInput = inputPipe
        nextProcess.standardOutput = outputPipe
        nextProcess.standardError = FileHandle.nullDevice
        nextProcess.terminationHandler = { [weak self, weak nextProcess] _ in
            guard let self, let nextProcess else { return }
            self.queue.async {
                self.processDidTerminate(nextProcess)
            }
        }

        do {
            try nextProcess.run()
        } catch {
            nextProcess.terminationHandler = nil
            publishError(.launchFailed)
            scheduleRestart()
            return
        }

        process = nextProcess
        input = inputPipe.fileHandleForWriting
        output = outputPipe.fileHandleForReading
        if let input {
            _ = fcntl(input.fileDescriptor, F_SETNOSIGPIPE, 1)
        }
        codec = JSONRPCLineCodec()
        let readableOutput = outputPipe.fileHandleForReading
        readableOutput.readabilityHandler = { [weak self, weak readableOutput] handle in
            let data = handle.availableData
            guard !data.isEmpty, let self, let readableOutput else { return }
            self.queue.async {
                guard self.output === readableOutput else { return }
                self.consume(data)
            }
        }
        send(Self.initializationRequest)
    }

    private func processDidTerminate(_ terminatedProcess: Process) {
        guard let current = process, current === terminatedProcess else { return }
        initialized = false
        cancelRefreshTimer()
        cleanupProcess(terminating: false)
        guard wantsToRun else { return }
        publishError(.launchFailed)
        scheduleRestart()
    }

    private func consume(_ data: Data) {
        for message in codec.append(data) {
            if message["error"] != nil {
                publishError((message["id"] as? Int) == 1 ? .initializationFailed : .requestFailed)
                continue
            }
            if (message["id"] as? Int) == 1, message["result"] != nil, !initialized {
                initialized = true
                restartAttempt = 0
                sendPostInitializationRequests()
                configureRefreshTimer()
                continue
            }
            if let snapshot = AccountUsageParser.parse(message: message, mergingWith: latestSnapshot) {
                latestSnapshot = snapshot
                publishSnapshot(snapshot)
            }
        }
    }

    private func sendPostInitializationRequests() {
        for request in Self.postInitializationRequests {
            send(request)
        }
    }

    private func sendReadOnlyAccountRequests() {
        for request in Self.postInitializationRequests.dropFirst() {
            send(request)
        }
    }

    private func send(_ request: [String: Any]) {
        guard let input else { return }
        let data: Data
        do {
            data = try codec.encode(request)
        } catch {
            publishError(.requestEncodingFailed)
            return
        }
        do {
            try input.write(contentsOf: data)
        } catch {
            handleTransportFailure()
        }
    }

    private func handleTransportFailure() {
        guard wantsToRun else { return }
        initialized = false
        cancelRefreshTimer()
        cleanupProcess(terminating: true)
        publishError(.transportFailed)
        scheduleRestart()
    }

    private func configureRefreshTimer() {
        guard foregroundActive, initialized, refreshTimer == nil else {
            if !foregroundActive || !initialized { cancelRefreshTimer() }
            return
        }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + refreshInterval, repeating: refreshInterval)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            guard self.foregroundActive, self.initialized else {
                self.cancelRefreshTimer()
                return
            }
            self.sendReadOnlyAccountRequests()
        }
        refreshTimer = timer
        timer.resume()
    }

    private func cancelRefreshTimer() {
        refreshTimer?.setEventHandler {}
        refreshTimer?.cancel()
        refreshTimer = nil
    }

    private func scheduleRestart() {
        guard wantsToRun else { return }
        restartWorkItem?.cancel()
        let delays: [TimeInterval] = [1, 2, 5, 15]
        let delay = delays[min(restartAttempt, delays.count - 1)]
        restartAttempt += 1
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.wantsToRun else { return }
            self.restartWorkItem = nil
            self.launch()
        }
        restartWorkItem = workItem
        queue.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cleanupProcess(terminating: Bool) {
        codec = JSONRPCLineCodec()
        output?.readabilityHandler = nil
        input?.closeFile()
        output?.closeFile()
        input = nil
        output = nil
        guard let process else { return }
        process.terminationHandler = nil
        if terminating, process.isRunning {
            process.terminate()
            let deadline = ProcessInfo.processInfo.systemUptime + 0.5
            while process.isRunning, ProcessInfo.processInfo.systemUptime < deadline {
                Thread.sleep(forTimeInterval: 0.01)
            }
            // Escalate only for the exact Process instance owned by this client.
            if process.isRunning { _ = kill(process.processIdentifier, SIGKILL) }
            process.waitUntilExit()
        }
        self.process = nil
    }

    private func publishSnapshot(_ snapshot: AccountUsageSnapshot) {
        let callback = onSnapshot
        DispatchQueue.main.async {
            callback?(snapshot)
        }
    }

    private func publishError(_ error: AppServerClientError) {
        let callback = onError
        DispatchQueue.main.async {
            callback?(error)
        }
    }
}
