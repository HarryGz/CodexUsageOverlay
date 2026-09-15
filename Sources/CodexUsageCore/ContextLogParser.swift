import CoreFoundation
import Foundation

/// Extracts only structural token-count metadata from a bounded JSONL tail.
public enum ContextLogParser {
    public static let maximumTailBytes = 8 * 1024 * 1024

    public static func parseLatest(data: Data, threadID: String, updatedAt: Date?, provenance: SnapshotProvenance, leadingRecordMayBePartial: Bool = false) -> ContextUsageSnapshot? {
        let records = completeRecords(in: data, leadingRecordMayBePartial: leadingRecordMayBePartial)
        var post: [TokenRecord] = []
        var latest: TokenRecord?
        var sawCompaction = false
        var prior: TokenRecord?
        for record in records.reversed() {
            switch record {
            case .compaction: sawCompaction = true
            case let .token(token):
                if sawCompaction { prior = prior ?? token }
                else { latest = latest ?? token; post.append(token) }
            }
        }
        guard let latest, let timestamp = latest.timestamp ?? updatedAt else { return nil }
        // Without a pre-marker baseline in this bounded tail, one replay-like post
        // count is not evidence of a fresh compacted context.
        if sawCompaction {
            if let prior {
                guard post.contains(where: { $0.usedTokens != prior.usedTokens }) else { return nil }
            } else {
                guard Set(post.map(\.usedTokens)).count >= 2 else { return nil }
            }
        }
        return ContextUsageSnapshot(threadID: threadID, usedTokens: latest.usedTokens, windowTokens: latest.windowTokens, updatedAt: timestamp, provenance: provenance)
    }

    private struct TokenRecord { let usedTokens: Int64; let windowTokens: Int64; let timestamp: Date? }
    private enum Record { case token(TokenRecord), compaction }

    private static func completeRecords(in data: Data, leadingRecordMayBePartial: Bool) -> [Record] {
        var bytes = Array(data.suffix(maximumTailBytes))
        guard let lastNewline = bytes.lastIndex(of: 0x0A) else { return [] }
        bytes = Array(bytes[..<lastNewline])
        if leadingRecordMayBePartial || data.count > maximumTailBytes {
            guard let firstNewline = bytes.firstIndex(of: 0x0A) else { return [] }
            bytes = Array(bytes[(firstNewline + 1)...])
        }
        return bytes.split(separator: 0x0A).compactMap(parseRecord)
    }

    private static func parseRecord(_ line: ArraySlice<UInt8>) -> Record? {
        let event = StructuralJSONLine.parse(Array(line))
        guard event.isValid else { return nil }
        if event.isCompaction { return .compaction }
        guard event.rootType == "event_msg", event.payloadType == "token_count",
              let used = integer(event.totalTokens), let window = integer(event.windowTokens), window > 0 else { return nil }
        return .token(TokenRecord(usedTokens: max(0, used), windowTokens: window, timestamp: timestamp(event.timestamp)))
    }

    private static func integer(_ text: String?) -> Int64? {
        guard let text, let data = text.data(using: .utf8),
              let number = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let value = number.doubleValue
        guard value.isFinite, value.rounded() == value,
              value > Double(Int64.min), value < Double(Int64.max) else { return nil }
        return Int64(value)
    }

    private static func timestamp(_ text: String?) -> Date? {
        guard let text else { return nil }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: text) ?? ISO8601DateFormatter().date(from: text)
    }
}

/// Byte-level scanner that decodes only recognized structural keys and values.
struct StructuralJSONLine {
    var isValid = false
    var rootType: String?
    var payloadType: String?
    var timestamp: String?
    var totalTokens: String?
    var windowTokens: String?
    var sessionIdentifier: String?

    var isCompaction: Bool {
        if rootType == "contextCompaction" || rootType == "context_compaction" { return true }
        return rootType == "event_msg" && ["contextCompaction", "context_compaction", "compact", "compaction"].contains(payloadType)
    }

    static func parse(_ bytes: [UInt8]) -> Self {
        var scanner = JSONStructuralScanner(bytes: bytes)
        var event = Self()
        guard scanner.beginObject() else { return event }
        while let key = scanner.nextObjectKey() {
            switch key {
            case "type": event.rootType = scanner.readDecodedString()
            case "timestamp": event.timestamp = scanner.readDecodedString()
            case "payload": parsePayload(&scanner, into: &event)
            case "id", "thread_id", "threadId": event.sessionIdentifier = scanner.readDecodedString()
            default: scanner.skipValue()
            }
            if !scanner.nextObjectElement() { break }
        }
        event.isValid = scanner.isValid && scanner.isAtEnd
        return event
    }

