import Dispatch
import Foundation

public enum ContextLogMonitorError: Error, LocalizedError, Equatable {
    case unavailable(String), staleSnapshot
    public var errorDescription: String? {
        switch self {
        case let .unavailable(reason): return reason
        case .staleSnapshot: return "The latest context token event is older than five minutes."
        }
    }
}

/// Watches one descriptor-bound rollout at a time. Callbacks always arrive on main.
/// A stale value is sent through `onSnapshot` before the generic stale `onError`.
public final class ContextLogMonitor {
    public var onSnapshot: ((ContextUsageSnapshot) -> Void)?
    public var onError: ((Error) -> Void)?

    private let codexHome: URL
    private let now: () -> Date
    private let queue: DispatchQueue
    private let queueKey = DispatchSpecificKey<Void>()
    private enum Target: Equatable {
        case thread(String, SnapshotProvenance)
        case fallback(SnapshotProvenance)
    }
    private var target: Target?
    private var enabled = false
    private var selection: (threadID: String, provenance: SnapshotProvenance)?
    private var session: VerifiedSession?
    private var source: DispatchSourceFileSystemObject?
    private var debounceWork: DispatchWorkItem?
    private var discoveryWork: DispatchWorkItem?
    private var discoveryAttempt = 0
    private var generation: UInt64 = 0

    public init(codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"), now: @escaping () -> Date = Date.init, workerQueue: DispatchQueue? = nil) {
        self.codexHome = codexHome; self.now = now
        self.queue = workerQueue ?? DispatchQueue(label: "CodexUsageCore.ContextLogMonitor")
        queue.setSpecific(key: queueKey, value: ())
    }
    deinit { performSync { invalidateAndStopLocked() } }

    public func select(threadID: String, provenance: SnapshotProvenance) {
        performSync { selectLocked(.thread(threadID, provenance)) }
    }
    public func selectFallbackRootSession(provenance: SnapshotProvenance) {
        performSync { selectLocked(.fallback(provenance)) }
    }
    /// Foreground visibility owns monitoring; selection alone never opens a file.
    public func start() {
        performSync {
            guard !enabled else { return }
            enabled = true
            discoveryAttempt = 0
            resolveSelectedLocked()
        }
    }
    public func stop() { performSync { enabled = false; invalidateAndStopLocked() } }
    public func refreshNow() {
        queue.async { [self] in
            guard enabled else { return }
            invalidateAndStopLocked()
            discoveryAttempt = 0
            resolveSelectedLocked()
        }
    }

    private func selectLocked(_ next: Target) {
        guard target != next else { return }
        let hadSelection = selection != nil
        invalidateAndStopLocked()
        target = next
        selection = nil
        discoveryAttempt = 0
        guard enabled else { return }
        if hadSelection { report(ContextLogMonitorError.unavailable("正在读取任务用量"), generation: generation) }
        resolveSelectedLocked()
    }
    private func resolveSelectedLocked() {
        guard enabled, let target else { return }
        do {
            let next: (threadID: String, provenance: SnapshotProvenance)
            switch target {
            case let .thread(threadID, provenance):
                session = try SessionPathResolver.openVerified(threadID: threadID, codexHome: codexHome)
                next = (threadID, provenance)
            case .fallback(let provenance):
                let fallback = try SessionPathResolver.openFallback(codexHome: codexHome)
                session = fallback.session
                next = (fallback.threadID, provenance)
            }
            if let selection, selection.threadID != next.threadID || selection.provenance != next.provenance {
                report(ContextLogMonitorError.unavailable("正在读取任务用量"), generation: generation)
            }
            selection = next
            discoveryWork?.cancel(); discoveryWork = nil
            discoveryAttempt = 0
            startWatchingLocked()
            refreshLocked()
        } catch {
            session = nil
            report(error, generation: generation)
            scheduleDiscoveryLocked()
        }
    }
    private func scheduleDiscoveryLocked() {
        guard enabled, target != nil, session == nil, discoveryWork == nil else { return }
        let delays: [TimeInterval] = [1, 2, 5, 15]
        let delay = delays[min(discoveryAttempt, delays.count - 1)]
        discoveryAttempt += 1
        let expectedGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.enabled, self.generation == expectedGeneration else { return }
            self.discoveryWork = nil
            self.resolveSelectedLocked()
        }
        discoveryWork = work
        queue.asyncAfter(deadline: .now() + delay, execute: work)
    }
    private func startWatchingLocked() {
        guard enabled, source == nil, let session else { return }
        let expectedGeneration = generation
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: session.fileDescriptor, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source, self.enabled, self.generation == expectedGeneration else { return }
            if source.data.contains(.rename) || source.data.contains(.delete) {
                self.invalidateAndStopLocked(); self.resolveSelectedLocked()
            } else { self.scheduleRefreshLocked() }
        }
        // The dispatch source owns final descriptor shutdown; all direct readers use
        // this same descriptor and cannot reopen a replaced pathname.
        source.setCancelHandler { session.close() }
        self.source = source; source.resume()
    }
    private func scheduleRefreshLocked() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshLocked() }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
    }
    private func refreshLocked() {
        guard enabled, let session, let selection else { return }
        let callbackGeneration = generation
        do {
            let tail = try session.readTail()
            guard let snapshot = ContextLogParser.parseLatest(data: tail.data, threadID: selection.threadID, updatedAt: tail.modificationDate, provenance: selection.provenance, leadingRecordMayBePartial: tail.leadingRecordMayBePartial) else {
                report(ContextLogMonitorError.unavailable("No complete context token event is available."), generation: callbackGeneration); return
            }
            let stale = now().timeIntervalSince(snapshot.updatedAt) > 300
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrent(callbackGeneration) else { return }
                self.onSnapshot?(snapshot)
                if stale, self.isCurrent(callbackGeneration) { self.onError?(ContextLogMonitorError.staleSnapshot) }
            }
        } catch { report(error, generation: callbackGeneration) }
    }
    private func invalidateAndStopLocked() {
        generation &+= 1
        debounceWork?.cancel(); debounceWork = nil
        discoveryWork?.cancel(); discoveryWork = nil
        let sourceToCancel = source
        source = nil
        if let sourceToCancel { sourceToCancel.cancel() } else { session?.close() }
        session = nil
    }
    private func report(_ error: Error, generation: UInt64) {
        DispatchQueue.main.async { [weak self] in guard let self, self.isCurrent(generation) else { return }; self.onError?(error) }
    }
    private func isCurrent(_ candidate: UInt64) -> Bool {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return enabled && generation == candidate }
        return queue.sync { enabled && generation == candidate }
    }
    private func performSync(_ action: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { action() } else { queue.sync(execute: action) }
    }
}
