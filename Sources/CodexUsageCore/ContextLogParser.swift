import Foundation

/// Extracts only structural token-count metadata from a bounded JSONL tail.
public enum ContextLogParser {
    public static let maximumTailBytes = 8 * 1024 * 1024

    public static func parseLatest(
        data: Data,
        threadID: String,
        updatedAt: Date,
        provenance: SnapshotProvenance
    ) -> ContextUsageSnapshot? {
        let records = completeRecords(in: data)
        var postCompactionTokens: [TokenRecord] = []
        var latestToken: TokenRecord?
        var sawCompaction = false
        var priorToken: TokenRecord?

        for record in records.reversed() {
            switch record {
            case .compaction:
                sawCompaction = true
            case let .token(token):
                if !sawCompaction {
                    latestToken = latestToken ?? token
                    postCompactionTokens.append(token)
                } else {
                    priorToken = priorToken ?? token
                }
            }
        }

        guard let latestToken else { return nil }
        if sawCompaction, let priorToken,
           !postCompactionTokens.contains(where: { $0.usedTokens != priorToken.usedTokens }) {
            return nil
        }
        return ContextUsageSnapshot(
            threadID: threadID,
            usedTokens: latestToken.usedTokens,
            windowTokens: latestToken.windowTokens,
            updatedAt: latestToken.timestamp ?? updatedAt,
            provenance: provenance
        )
    }

    private struct TokenRecord {
        let usedTokens: Int64
        let windowTokens: Int64
        let timestamp: Date?
    }

    private enum Record {
        case token(TokenRecord)
        case compaction
    }

    private static func completeRecords(in data: Data) -> [Record] {
        var tail = Array(data.suffix(maximumTailBytes))
        guard let finalNewline = tail.lastIndex(of: 0x0A) else { return [] }
        tail = Array(tail[...finalNewline])
        if data.count > maximumTailBytes, let firstNewline = tail.firstIndex(of: 0x0A) {
            tail = Array(tail[(firstNewline + 1)...])
        }
        return tail.split(separator: 0x0A).compactMap(parseRecord)
    }

    private static func parseRecord(_ line: ArraySlice<UInt8>) -> Record? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line)),
              let root = object as? [String: Any] else { return nil }
        if isCompaction(root) { return .compaction }
        guard root["type"] as? String == "event_msg",
              let payload = root["payload"] as? [String: Any],
              payload["type"] as? String == "token_count",
              let info = payload["info"] as? [String: Any],
              let lastUsage = info["last_token_usage"] as? [String: Any],
              let rawUsed = integer(lastUsage["total_tokens"]),
              let windowTokens = integer(info["model_context_window"]), windowTokens > 0 else { return nil }
        return .token(TokenRecord(
            usedTokens: max(0, rawUsed),
            windowTokens: windowTokens,
            timestamp: timestamp(root["timestamp"])
        ))
    }

    private static func isCompaction(_ root: [String: Any]) -> Bool {
        let rootType = root["type"] as? String
        if rootType == "contextCompaction" || rootType == "context_compaction" { return true }
        guard rootType == "event_msg", let payload = root["payload"] as? [String: Any],
              let payloadType = payload["type"] as? String else { return false }
        return ["contextCompaction", "context_compaction", "compact", "compaction"].contains(payloadType)
    }

    private static func integer(_ value: Any?) -> Int64? {
        guard let number = value as? NSNumber, !(number is Bool) else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value.rounded() == value,
              value > Double(Int64.min), value < Double(Int64.max) else { return nil }
        return Int64(value)
    }

    private static func timestamp(_ value: Any?) -> Date? {
        guard let string = value as? String else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }
}