    static func sessionMetadataMatches(_ bytes: [UInt8], threadID: String) -> Bool {
        let event = parse(bytes)
        guard event.isValid, event.rootType == "session_meta" || event.rootType == "history_base" else { return false }
        return event.sessionIdentifier?.lowercased() == threadID.lowercased()
    }

    private static func parsePayload(_ scanner: inout JSONStructuralScanner, into event: inout Self) {
        guard scanner.beginObject() else { scanner.skipValue(); return }
        while let key = scanner.nextObjectKey() {
            switch key {
            case "type": event.payloadType = scanner.readDecodedString()
            case "info": parseInfo(&scanner, into: &event)
            case "id", "thread_id", "threadId": event.sessionIdentifier = scanner.readDecodedString()
            default: scanner.skipValue()
            }
            if !scanner.nextObjectElement() { break }
        }
    }

    private static func parseInfo(_ scanner: inout JSONStructuralScanner, into event: inout Self) {
        guard scanner.beginObject() else { scanner.skipValue(); return }
        while let key = scanner.nextObjectKey() {
            switch key {
            case "model_context_window": event.windowTokens = scanner.readNumber()
            case "last_token_usage": parseLastUsage(&scanner, into: &event)
            default: scanner.skipValue()
            }
            if !scanner.nextObjectElement() { break }
        }
    }

    private static func parseLastUsage(_ scanner: inout JSONStructuralScanner, into event: inout Self) {
        guard scanner.beginObject() else { scanner.skipValue(); return }
        while let key = scanner.nextObjectKey() {
            if key == "total_tokens" { event.totalTokens = scanner.readNumber() } else { scanner.skipValue() }
            if !scanner.nextObjectElement() { break }
        }
    }
}

struct JSONStructuralScanner {
    // Recognized schema objects have fixed depth. Bound arbitrary ignored
    // containers separately so even an 8 MiB hostile record cannot exhaust
    // the call stack. Deeper records are rejected without decoding their values.
    private static let maximumIgnoredContainerDepth = 64
    private let bytes: [UInt8]
    private var index = 0
    private(set) var isValid = true
    init(bytes: [UInt8]) { self.bytes = bytes }

