import Foundation
import XCTest
@testable import CodexUsageCore

final class JSONRPCLineCodecTests: XCTestCase {
    func testCodecBuffersFragmentedLines() throws {
        var codec = JSONRPCLineCodec()
        XCTAssertTrue(codec.append(Data("{\"id\":1".utf8)).isEmpty)
        let messages = codec.append(Data(",\"result\":{}}\n{\"method\":\"x\"}\n".utf8))
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["id"] as? Int, 1)
        XCTAssertEqual(messages[1]["method"] as? String, "x")
    }

    func testCodecSkipsEmptyAndMalformedLinesWhileKeepingFollowingMessages() {
        var codec = JSONRPCLineCodec()
        let messages = codec.append(Data("\nnot-json\n{\"id\":2}\n".utf8))
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["id"] as? Int, 2)
    }

    func testCodecDropsOversizedUnterminatedFrame() {
        var codec = JSONRPCLineCodec()
        XCTAssertTrue(codec.append(Data(repeating: 65, count: 4 * 1024 * 1024 + 1)).isEmpty)
        XCTAssertTrue(codec.append(Data("{\"method\":\"inside-discarded-frame\"}\n".utf8)).isEmpty)
        let messages = codec.append(Data("{\"method\":\"after-overflow\"}\n".utf8))
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages.first?["method"] as? String, "after-overflow")
    }

    func testOversizedTerminatedFrameCannotBypassCap() {
        let oversized = Data(("{\"padding\":\"" + String(repeating: "x", count: 4 * 1024 * 1024) + "\"}\n{\"id\":9}\n").utf8)
        for chunkSize in [oversized.count, 65_537] {
            var codec = JSONRPCLineCodec()
            var messages: [[String: Any]] = []
            for offset in stride(from: 0, to: oversized.count, by: chunkSize) {
                messages += codec.append(oversized.subdata(in: offset..<min(offset + chunkSize, oversized.count)))
            }
            XCTAssertEqual(messages.count, 1)
            XCTAssertEqual(messages.first?["id"] as? Int, 9)
        }
    }

    func testEncodeAppendsOneNewlineToJSONObject() throws {
        let encoded = try JSONRPCLineCodec().encode(["id": 3, "method": "account/rateLimits/read", "params": NSNull()])
        XCTAssertEqual(encoded.last, 10)
        XCTAssertFalse(encoded.dropLast().contains(10))
        let object = try JSONSerialization.jsonObject(with: encoded.dropLast()) as? [String: Any]
        XCTAssertEqual(object?["id"] as? Int, 3)
        XCTAssertEqual(object?["method"] as? String, "account/rateLimits/read")
    }
}
