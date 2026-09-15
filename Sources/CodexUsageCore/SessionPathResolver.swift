import Darwin
import Foundation

/// Locates rollout logs without following paths outside the supplied Codex home.
public enum SessionPathResolver {
    public enum ResolverError: Error, LocalizedError, Equatable {
        case unavailable, invalidThreadID
        public var errorDescription: String? {
            switch self {
            case .unavailable: return "No compatible Codex session log is available."
            case .invalidThreadID: return "The selected task identifier is invalid."
            }
        }
    }

    private static let maximumCandidates = 128
    private static let metadataReadLimit = 64 * 1024

    public static func resolve(threadID: String, codexHome: URL) throws -> URL {
        guard let identifier = canonicalUUID(threadID) else { throw ResolverError.invalidThreadID }
        guard let candidate = preferred(discover(codexHome: codexHome, requiredThreadID: identifier)) else { throw ResolverError.unavailable }
        return candidate.url
    }

    /// Finds a recent valid session for explicitly labeled fallback use only.
    public static func resolveFallback(codexHome: URL) throws -> (threadID: String, url: URL) {
        guard let candidate = preferred(discover(codexHome: codexHome, requiredThreadID: nil)) else { throw ResolverError.unavailable }
        return (candidate.threadID, candidate.url)
    }

    /// Opens the chosen rollout through no-symlink directory components. The returned
    /// descriptor remains bound to the verified object even if its pathname changes.
    static func openVerified(threadID: String, codexHome: URL) throws -> VerifiedSession {
        guard let identifier = canonicalUUID(threadID) else { throw ResolverError.invalidThreadID }
        for candidate in ordered(discover(codexHome: codexHome, requiredThreadID: identifier)) {
            if let descriptor = securelyOpen(home: codexHome, components: candidate.components) {
                return VerifiedSession(url: candidate.url, fileDescriptor: descriptor)
            }
        }
        throw ResolverError.unavailable
    }

    static func openFallback(codexHome: URL) throws -> (threadID: String, session: VerifiedSession) {
        for candidate in ordered(discover(codexHome: codexHome, requiredThreadID: nil)) {
            if let descriptor = securelyOpen(home: codexHome, components: candidate.components) {
                return (candidate.threadID, VerifiedSession(url: candidate.url, fileDescriptor: descriptor))
            }
        }
        throw ResolverError.unavailable
    }

    private struct Candidate {
        let threadID: String
        let url: URL
        let components: [String]
        let modificationDate: Date
        let hasSessionMetadata: Bool
    }

