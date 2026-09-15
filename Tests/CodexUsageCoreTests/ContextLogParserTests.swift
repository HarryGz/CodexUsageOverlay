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

    // Break caught: treating JSON numeric zero and one as booleans rather than valid token values.
    func testAcceptsNumericZeroUsageAndOneTokenWindow() {
        XCTAssertEqual(parse(tokenLine(tokens: 0, window: 1))?.usedTokens, 0)
        XCTAssertEqual(parse(tokenLine(tokens: 1, window: 1))?.windowTokens, 1)
    }

    // Break caught: accepting actual JSON boolean values as numeric token values.
    func testRejectsBooleanTokenValues() {
        let line = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":true},\"model_context_window\":1}}}\n"

        XCTAssertNil(parse(line))
    }

    // Break caught: decoding irrelevant message text instead of structurally skipping it.
    func testSkipsUnrelatedSentinelRecordWithoutMaterializingItsPayload() {
        let sentinel = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"response\",\"text\":\"SENTINEL_DO_NOT_DECODE_\\uD800\"}}\n"

        XCTAssertEqual(parse(sentinel + tokenLine(tokens: 12, window: 100))?.usedTokens, 12)
    }

    // Break caught: publishing a replay-like count after compaction without a bounded pre-compaction baseline.
    func testKeepsCompactedTailUnavailableWithoutBoundedBaseline() {
        XCTAssertNil(parse(compactLine + tokenLine(tokens: 1_000, window: 8_000)))
    }

    // Break caught: trusting a complete-looking first bytes slice that actually starts inside a record.
    func testDropsLeadingRecordWhenTailReaderReportsBoundaryCut() {
        XCTAssertNil(ContextLogParser.parseLatest(
            data: Data(tokenLine(tokens: 99, window: 100).utf8),
            threadID: threadID,
            updatedAt: modifiedAt,
            provenance: .selectedThread,
            leadingRecordMayBePartial: true
        ))
    }

    // Break caught: publishing fields accumulated from a newline-terminated but unclosed JSON object.
    func testRejectsNewlineTerminatedIncompleteTokenRecord() {
        let incomplete = "{\"timestamp\":\"2026-09-15T10:00:00Z\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":180000},\"model_context_window\":258400}\n"

        XCTAssertNil(parse(incomplete))
    }

    // Break caught: remaining unavailable after two distinct post-compaction counts establish fresh bounded evidence.
    func testRecoversAfterTwoDistinctPostCompactionCountsWithoutBaseline() {
        XCTAssertEqual(parse(compactLine + tokenLine(tokens: 1_000, window: 8_000) + tokenLine(tokens: 700, window: 8_000))?.usedTokens, 700)
    }

    // Break caught: inventing a timestamp when neither the event nor file metadata provides one.
    func testReturnsNilWhenEventTimestampAndModificationDateAreMissing() {
        let line = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"last_token_usage\":{\"total_tokens\":10},\"model_context_window\":100}}}\n"

        XCTAssertNil(ContextLogParser.parseLatest(data: Data(line.utf8), threadID: threadID, updatedAt: nil, provenance: .selectedThread))
    }

    // Break caught: accepting a complete token object with a trailing root comma.
    func testRejectsTokenRecordWithTrailingRootComma() {
        let malformed = String(tokenLine(tokens: 10, window: 100).dropLast(2)) + ",}\n"

        XCTAssertNil(parse(malformed))
    }

    // Break caught: treating an ignored object field with no value as structurally valid.
    func testRejectsTokenRecordWithIgnoredFieldMissingValue() {
        let malformed = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"ignored\":,\"info\":{\"last_token_usage\":{\"total_tokens\":10},\"model_context_window\":100}}}\n"

        XCTAssertNil(parse(malformed))
    }

    // Break caught: accepting an ignored value with mismatched/unclosed nested containers.
    func testRejectsTokenRecordWithMalformedIgnoredContainer() {
        let malformed = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"ignored\":{\"x\":[},\"info\":{\"last_token_usage\":{\"total_tokens\":10},\"model_context_window\":100}}}\n"

        XCTAssertNil(parse(malformed))
    }

    // Break caught: unbounded array recursion can overflow the stack on a small record.
    func testRejectsExcessiveIgnoredArrayNesting() {
        assertRejectsExcessiveNesting(open: "[", close: "]")
    }

    // Break caught: ignored objects bypassing the same recursion bound as arrays.
    func testRejectsExcessiveIgnoredObjectNesting() {
        assertRejectsExcessiveNesting(open: "{\"x\":", close: "}")
    }

    // Break caught: separate object/array budgets permit excessive mixed nesting.
    func testRejectsExcessiveMixedIgnoredNesting() {
        assertRejectsExcessiveNesting(open: "[{\"x\":", close: "}]", shallowRepetitions: 33)
    }

    // Break caught: rejecting ordinary nested values or leaking depth between siblings.
    func testAcceptsBoundedIgnoredNestingAcrossSiblings() {
        let arrays = String(repeating: "[", count: 64) + "0" + String(repeating: "]", count: 64)
        let objects = String(repeating: "{\"x\":", count: 64) + "0" + String(repeating: "}", count: 64)

        XCTAssertEqual(parse(tokenLineWithIgnoredValue(arrays, additionalField: ",\"other\":\(objects)"))?.usedTokens, 10)
    }

    private func assertRejectsExcessiveNesting(open: String, close: String, shallowRepetitions: Int = 65, file: StaticString = #filePath, line: UInt = #line) {
        // Gate the stress case on a safely shallow rejection. Removing the limit
        // must produce an assertion failure instead of crashing the test runner.
        for depth in [shallowRepetitions, 200_000] {
            let nested = String(repeating: open, count: depth) + "0" + String(repeating: close, count: depth)
            let record = tokenLineWithIgnoredValue(nested)
            XCTAssertLessThan(record.utf8.count, ContextLogParser.maximumTailBytes, file: file, line: line)
            guard parse(record) == nil else {
                XCTFail("Expected rejection of ignored JSON at nesting repetition count \(depth)", file: file, line: line)
                return
            }
        }
    }

    private func tokenLineWithIgnoredValue(_ value: String, additionalField: String = "") -> String {
        String(tokenLine(tokens: 10, window: 100).dropLast(2)) + ",\"ignored\":\(value)\(additionalField)}\n"
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
