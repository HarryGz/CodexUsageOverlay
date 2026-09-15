import Foundation
import XCTest
@testable import CodexUsageCore

final class CodexBinaryLocatorTests: XCTestCase {
    private let chatGPT = "/Applications/ChatGPT.app/Contents/Resources/codex"
    private let codexApp = "/Applications/Codex.app/Contents/Resources/codex"
    private let homebrew = "/opt/homebrew/bin/codex"
    private let local = "/usr/local/bin/codex"
    private let userLocal = "/Users/tester/.local/bin/codex"

    func testExplicitExecutableWinsOverAllOtherLocations() {
        let explicit = "/tmp/custom-codex"
        let result = CodexBinaryLocator.resolve(
            environment: ["CODEX_BINARY": explicit, "HOME": "/Users/tester"],
            fileExists: { [$0 == explicit, $0 == self.chatGPT, $0 == self.codexApp, $0 == self.homebrew, $0 == self.local, $0 == self.userLocal].contains(true) }
        )
        XCTAssertEqual(result, explicit)
    }

    func testInstalledChatGPTBinaryPrecedesOtherFallbacks() {
        let result = CodexBinaryLocator.resolve(
            environment: ["HOME": "/Users/tester"],
            fileExists: { [$0 == self.chatGPT, $0 == self.codexApp, $0 == self.homebrew].contains(true) }
        )
        XCTAssertEqual(result, chatGPT)
    }

    func testCommonFallbacksAreCheckedInDocumentedOrder() {
        let result = CodexBinaryLocator.resolve(
            environment: ["HOME": "/Users/tester"],
            fileExists: { [$0 == self.homebrew, $0 == self.local, $0 == self.userLocal].contains(true) }
        )
        XCTAssertEqual(result, homebrew)
    }

    func testReturnsNilWhenNoCandidateIsExecutable() {
        XCTAssertNil(CodexBinaryLocator.resolve(environment: ["HOME": "/Users/tester"], fileExists: { _ in false }))
    }
}
