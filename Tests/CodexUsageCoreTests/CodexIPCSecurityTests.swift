import Darwin
import XCTest
@testable import CodexUsageCore

final class CodexIPCSecurityTests: XCTestCase {
    func testOnlyOwnedSocketInOwnedNonWritableDirectoryIsAccepted() {
        let cases: [(mode_t, uid_t, mode_t, uid_t, Bool)] = [
            (mode_t(S_IFSOCK) | 0o600, 501, mode_t(S_IFDIR) | 0o700, 501, true),
            (mode_t(S_IFREG) | 0o600, 501, mode_t(S_IFDIR) | 0o700, 501, false),
            (mode_t(S_IFSOCK) | 0o600, 502, mode_t(S_IFDIR) | 0o700, 501, false),
            (mode_t(S_IFSOCK) | 0o600, 501, mode_t(S_IFDIR) | 0o770, 501, false),
            (mode_t(S_IFSOCK) | 0o600, 501, mode_t(S_IFDIR) | 0o707, 501, false),
            (mode_t(S_IFSOCK) | 0o600, 501, mode_t(S_IFDIR) | 0o700, 502, false),
            (mode_t(S_IFLNK) | 0o700, 501, mode_t(S_IFDIR) | 0o700, 501, false),
            (mode_t(S_IFSOCK) | 0o600, 501, mode_t(S_IFLNK) | 0o700, 501, false)
        ]
        for (mode, owner, directoryMode, directoryOwner, expected) in cases {
            let attributes = SocketFileAttributes(mode: mode, ownerID: owner, directoryMode: directoryMode, directoryOwnerID: directoryOwner)
            XCTAssertEqual(SocketSecurityValidator.validate(socketURL: URL(fileURLWithPath: "/synthetic/ipc.sock"), currentUserID: 501, attributes: attributes), expected)
        }
    }

    func testCandidateOrderUsesOverridesBeforeDefaults() {
        let candidates = CodexIPCClient.socketCandidates(environment: ["CODEX_HOME": "/custom/codex", "TMPDIR": "/custom/tmp"], homeDirectory: URL(fileURLWithPath: "/users/synthetic"))
        XCTAssertEqual(candidates.map(\.path), ["/custom/codex/ipc/ipc.sock", "/users/synthetic/.codex/ipc/ipc.sock", "/custom/tmp/codex-ipc/ipc.sock", "/tmp/codex-ipc/ipc.sock"])
    }
}
