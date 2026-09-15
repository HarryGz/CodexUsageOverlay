import Darwin
import Dispatch
import Foundation

public enum ContextLogMonitorError: Error, LocalizedError, Equatable {
    case unavailable(String)
    case staleSnapshot

    public var errorDescription: String? {
        switch self {
        case let .unavailable(reason): return reason
        case .staleSnapshot: return "The latest context token event is older than five minutes."
        }
    }
}

/// Watches one rollout file at a time. Callbacks always arrive on the main queue.
/// A stale snapshot is delivered first through `onSnapshot`, then `.staleSnapshot` is
/// delivered through `onError`; the snapshot model intentionally has no stale flag.
public final class ContextLogMonitor {
    public var onSnapshot: ((ContextUsageSnapshot) -> Void)?
    public var onError: ((Error) -> Void)?

    private let codexHome: URL
    private let now: () -> Date
    private let queue = DispatchQueue(label: "CodexUsageCore.ContextLogMonitor")
    private var selection: (threadID: String, provenance: SnapshotProvenance)?
    private var selectedURL: URL?
    private var source: DispatchSourceFileSystemObject?
    private var debounceWork: DispatchWorkItem?

    public init(codexHome: URL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex"), now: @escaping () -> Date = Date.init) {
        self.codexHome = codexHome
        self.now = now
    }

    deinit { stop() }

    public func select(threadID: String, provenance: SnapshotProvenance) {
        queue.sync {
            selection = (threadID, provenance)
            stopLocked()
            resolveSelectedLocked()
        }
    }

    public func selectFallbackRootSession(provenance: SnapshotProvenance) {
        queue.sync {
            stopLocked()
            do {
                let fallback = try SessionPathResolver.resolveFallback(codexHome: codexHome)
                selection = (fallback.threadID, provenance)
                selectedURL = fallback.url
                startWatchingLocked()
                refreshLocked()
            } catch {
                selection = nil
                report(error)
            }
        }
    }

    public func start() {
        queue.async { [weak self] in
            guard let self else { return }
            if self.selectedURL == nil { self.resolveSelectedLocked() } else { self.startWatchingLocked(); self.refreshLocked() }
        }
    }

    public func stop() {
        queue.sync { stopLocked() }
    }

    public func refreshNow() {
        queue.async { [weak self] in self?.refreshLocked() }
    }

    private func resolveSelectedLocked() {
        guard let selection else { return }
        do {
            selectedURL = try SessionPathResolver.resolve(threadID: selection.threadID, codexHome: codexHome)
            startWatchingLocked()
            refreshLocked()
        } catch {
            selectedURL = nil
            report(error)
        }
    }

    private func startWatchingLocked() {
        guard source == nil, let selectedURL else { return }
        let descriptor = open(selectedURL.path, O_EVTONLY)
        guard descriptor >= 0 else {
            report(ContextLogMonitorError.unavailable("The selected context log cannot be watched."))
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete],
            queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self, let source else { return }
            let events = source.data
            if events.contains(.rename) || events.contains(.delete) {
                self.stopLocked()
                self.resolveSelectedLocked()
            } else {
                self.scheduleRefreshLocked()
            }
        }
        source.setCancelHandler { close(descriptor) }
        self.source = source
        source.resume()
    }

    private func scheduleRefreshLocked() {
        debounceWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.refreshLocked() }
        debounceWork = work
        queue.asyncAfter(deadline: .now() + .milliseconds(100), execute: work)
    }

    private func refreshLocked() {
        guard let selectedURL, let selection else { return }
        do {
            let data = try readTail(from: selectedURL)
            let values = try selectedURL.resourceValues(forKeys: [.contentModificationDateKey])
            guard let snapshot = ContextLogParser.parseLatest(
                data: data,
                threadID: selection.threadID,
                updatedAt: values.contentModificationDate ?? now(),
                provenance: selection.provenance
            ) else {
                report(ContextLogMonitorError.unavailable("No complete context token event is available."))
                return
            }
            let stale = now().timeIntervalSince(snapshot.updatedAt) > 300
            DispatchQueue.main.async { [weak self] in
                self?.onSnapshot?(snapshot)
                if stale { self?.onError?(ContextLogMonitorError.staleSnapshot) }
            }
        } catch {
            report(ContextLogMonitorError.unavailable("The selected context log cannot be read."))
        }
    }

    private func readTail(from url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let offset = size > UInt64(ContextLogParser.maximumTailBytes) ? size - UInt64(ContextLogParser.maximumTailBytes) : 0
        try handle.seek(toOffset: offset)
        return try handle.readToEnd() ?? Data()
    }

    private func stopLocked() {
        debounceWork?.cancel()
        debounceWork = nil
        source?.cancel()
        source = nil
    }

    private func report(_ error: Error) {
        DispatchQueue.main.async { [weak self] in self?.onError?(error) }
    }
}