    private static func discover(codexHome: URL, requiredThreadID: String?) -> [Candidate] {
        let manager = FileManager.default
        let home = codexHome.standardizedFileURL
        guard manager.fileExists(atPath: home.path) else { return [] }
        var candidates: [Candidate] = []
        for root in ["sessions", "archived_sessions"] where candidates.count < maximumCandidates {
            let directory = home.appendingPathComponent(root, isDirectory: true)
            guard isContained(directory.resolvingSymlinksInPath(), by: home.resolvingSymlinksInPath()),
                  let enumerator = manager.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey], options: [.skipsHiddenFiles]) else { continue }
            for case let found as URL in enumerator {
                guard candidates.count < maximumCandidates else { break }
                let resolved = found.standardizedFileURL.resolvingSymlinksInPath()
                guard isContained(resolved, by: home.resolvingSymlinksInPath()), isRollout(found),
                      let identifier = threadID(in: found.lastPathComponent),
                      requiredThreadID == nil || requiredThreadID == identifier,
                      let relative = relativeComponents(of: found.standardizedFileURL, below: home),
                      let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]), values.isRegularFile == true else { continue }
                candidates.append(Candidate(threadID: identifier, url: found.standardizedFileURL, components: relative,
                    modificationDate: values.contentModificationDate ?? .distantPast,
                    hasSessionMetadata: hasMatchingSessionMetadata(home: home, components: relative, threadID: identifier)))
            }
        }
        return candidates
    }

    private static func preferred(_ candidates: [Candidate]) -> Candidate? { ordered(candidates).first }
    private static func ordered(_ candidates: [Candidate]) -> [Candidate] {
        let metadata = candidates.filter(\.hasSessionMetadata)
        return (metadata.isEmpty ? candidates : metadata).sorted {
            if $0.modificationDate != $1.modificationDate { return $0.modificationDate > $1.modificationDate }
            return $0.url.path > $1.url.path
        }
    }

    private static func isRollout(_ url: URL) -> Bool { url.lastPathComponent.hasPrefix("rollout-") && url.pathExtension == "jsonl" }
    private static func threadID(in filename: String) -> String? {
        let pattern = "[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}"
        guard let range = filename.range(of: pattern, options: .regularExpression) else { return nil }
        return canonicalUUID(String(filename[range]))
    }
    private static func canonicalUUID(_ value: String) -> String? {
        guard let identifier = UUID(uuidString: value), identifier.uuidString.lowercased() == value.lowercased() else { return nil }
        return identifier.uuidString.lowercased()
    }
    private static func isContained(_ child: URL, by parent: URL) -> Bool {
        let childPath = child.standardizedFileURL.path, parentPath = parent.standardizedFileURL.path
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }
    private static func relativeComponents(of url: URL, below home: URL) -> [String]? {
        let prefix = home.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(prefix) else { return nil }
        let components = String(url.standardizedFileURL.path.dropFirst(prefix.count)).split(separator: "/").map(String.init)
        return components.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." } ? components : nil
    }

    /// Opens every component with O_NOFOLLOW, preventing pathname replacement from
    /// redirecting metadata reads, tail reads, or the watcher outside CODEX_HOME.
    private static func securelyOpen(home: URL, components: [String]) -> Int32? {
        guard !components.isEmpty else { return nil }
        var current = open(home.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard current >= 0 else { return nil }
        for component in components.dropLast() {
            let next = openat(current, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
            close(current)
            current = next
            guard current >= 0 else { return nil }
        }
        let result = openat(current, components.last!, O_RDONLY | O_NOFOLLOW)
        close(current)
        guard result >= 0 else { return nil }
        var status = stat()
        guard fstat(result, &status) == 0, (status.st_mode & S_IFMT) == S_IFREG else { close(result); return nil }
        return result
    }

    private static func hasMatchingSessionMetadata(home: URL, components: [String], threadID: String) -> Bool {
        guard let descriptor = securelyOpen(home: home, components: components) else { return false }
        defer { close(descriptor) }
        var bytes = [UInt8](repeating: 0, count: metadataReadLimit)
        let count = pread(descriptor, &bytes, bytes.count, 0)
        guard count > 0 else { return false }
        bytes.removeLast(bytes.count - Int(count))
        return bytes.split(separator: 0x0A).contains { StructuralJSONLine.sessionMetadataMatches(Array($0), threadID: threadID) }
    }
}

final class VerifiedSession {
    let url: URL
    private var descriptor: Int32
    init(url: URL, fileDescriptor: Int32) { self.url = url; self.descriptor = fileDescriptor }
    deinit { close() }
    func readTail() throws -> ContextLogTail {
        guard descriptor >= 0 else { throw SessionPathResolver.ResolverError.unavailable }
        let size = try ContextLogTailReader.capturedSize(of: descriptor)
        return try ContextLogTailReader.read(fileDescriptor: descriptor, capturedSize: size)
    }
    var fileDescriptor: Int32 { descriptor }
    func close() { if descriptor >= 0 { Darwin.close(descriptor); descriptor = -1 } }
}

struct ContextLogTail { let data: Data; let leadingRecordMayBePartial: Bool; let modificationDate: Date? }

struct ContextLogTailReader {
    static func capturedSize(of descriptor: Int32) throws -> UInt64 {
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_size >= 0 else { throw SessionPathResolver.ResolverError.unavailable }
        return UInt64(status.st_size)
    }
    static func read(fileDescriptor descriptor: Int32, capturedSize: UInt64) throws -> ContextLogTail {
        let count = Int(min(capturedSize, UInt64(ContextLogParser.maximumTailBytes)))
        let offset = capturedSize - UInt64(count)
        var bytes = [UInt8](repeating: 0, count: count)
        var readCount = 0
        while readCount < count {
            let result = bytes.withUnsafeMutableBytes { pread(descriptor, $0.baseAddress!.advanced(by: readCount), count - readCount, off_t(offset + UInt64(readCount))) }
            if result < 0 { throw SessionPathResolver.ResolverError.unavailable }
            if result == 0 { break }
            readCount += result
        }
        bytes.removeLast(count - readCount)
        var status = stat(); let date: Date? = fstat(descriptor, &status) == 0 ? Date(timeIntervalSince1970: TimeInterval(status.st_mtimespec.tv_sec)) : nil
        return ContextLogTail(data: Data(bytes), leadingRecordMayBePartial: offset > 0, modificationDate: date)
    }
}