    var isAtEnd: Bool { var copy = self; copy.skipWhitespace(); return copy.index == copy.bytes.count }
    mutating func beginObject() -> Bool {
        guard consume(0x7B) else { isValid = false; return false }
        return true
    }
    mutating func nextObjectKey() -> String? {
        skipWhitespace()
        guard index < bytes.count else { isValid = false; return nil }
        if bytes[index] == 0x7D { index += 1; return nil }
        guard let key = readDecodedString(), consume(0x3A) else { isValid = false; return nil }
        return key
    }
    mutating func nextObjectElement() -> Bool {
        skipWhitespace()
        if consume(0x2C) {
            skipWhitespace()
            // A comma always introduces another key/value pair; a closing brace
            // here is a trailing comma, not an empty member.
            guard index < bytes.count, bytes[index] != 0x7D else { isValid = false; return false }
            return true
        }
        if consume(0x7D) { return false }
        isValid = false
        return false
    }
    mutating func readDecodedString() -> String? {
        skipWhitespace()
        guard index < bytes.count, bytes[index] == 0x22 else { isValid = false; return nil }
        index += 1; let start = index; var escaped = false
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x5C {
                escaped = true
                index += 1
                guard index < bytes.count else { isValid = false; return nil }
                let escapedByte = bytes[index]
                if escapedByte == 0x75 {
                    index += 1
                    guard index + 4 <= bytes.count,
                          bytes[index..<(index + 4)].allSatisfy(isHexDigit) else { isValid = false; return nil }
                    index += 4
                } else if [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escapedByte) {
                    index += 1
                } else {
                    isValid = false; return nil
                }
                continue
            }
            if byte == 0x22 {
                let end = index; index += 1
                guard !escaped else { return nil }
                guard let value = String(bytes: bytes[start..<end], encoding: .utf8) else { isValid = false; return nil }
                return value
            }
            guard byte >= 0x20 else { isValid = false; return nil }
            index += 1
        }
        isValid = false
        return nil
    }
    mutating func readNumber() -> String? {
        skipWhitespace()
        let start = index
        skipNumberValue()
        guard isValid else { return nil }
        let raw = bytes[start..<index]
        return String(decoding: raw, as: UTF8.self)
    }
    mutating func skipValue(depth: Int = 0) {
        skipWhitespace()
        guard isValid, index < bytes.count else { isValid = false; return }
        switch bytes[index] {
        case 0x22: skipString()
        case 0x7B:
            guard depth < Self.maximumIgnoredContainerDepth else { isValid = false; return }
            skipObject(depth: depth + 1)
        case 0x5B:
            guard depth < Self.maximumIgnoredContainerDepth else { isValid = false; return }
            skipArray(depth: depth + 1)
        case 0x74: skipLiteral([0x74, 0x72, 0x75, 0x65]) // true
        case 0x66: skipLiteral([0x66, 0x61, 0x6C, 0x73, 0x65]) // false
        case 0x6E: skipLiteral([0x6E, 0x75, 0x6C, 0x6C]) // null
        default: skipNumberValue()
        }
    }

    /// Validates arbitrary ignored JSON without decoding or retaining its values.
    private mutating func skipObject(depth: Int) {
        guard consume(0x7B) else { isValid = false; return }
        skipWhitespace()
        if consume(0x7D) { return }
        while isValid {
            skipString()
            guard isValid, consume(0x3A) else { isValid = false; return }
            skipValue(depth: depth)
            guard isValid else { return }
            skipWhitespace()
            if consume(0x7D) { return }
            guard consume(0x2C) else { isValid = false; return }
            skipWhitespace()
            // JSON does not allow a trailing comma in an object.
            guard index < bytes.count, bytes[index] != 0x7D else { isValid = false; return }
        }
    }

    private mutating func skipArray(depth: Int) {
        guard consume(0x5B) else { isValid = false; return }
        skipWhitespace()
        if consume(0x5D) { return }
        while isValid {
            skipValue(depth: depth)
            guard isValid else { return }
            skipWhitespace()
            if consume(0x5D) { return }
            guard consume(0x2C) else { isValid = false; return }
            skipWhitespace()
            // JSON does not allow a trailing comma in an array.
            guard index < bytes.count, bytes[index] != 0x5D else { isValid = false; return }
        }
    }

    private mutating func skipLiteral(_ literal: [UInt8]) {
        guard index + literal.count <= bytes.count,
              Array(bytes[index..<(index + literal.count)]) == literal else { isValid = false; return }
        index += literal.count
        guard index == bytes.count || isDelimiter(bytes[index]) else { isValid = false; return }
    }

    private mutating func skipNumberValue() {
        let start = index
        if index < bytes.count, bytes[index] == 0x2D { index += 1 }
        guard index < bytes.count else { isValid = false; return }
        if bytes[index] == 0x30 {
            index += 1
            if index < bytes.count, isDigit(bytes[index]) { isValid = false; return }
        } else if isNonzeroDigit(bytes[index]) {
            repeat { index += 1 } while index < bytes.count && isDigit(bytes[index])
        } else {
            isValid = false; return
        }
        if index < bytes.count, bytes[index] == 0x2E {
            index += 1
            guard index < bytes.count, isDigit(bytes[index]) else { isValid = false; return }
            repeat { index += 1 } while index < bytes.count && isDigit(bytes[index])
        }
        if index < bytes.count, bytes[index] == 0x65 || bytes[index] == 0x45 {
            index += 1
            if index < bytes.count, bytes[index] == 0x2B || bytes[index] == 0x2D { index += 1 }
            guard index < bytes.count, isDigit(bytes[index]) else { isValid = false; return }
            repeat { index += 1 } while index < bytes.count && isDigit(bytes[index])
        }
        guard index > start, index == bytes.count || isDelimiter(bytes[index]) else { isValid = false; return }
    }

    private mutating func skipString() {
        guard index < bytes.count, bytes[index] == 0x22 else { isValid = false; return }
        index += 1
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 0x5C {
                index += 1
                guard index < bytes.count else { isValid = false; return }
                let escaped = bytes[index]
                if escaped == 0x75 {
                    index += 1
                    guard index + 4 <= bytes.count,
                          bytes[index..<(index + 4)].allSatisfy(isHexDigit) else { isValid = false; return }
                    index += 4
                } else if [0x22, 0x5C, 0x2F, 0x62, 0x66, 0x6E, 0x72, 0x74].contains(escaped) {
                    index += 1
                } else {
                    isValid = false; return
                }
                continue
            }
            if byte == 0x22 { index += 1; return }
            guard byte >= 0x20 else { isValid = false; return }
            index += 1
        }
        isValid = false
    }
    private mutating func consume(_ byte: UInt8) -> Bool {
        skipWhitespace(); guard index < bytes.count, bytes[index] == byte else { return false }
        index += 1; return true
    }
    private func isDelimiter(_ byte: UInt8) -> Bool { [0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D].contains(byte) }
    private func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }
    private func isNonzeroDigit(_ byte: UInt8) -> Bool { byte >= 0x31 && byte <= 0x39 }
    private func isHexDigit(_ byte: UInt8) -> Bool {
        isDigit(byte) || (byte >= 0x41 && byte <= 0x46) || (byte >= 0x61 && byte <= 0x66)
    }
    private mutating func skipWhitespace() { while index < bytes.count, [0x20, 0x09, 0x0A, 0x0D].contains(bytes[index]) { index += 1 } }
}
