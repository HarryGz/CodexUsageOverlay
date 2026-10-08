import Foundation
import XCTest
@testable import CodexUsageCore

final class TiboFeedParserTests: XCTestCase {
    private let now = ISO8601DateFormatter().date(from: "2026-10-08T05:30:00Z")!

    func testRejectsWrongSourceScopeOrProfile() throws {
        for (field, value, expected) in [
            ("source", "scrape", TiboFeedParserError.invalidSource),
            ("source_scope", "search", TiboFeedParserError.invalidScope)
        ] {
            var feed = validFeed()
            feed[field] = value
            XCTAssertThrowsError(try TiboFeedParser.parse(data: data(feed), now: now)) {
                XCTAssertEqual($0 as? TiboFeedParserError, expected)
            }
        }

        var feed = validFeed()
        feed["profile"] = ["handle": "someone_else", "name": "Tibo"]
        XCTAssertThrowsError(try TiboFeedParser.parse(data: data(feed), now: now)) {
            XCTAssertEqual($0 as? TiboFeedParserError, .invalidProfile)
        }
    }

    func testRejectsStaleOrOlderThanFifteenMinutes() throws {
        var stale = validFeed()
        stale["stale"] = true
        XCTAssertThrowsError(try TiboFeedParser.parse(data: data(stale), now: now)) {
            XCTAssertEqual($0 as? TiboFeedParserError, .staleFeed)
        }

        var old = validFeed()
        old["fetched_at"] = "2026-10-08T05:14:59Z"
        XCTAssertThrowsError(try TiboFeedParser.parse(data: data(old), now: now)) {
            XCTAssertEqual($0 as? TiboFeedParserError, .feedTooOld)
        }

        var future = validFeed()
        future["fetched_at"] = "2026-10-08T05:30:01Z"
        XCTAssertThrowsError(try TiboFeedParser.parse(data: data(future), now: now)) {
            XCTAssertEqual($0 as? TiboFeedParserError, .invalidFetchedAt)
        }
    }

    func testRejectsFutureDatedAndNonCanonicalPost() throws {
        var future = validFeed()
        future["tweets"] = [tweet(
            id: "2108040921044639779",
            url: "https://x.com/thsottiaux/status/2108040921044639779",
            text: "Global reset landing tomorrow",
            at: "2026-10-08T05:35:01Z"
        )]
        XCTAssertThrowsError(try TiboFeedParser.parse(data: data(future), now: now)) {
            XCTAssertEqual($0 as? TiboFeedParserError, .invalidMessage)
        }

        for url in [
            "http://x.com/thsottiaux/status/2108040921044639779",
            "https://x.com/other/status/2108040921044639779",
            "https://x.com/thsottiaux/status/999",
            "https://x.com/thsottiaux/status/2108040921044639779?tracking=1"
        ] {
            var feed = validFeed()
            feed["tweets"] = [tweet(
                id: "2108040921044639779",
                url: url,
                text: "Global reset landing tomorrow"
            )]
            XCTAssertThrowsError(try TiboFeedParser.parse(data: data(feed), now: now)) {
                XCTAssertEqual($0 as? TiboFeedParserError, .invalidMessage)
            }
        }
    }

    func testRejectsResponseOverOneMiB() {
        let oversized = Data(repeating: 0x20, count: TiboAlertLimits.feedResponseBytes + 1)
        XCTAssertThrowsError(try TiboFeedParser.parse(data: oversized, now: now)) {
            XCTAssertEqual($0 as? TiboFeedParserError, .responseTooLarge)
        }
    }

    func testClassifiesFourQualifyingCategories() throws {
        let fixtures: [(String, [String: Any], TiboMessageCategory)] = [
            ("2105843926221660585", tweet(
                id: "2105843926221660585",
                url: "https://x.com/thsottiaux/status/2105843926221660585",
                text: "Global reset landing tomorrow 10am PST for all paid ChatGPT accounts.",
                lane: "reset_announcement"
            ), .resetAnnouncement),
            ("2106131810921136451", tweet(
                id: "2106131810921136451",
                url: "https://x.com/thsottiaux/status/2106131810921136451",
                text: "Reset all propagated. Enjoy.",
                lane: "reset_announcement",
                explicit: true
            ), .resetCompleted),
            ("2107913674593644711", tweet(
                id: "2107913674593644711",
                url: "https://x.com/thsottiaux/status/2107913674593644711",
                text: "Loading a banked reset in everyone's paid accounts.",
                kind: "banked"
            ), .bankedReset),
            ("2106845241357824205", tweet(
                id: "2106845241357824205",
                url: "https://x.com/thsottiaux/status/2106845241357824205",
                text: "Over the next 28 days, each day we’ll either ship one thing that is a clear improvement and relevant for most codex/work users or ship a full reset.",
                localized: "在接下来的 28 天里，我们每天要么发布一项明确改进，要么进行一次彻底的重置。"
            ), .strongHint)
        ]

        for (id, fixture, category) in fixtures {
            var feed = validFeed()
            feed["tweets"] = [fixture]
            let result = try TiboFeedParser.parse(data: data(feed), now: now)
            let message = try XCTUnwrap(result.newestQualifyingMessage)
            XCTAssertEqual(message.id, id)
            XCTAssertEqual(message.category, category)
            XCTAssertEqual(message.canonicalURL.absoluteString, "https://x.com/thsottiaux/status/\(id)")
            XCTAssertEqual(message.publishedAt, ISO8601DateFormatter().date(from: "2026-10-08T05:20:00Z"))
            XCTAssertLessThanOrEqual(message.localizedSummary.unicodeScalars.count, TiboAlertLimits.summaryScalars)
            XCTAssertLessThanOrEqual(message.localizedSummary.split(separator: "\n", omittingEmptySubsequences: false).count, TiboAlertLimits.summaryLines)
        }
    }

