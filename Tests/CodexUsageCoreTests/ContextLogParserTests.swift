import Foundation
import XCTest
@testable import CodexUsageCore

final class ContextLogParserTests: XCTestCase {
    private let threadID = "123E4567-E89B-12D3-A456-426614174000"
    private let modifiedAt = Date(timeIntervalSince1970: 2_000_000_000)

    // Break caught: parsing the context token count from the permitted event shape incorrectly.
    func testParsesLatestContextTokenCount() {
        let snapshot = parse(tokenLine(tokens: 180_000, window: 258_400))

        XCTAssertEqual(snapshot?.usedTokens, 180_000)
        XCTAssertEqual(snapshot?.windowTokens, 258_400)
        XCTAssertEqual(snapshot?.updatedAt, ISO8601DateFormatter().date(from: "2026-09-15T10:00:00Z"))
    }

    // Break caught: treating an incomplete write as the final event instead of recovering the prior complete line.
    func testWalksBackwardPastUnfinishedTrailingLine() {
        let data = Data((tokenLine(tokens: 1_000, window: 8_000) + "{\"type\":\"event_msg\"").utf8)

        XCTAssertEqual(parse(data)?.usedTokens, 1_000)
    }

    // Break caught: interpreting account-wide total_token_usage as context capacity.
    func testIgnoresTotalTokenUsage() {
        let line = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":999,\"model_context_window\":258400}}}\n"

        XCTAssertNil(parse(line))
    }

    // Break caught: publishing unusable context limits.
    func testRejectsMissingOrZeroContextWindow() {
        XCTAssertNil(parse("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":10}}}}\n"))
        XCTAssertNil(parse(tokenLine(tokens: 10, window: 0)))
    }

    // Break caught: carrying a pre-compaction count into a compacted context.
    func testReturnsNilWhenCompactionHasNoNewDistinctTokenCount() {
        let data = tokenLine(tokens: 1_000, window: 8_000) + compactLine + tokenLine(tokens: 1_000, window: 8_000)

        XCTAssertNil(parse(data))
    }

    // Break caught: suppressing the first genuinely new count after compaction.
    func testAcceptsDistinctTokenCountAfterCompaction() {
        let data = tokenLine(tokens: 1_000, window: 8_000) + compactLine + tokenLine(tokens: 700, window: 8_000)

        XCTAssertEqual(parse(data)?.usedTokens, 700)
    }

    // Break caught: using the file date when a valid event timestamp exists, or failing to use it when absent.
    func testUsesModificationDateOnlyWhenEventTimestampIsInvalid() {
        let line = "{\"timestamp\":\"invalid\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":10},\"model_context_window\":100}}}\n"

        XCTAssertEqual(parse(line)?.updatedAt, modifiedAt)
    }

    private var compactLine: String {
        "{\"type\":\"event_msg\",\"payload\":{\"type\":\"context_compaction\"}}\n"
    }

    private func tokenLine(tokens: Int, window: Int) -> String {
        "{\"timestamp\":\"2026-09-15T10:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":\(tokens)},\"model_context_window\":\(window)}}}\n"
    }

    private func parse(_ string: String) -> ContextUsageSnapshot? {
        parse(Data(string.utf8))
    }

    private func parse(_ data: Data) -> ContextUsageSnapshot? {
        ContextLogParser.parseLatest(data: data, threadID: threadID, updatedAt: modifiedAt, provenance: .selectedThread)
    }
}
