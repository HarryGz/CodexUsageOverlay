import Foundation

/// Locates rollout logs without following paths outside the supplied Codex home.
public enum SessionPathResolver {
    public enum ResolverError: Error, LocalizedError, Equatable {
        case unavailable
        case invalidThreadID

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
        guard let canonicalThreadID = canonicalUUID(threadID) else { throw ResolverError.invalidThreadID }
        let candidates = discover(codexHome: codexHome, requiredThreadID: canonicalThreadID)
        guard let candidate = preferred(candidates) else { throw ResolverError.unavailable }
        return candidate.url
    }

    /// Finds a recent valid session for explicitly labeled fallback use only.
    public static func resolveFallback(codexHome: URL) throws -> (threadID: String, url: URL) {
        let candidates = discover(codexHome: codexHome, requiredThreadID: nil)
        guard let candidate = preferred(candidates) else { throw ResolverError.unavailable }
        return (candidate.threadID, candidate.url)
    }

    private struct Candidate {
        let threadID: String
        let url: URL
        let modificationDate: Date
        let hasSessionMetadata: Bool
    }

    private static func discover(codexHome: URL, requiredThreadID: String?) -> [Candidate] {
        let fileManager = FileManager.default
        let home = codexHome.standardizedFileURL.resolvingSymlinksInPath()
        guard fileManager.fileExists(atPath: home.path) else { return [] }
        var candidates: [Candidate] = []

        for directoryName in ["sessions", "archived_sessions"] where candidates.count < maximumCandidates {
            let directory = home.appendingPathComponent(directoryName, isDirectory: true)
            guard isContained(directory.resolvingSymlinksInPath(), by: home),
                  let enumerator = fileManager.enumerator(
                    at: directory,
                    includingPropertiesForKeys: [.isRegularFileKey, .contentModificationDateKey],
                    options: [.skipsHiddenFiles]
                  ) else { continue }

            for case let discovered as URL in enumerator {
                guard candidates.count < maximumCandidates else { break }
                let resolved = discovered.standardizedFileURL.resolvingSymlinksInPath()
                guard isContained(resolved, by: home), isRollout(resolved),
                      let threadID = threadID(in: resolved.lastPathComponent),
                      requiredThreadID == nil || requiredThreadID == threadID,
                      let values = try? resolved.resourceValues(forKeys: [.isRegularFileKey, .contentModificationDateKey]),
                      values.isRegularFile == true else { continue }
                candidates.append(Candidate(
                    threadID: threadID,
                    url: resolved.standardizedFileURL,
                    modificationDate: values.contentModificationDate ?? .distantPast,
                    hasSessionMetadata: hasMatchingSessionMetadata(in: resolved, threadID: threadID)
                ))
            }
        }
        return candidates
    }

    private static func preferred(_ candidates: [Candidate]) -> Candidate? {
        guard !candidates.isEmpty else { return nil }
        let metadataCandidates = candidates.filter(\.hasSessionMetadata)
        let pool = metadataCandidates.isEmpty ? candidates : metadataCandidates
        return pool.max { left, right in
            if left.modificationDate != right.modificationDate { return left.modificationDate < right.modificationDate }
            return left.url.path < right.url.path
        }
    }

    private static func isRollout(_ url: URL) -> Bool {
        let name = url.lastPathComponent
        return name.hasPrefix("rollout-") && url.pathExtension == "jsonl"
    }

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
        let childPath = child.standardizedFileURL.path
        let parentPath = parent.standardizedFileURL.path
        return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
    }

    /// Reads only initial structural metadata; event contents are neither retained nor exposed.
    private static func hasMatchingSessionMetadata(in url: URL, threadID: String) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let data = handle.readData(ofLength: metadataReadLimit)
        for line in data.split(separator: 0x0A) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
                  let root = object as? [String: Any],
                  let type = root["type"] as? String,
                  type == "session_meta" || type == "history_base",
                  let payload = root["payload"] as? [String: Any] else { continue }
            let identifiers = [payload["id"], payload["thread_id"], payload["threadId"], root["id"]]
            if identifiers.compactMap({ $0 as? String }).contains(where: { canonicalUUID($0) == threadID }) {
                return true
            }
        }
        return false
    }
}
