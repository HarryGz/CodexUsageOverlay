import Darwin
import Foundation
import XCTest
@testable import CodexUsageCore

final class SessionPathResolverTests: XCTestCase {
    private let threadID = "123E4567-E89B-12D3-A456-426614174000"
    private var codexHome: URL!

    override func setUpWithError() throws {
        codexHome = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsageResolverTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: codexHome, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: codexHome)
    }

    // Break caught: accepting a matching UUID from an unrecognized directory.
    func testResolvesCanonicalUUIDFromSessionsDirectory() throws {
        let expected = try makeRollout(root: "sessions", day: "2026/09/15", name: "rollout-\(threadID).jsonl")

        XCTAssertEqual(try SessionPathResolver.resolve(threadID: threadID.lowercased(), codexHome: codexHome), expected.standardizedFileURL)
    }

    // Break caught: allowing a caller-provided path to escape the session lookup.
    func testRejectsTraversalLikeThreadID() throws {
        XCTAssertThrowsError(try SessionPathResolver.resolve(threadID: "../\(threadID)", codexHome: codexHome))
    }

    // Break caught: returning a symlink that resolves outside the supplied Codex home.
    func testRejectsRolloutSymlinkResolvingOutsideCodexHome() throws {
        let external = FileManager.default.temporaryDirectory.appendingPathComponent("external-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: external) }
        try Data("{}\n".utf8).write(to: external)
        let directory = codexHome.appendingPathComponent("sessions/2026/09/15", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: directory.appendingPathComponent("rollout-\(threadID).jsonl"), withDestinationURL: external)

        XCTAssertThrowsError(try SessionPathResolver.resolve(threadID: threadID, codexHome: codexHome))
    }

    // Break caught: choosing the first segment instead of the latest valid continuation.
    func testPrefersLatestMatchingContinuationSegment() throws {
        _ = try makeRollout(root: "sessions", day: "2026/09/14", name: "rollout-old-\(threadID).jsonl", metadata: "history_base")
        let expected = try makeRollout(root: "archived_sessions", day: "2026/09/15", name: "rollout-new-\(threadID).jsonl", metadata: "session_meta")

        XCTAssertEqual(try SessionPathResolver.resolve(threadID: threadID, codexHome: codexHome), expected.standardizedFileURL)
    }

    func testNewestFallbackIsConsideredAfterMoreThan128Histories() throws {
        for index in 0..<140 {
            let old = try makeRollout(root: "sessions", day: "2025/01/01", name: "rollout-\(index)-\(threadID).jsonl")
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: old.path)
        }
        let newest = try makeRollout(root: "archived_sessions", day: "2026/09/15", name: "rollout-newest-\(threadID).jsonl")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 10_000)], ofItemAtPath: newest.path)
        XCTAssertEqual(try SessionPathResolver.resolveFallback(codexHome: codexHome).url, newest)
        XCTAssertEqual(try SessionPathResolver.resolve(threadID: threadID, codexHome: codexHome), newest)
    }

    // Break caught: reopening a verified path after it has been replaced by an external symlink.
    func testVerifiedDescriptorRemainsBoundToOriginalFileAfterReplacement() throws {
        let original = try makeRollout(root: "sessions", day: "2026/09/15", name: "rollout-\(threadID).jsonl")
        let external = FileManager.default.temporaryDirectory.appendingPathComponent("external-\(UUID().uuidString).jsonl")
        defer { try? FileManager.default.removeItem(at: external) }
        try Data("outside\n".utf8).write(to: external)
        let opened = try SessionPathResolver.openVerified(threadID: threadID, codexHome: codexHome)
        defer { opened.close() }
        try FileManager.default.removeItem(at: original)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: external)

        XCTAssertEqual(String(data: try opened.readTail().data, encoding: .utf8), "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(threadID)\"}}\n")
    }

    // Break caught: deserializing unrelated session text before recognizing session metadata.
    func testFindsSessionMetadataAfterUnrelatedSentinelRecord() throws {
        let directory = codexHome.appendingPathComponent("sessions/2026/09/15", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("rollout-\(threadID).jsonl")
        let contents = "{\"type\":\"event_msg\",\"payload\":{\"type\":\"response\",\"text\":\"SENTINEL_DO_NOT_DECODE_\\uD800\"}}\n" +
            "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(threadID)\"}}\n"
        try Data(contents.utf8).write(to: file)

        XCTAssertEqual(try SessionPathResolver.resolve(threadID: threadID, codexHome: codexHome), file.standardizedFileURL)
    }

    // Break caught: reading bytes appended after the tail reader captured the file size.
    func testTailReadUsesCapturedSizeWhenFileGrows() throws {
        let file = try makeRollout(root: "sessions", day: "2026/09/15", name: "rollout-\(threadID).jsonl")
        let descriptor = open(file.path, O_RDONLY)
        XCTAssertGreaterThanOrEqual(descriptor, 0)
        defer { close(descriptor) }
        let capturedSize = try ContextLogTailReader.capturedSize(of: descriptor)
        let appended = try FileHandle(forWritingTo: file)
        try appended.seekToEnd()
        try appended.write(contentsOf: Data("outside-growth\n".utf8))
        try appended.close()

        XCTAssertEqual(String(data: try ContextLogTailReader.read(fileDescriptor: descriptor, capturedSize: capturedSize).data, encoding: .utf8), "{\"type\":\"session_meta\",\"payload\":{\"id\":\"\(threadID)\"}}\n")
    }

    private func makeRollout(root: String, day: String, name: String, metadata: String = "session_meta") throws -> URL {
        let directory = codexHome.appendingPathComponent("\(root)/\(day)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(name)
        let line = "{\"type\":\"\(metadata)\",\"payload\":{\"id\":\"\(threadID)\"}}\n"
        try Data(line.utf8).write(to: file)
        return file
    }
}