    func testStructuredFieldsTakePrecedenceOverTextFallback() throws {
        var feed = validFeed()
        feed["tweets"] = [tweet(
            id: "2107913738791596286",
            url: "https://x.com/thsottiaux/status/2107913738791596286",
            text: "Will be there by EOD PST.",
            kind: "other",
            bankedState: "arriving"
        )]
        XCTAssertEqual(
            try TiboFeedParser.parse(data: data(feed), now: now).newestQualifyingMessage?.category,
            .bankedReset
        )
    }

    func testIgnoresFeaturePostsRepliesProbabilityAndCommunityOnlyObservations() throws {
        let nonQualifying = [
            tweet(
                id: "2107158998495748264",
                url: "https://x.com/thsottiaux/status/2107158998495748264",
                text: "We optimized the default speed to be 50% faster.",
                kind: "other"
            ),
            tweet(
                id: "2107592271952748814",
                url: "https://x.com/thsottiaux/status/2107592271952748814",
                text: "Is this how the internet works?",
                isReply: true
            ),
            tweet(
                id: "2107587334661378382",
                url: "https://x.com/thsottiaux/status/2107587334661378382",
                text: "The probability of a reset is now 80%, based on cadence.",
                kind: "signal"
            )
        ]

        for fixture in nonQualifying {
            var feed = validFeed()
            feed["tweets"] = [fixture]
            XCTAssertNil(try TiboFeedParser.parse(data: data(feed), now: now).newestQualifyingMessage)
        }

        var communityOnly = validFeed()
        communityOnly["tweets"] = []
        communityOnly["signal"] = [
            "tweet_id": "2107676072871600470",
            "summary": "Monitoring suggests a reset soon",
            "kind": "candidate",
            "active": true
        ]
        XCTAssertNil(try TiboFeedParser.parse(data: data(communityOnly), now: now).newestQualifyingMessage)
    }

    func testBoundsSummaryToSixLinesAndFiveHundredUnicodeScalars() throws {
        let longLines = (1...8).map { line in "第\(line)行" + String(repeating: "界", count: 120) }.joined(separator: "\n")
        var feed = validFeed()
        feed["tweets"] = [tweet(
            id: "2105843926221660585",
            url: "https://x.com/thsottiaux/status/2105843926221660585",
            text: "Global reset landing tomorrow.",
            localized: longLines,
            lane: "reset_announcement"
        )]
        let summary = try XCTUnwrap(TiboFeedParser.parse(data: data(feed), now: now).newestQualifyingMessage?.localizedSummary)
        XCTAssertEqual(summary.split(separator: "\n", omittingEmptySubsequences: false).count, 6)
        XCTAssertEqual(summary.unicodeScalars.count, 500)
    }

    private func validFeed() -> [String: Any] {
        [
            "version": 1,
            "fetched_at": "2026-10-08T05:29:00Z",
            "source": "x-api",
            "source_scope": "timeline",
            "stale": false,
            "profile": ["handle": "thsottiaux", "name": "Tibo"],
            "tweets": [tweet(
                id: "2108040921044639779",
                url: "https://x.com/thsottiaux/status/2108040921044639779",
                text: "Confirmed landed across all accounts.",
                bankedState: "available"
            )]
        ]
    }

    private func tweet(
        id: String,
        url: String,
        text: String,
        at: String = "2026-10-08T05:20:00Z",
        localized: String? = nil,
        kind: String = "candidate",
        lane: String = "reset_related",
        explicit: Bool = false,
        bankedState: String? = nil,
        isReply: Bool = false
    ) -> [String: Any] {
        var value: [String: Any] = [
            "id": id,
            "url": url,
            "text": text,
            "at": at,
            "kind": kind,
            "tibo_lane": lane,
            "explicit_reset_claim": explicit,
            "is_reply": isReply
        ]
        value["localized_text"] = localized ?? text
        if let bankedState { value["banked_state"] = bankedState }
        return value
    }

    private func data(_ value: [String: Any]) -> Data {
        try! JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
    }
}
