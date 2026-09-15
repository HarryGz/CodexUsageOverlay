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
    private var selection: (threadID: String, provenance: SnapshotProvenance)?
    private var session: VerifiedSession?
    private var source: DispatchSourceFileSystemObject?
    private var debounceWork: DispatchWorkItem?
    private var generation: UInt64 = 0

    public init(codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"), now: @escaping () -> Date = Date.init, workerQueue: DispatchQueue? = nil) {
        self.codexHome = codexHome; self.now = now
        self.queue = workerQueue ?? DispatchQueue(label: "CodexUsageCore.ContextLogMonitor")
        queue.setSpecific(key: queueKey, value: ())
    }
    deinit { performSync { invalidateAndStopLocked() } }

    public func select(threadID: String, provenance: SnapshotProvenance) {
        performSync { invalidateAndStopLocked(); selection = (threadID, provenance); resolveSelectedLocked() }
    }
    public func selectFallbackRootSession(provenance: SnapshotProvenance) {
        performSync {
            invalidateAndStopLocked()
            do {
                let fallback = try SessionPathResolver.openFallback(codexHome: codexHome)
                selection = (fallback.threadID, provenance); session = fallback.session
                startWatchingLocked(); refreshLocked()
            } catch { selection = nil; report(error, generation: generation) }
        }
    }
    public func start() { queue.async { [weak self] in self?.resolveOrRefreshLocked() } }
    public func stop() { performSync { invalidateAndStopLocked() } }
    public func refreshNow() { queue.async { [self] in refreshLocked() } }

    private func resolveOrRefreshLocked() { if session == nil { resolveSelectedLocked() } else { startWatchingLocked(); refreshLocked() } }
    private func resolveSelectedLocked() {
        guard let selection else { return }
        do { session = try SessionPathResolver.openVerified(threadID: selection.threadID, codexHome: codexHome); startWatchingLocked(); refreshLocked() }
        catch { session = nil; report(error, generation: generation) }
    }
    private func startWatchingLocked() {
        guard source == nil, let session else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: session.fileDescriptor, eventMask: [.write, .rename, .delete], queue: queue)
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
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
        guard let session, let selection else { return }
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
        } catch { report(ContextLogMonitorError.unavailable("The selected context log cannot be read."), generation: callbackGeneration) }
    }
    private func invalidateAndStopLocked() {
        generation &+= 1
        debounceWork?.cancel(); debounceWork = nil
        let sourceToCancel = source
        source = nil
        if let sourceToCancel { sourceToCancel.cancel() } else { session?.close() }
        session = nil
    }
    private func report(_ error: Error, generation: UInt64) {
        DispatchQueue.main.async { [weak self] in guard let self, self.isCurrent(generation) else { return }; self.onError?(error) }
    }
    private func isCurrent(_ candidate: UInt64) -> Bool {
        if DispatchQueue.getSpecific(key: queueKey) != nil { return generation == candidate }
        return queue.sync { generation == candidate }
    }
    private func performSync(_ action: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil { action() } else { queue.sync(execute: action) }
    }
}
