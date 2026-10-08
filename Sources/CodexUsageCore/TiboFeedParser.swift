import Foundation

public enum TiboFeedParserError: Error, Equatable, Sendable {
    case responseTooLarge
    case invalidJSON
    case invalidSource
    case invalidScope
    case invalidProfile
    case staleFeed
    case invalidFetchedAt
    case feedTooOld
    case invalidMessage
}

public enum TiboFeedParser {
    public static func parse(data: Data, now: Date = Date()) throws -> TiboFeedResult {
        guard data.count <= TiboAlertLimits.feedResponseBytes else {
            throw TiboFeedParserError.responseTooLarge
        }

        let feed: Feed
        do {
            feed = try JSONDecoder().decode(Feed.self, from: data)
        } catch {
            throw TiboFeedParserError.invalidJSON
        }

        guard feed.source == "x-api" else { throw TiboFeedParserError.invalidSource }
        guard feed.sourceScope == "timeline" else { throw TiboFeedParserError.invalidScope }
        guard feed.profile.handle == "thsottiaux" else { throw TiboFeedParserError.invalidProfile }
        guard !feed.stale else { throw TiboFeedParserError.staleFeed }
        guard let fetchedAt = parseDate(feed.fetchedAt) else { throw TiboFeedParserError.invalidFetchedAt }

        let age = now.timeIntervalSince(fetchedAt)
        guard age >= 0 else { throw TiboFeedParserError.invalidFetchedAt }
        guard age <= TiboAlertLimits.maximumFeedAge else { throw TiboFeedParserError.feedTooOld }

        var messages: [TiboMessage] = []
        for tweet in feed.tweets {
            let normalized = try normalize(tweet: tweet, now: now)
            if let normalized { messages.append(normalized) }
        }

        let newest = messages.max {
            if $0.publishedAt == $1.publishedAt { return $0.id < $1.id }
            return $0.publishedAt < $1.publishedAt
        }
        return TiboFeedResult(
            fetchedAt: fetchedAt,
            health: .healthy(checkedAt: now, fetchedAt: fetchedAt),
            newestQualifyingMessage: newest
        )
    }

    private static func normalize(tweet: Tweet, now: Date) throws -> TiboMessage? {
        guard validStatusID(tweet.id),
              tweet.url == "https://x.com/thsottiaux/status/\(tweet.id)",
              let publishedAt = parseDate(tweet.at),
              publishedAt.timeIntervalSince(now) <= TiboAlertLimits.publicationFutureTolerance else {
            throw TiboFeedParserError.invalidMessage
        }

        guard let category = classify(tweet) else { return nil }
        guard let canonicalURL = URL(string: "https://x.com/thsottiaux/status/\(tweet.id)") else {
            throw TiboFeedParserError.invalidMessage
        }
        let sourceSummary = nonEmpty(tweet.localizedText) ?? nonEmpty(tweet.text)
        guard let sourceSummary else { throw TiboFeedParserError.invalidMessage }

        return TiboMessage(
            id: tweet.id,
            category: category,
            localizedSummary: boundedSummary(sourceSummary),
            publishedAt: publishedAt,
            canonicalURL: canonicalURL
        )
    }

    private static func classify(_ tweet: Tweet) -> TiboMessageCategory? {
        let text = tweet.text.lowercased()
        let localized = (tweet.localizedText ?? "").lowercased()
        let searchable = text + "\n" + localized

        if tweet.kind == "banked" || ["granted", "arriving", "available", "loading", "loaded"].contains(tweet.bankedState) {
            return .bankedReset
        }

        if tweet.tiboLane == "reset_announcement" || tweet.explicitResetClaim == true {
            return completionLanguage(searchable) ? .resetCompleted : .resetAnnouncement
        }

        guard tweet.isReply != true else { return nil }
        guard resetLanguage(searchable), !predictionLanguage(searchable) else { return nil }
        if completionLanguage(searchable) { return .resetCompleted }
        if bankedLanguage(searchable) { return .bankedReset }
        if announcementLanguage(searchable) { return .resetAnnouncement }
        if strongHintLanguage(searchable) { return .strongHint }
        return nil
    }

    private static func resetLanguage(_ text: String) -> Bool {
        text.contains("reset") || text.contains("重置")
    }

    private static func completionLanguage(_ text: String) -> Bool {
        ["processed", "propagated", "completed", "confirmed landed", "reset has landed", "已处理", "已完成", "已到账", "已重置"].contains { text.contains($0) }
    }

    private static func bankedLanguage(_ text: String) -> Bool {
        text.contains("banked reset") || text.contains("banked quota") || text.contains("备用重置") || text.contains("银行重置")
    }

    private static func announcementLanguage(_ text: String) -> Bool {
        ["landing tomorrow", "reset tomorrow", "will reset", "reset scheduled", "reset is coming", "loading a", "将于", "即将重置", "计划重置"].contains { text.contains($0) }
    }

    private static func strongHintLanguage(_ text: String) -> Bool {
        let campaign = text.contains("28 days") || text.contains("28 天")
        let conditional = text.contains("either") || text.contains(" or ") || text.contains("要么") || text.contains("或者")
        let improvement = text.contains("improvement") || text.contains("update") || text.contains("改进") || text.contains("更新")
        return (campaign && conditional && improvement) || (conditional && improvement && text.contains("full reset"))
    }

    private static func predictionLanguage(_ text: String) -> Bool {
        ["probability", "odds", "cadence", "chance of", "预测", "概率", "可能性", "节奏"].contains { text.contains($0) }
    }

    private static func validStatusID(_ id: String) -> Bool {
        let scalars = id.unicodeScalars
        guard scalars.count >= TiboAlertLimits.minimumStatusIDLength,
              scalars.count <= TiboAlertLimits.maximumStatusIDLength else { return false }
        return scalars.allSatisfy { $0.value >= 48 && $0.value <= 57 }
    }

    private static func boundedSummary(_ value: String) -> String {
        let normalized = value.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var lines = Array(normalized.split(separator: "\n", omittingEmptySubsequences: false).prefix(TiboAlertLimits.summaryLines))
            .map(String.init)
        while lines.count > 1 && lines.last?.isEmpty == true { lines.removeLast() }

        let separatorCount = max(0, lines.count - 1)
        let scalarBudget = max(0, TiboAlertLimits.summaryScalars - separatorCount)
        let currentCount = lines.reduce(0) { $0 + $1.unicodeScalars.count }
        guard currentCount > scalarBudget, !lines.isEmpty else { return lines.joined(separator: "\n") }

        var remaining = scalarBudget
        for index in lines.indices {
            let remainingLines = lines.count - index
            let allowance = Int(ceil(Double(remaining) / Double(remainingLines)))
            lines[index] = String(String.UnicodeScalarView(lines[index].unicodeScalars.prefix(allowance)))
            remaining -= lines[index].unicodeScalars.count
        }
        return lines.joined(separator: "\n")
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func parseDate(_ value: String) -> Date? {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return fractional.date(from: value) ?? ISO8601DateFormatter().date(from: value)
    }
}

private extension TiboFeedParser {
    struct Feed: Decodable {
        let fetchedAt: String
        let source: String
        let sourceScope: String
        let stale: Bool
        let profile: Profile
        let tweets: [Tweet]

        enum CodingKeys: String, CodingKey {
            case fetchedAt = "fetched_at"
            case source
            case sourceScope = "source_scope"
            case stale
            case profile
            case tweets
        }
    }

    struct Profile: Decodable {
        let handle: String
    }

    struct Tweet: Decodable {
        let id: String
        let url: String
        let text: String
        let at: String
        let kind: String?
        let tiboLane: String?
        let explicitResetClaim: Bool?
        let bankedState: String?
        let localizedText: String?
        let isReply: Bool?

        enum CodingKeys: String, CodingKey {
            case id, url, text, at, kind
            case tiboLane = "tibo_lane"
            case explicitResetClaim = "explicit_reset_claim"
            case bankedState = "banked_state"
            case localizedText = "localized_text"
            case isReply = "is_reply"
        }
    }
}
