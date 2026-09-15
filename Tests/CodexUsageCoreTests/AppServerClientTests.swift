import Foundation
import Darwin
import XCTest
@testable import CodexUsageCore

final class AppServerClientTests: XCTestCase {
    func testInitializationErrorReapsChildAndRecovers() throws {
        try assertHandshakeRecovery(firstResponse: "printf '{\"id\":1,\"error\":{\"code\":-1}}\\n'")
    }

    func testSilentInitializationTimesOutReapsChildAndRecovers() throws {
        try assertHandshakeRecovery(firstResponse: ":")
    }

    private func assertHandshakeRecovery(firstResponse: String) throws {
        let fixture = try SyntheticAppServer(script: """
        count=0
        if [ -f \(fixturePath("count")) ]; then count=$(cat \(fixturePath("count"))); fi
        count=$((count + 1))
        printf '%s' "$count" > \(fixturePath("count"))
        read line || exit 2
        echo $$ >> \(fixturePath("events"))
        if [ "$count" -eq 1 ]; then
          \(firstResponse)
          while read line; do :; done
          exit 0
        fi
        printf '{"id":1,"result":{}}\\n'
        for method in initialized account/read account/rateLimits/read; do
          read line || exit 3
          case "$line" in *"$method"*) :;; *) exit 4;; esac
        done
        printf '{"id":3,"result":{"rateLimits":{"primary":{"usedPercent":0,"windowDurationMins":300}}}}\\n'
        while read line; do :; done
        """)
        let client = AppServerClient(binaryResolver: { fixture.executable.path })
        defer { client.stop() }
        let failure = expectation(description: "initialization failure")
        let recovery = expectation(description: "recovered quota")
        client.onError = { error in
            XCTAssertEqual(error, .initializationFailed)
            failure.fulfill()
        }
        client.onSnapshot = { snapshot in
            XCTAssertEqual(snapshot.windows.first?.remainingPercent, 100)
            recovery.fulfill()
        }
        client.start()
        wait(for: [failure, recovery], timeout: 8)
        XCTAssertEqual(fixture.invocationCount, 2)
        let oldPID = try XCTUnwrap(fixture.events.first.flatMap(Int32.init))
        XCTAssertEqual(kill(oldPID, 0), -1, "failed handshake child must be reaped")
        XCTAssertEqual(errno, ESRCH)
    }

    func testStopWaitsForOwnedChildThatIgnoresTermination() throws {
        let fixture = try SyntheticAppServer(script: """
        trap '' TERM
        echo $$ >> \(fixturePath("events"))
        while :; do :; done
        """)
        let client = AppServerClient(binaryResolver: { fixture.executable.path })
        client.start()
        XCTAssertTrue(waitUntil(timeout: 1) { fixture.events.count == 1 })
        let pid = try XCTUnwrap(fixture.events.first.flatMap(Int32.init))
        defer { _ = kill(pid, SIGKILL) }
        let started = Date()
        client.stop()
        XCTAssertEqual(kill(pid, 0), -1, "stop must reap its own child before returning")
        XCTAssertEqual(errno, ESRCH)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testProtocolRequestsUseTheReadOnlyAppServerContract() {
        let initialization = AppServerClient.initializationRequest
        XCTAssertEqual(initialization["id"] as? Int, 1)
        XCTAssertEqual(initialization["method"] as? String, "initialize")
        let params = initialization["params"] as? [String: Any]
        XCTAssertEqual((params?["clientInfo"] as? [String: Any])?["name"] as? String, "codex-usage-overlay")
        XCTAssertEqual((params?["clientInfo"] as? [String: Any])?["version"] as? String, "0.1.0")
        XCTAssertEqual((params?["capabilities"] as? [String: Any])?["experimentalApi"] as? Bool, true)

        let followUps = AppServerClient.postInitializationRequests
        XCTAssertEqual(followUps.map { $0["method"] as? String }, ["initialized", "account/read", "account/rateLimits/read"])
        XCTAssertEqual(followUps[1]["id"] as? Int, 2)
        XCTAssertEqual((followUps[1]["params"] as? [String: Any])?["refreshToken"] as? Bool, false)
        XCTAssertEqual(followUps[2]["id"] as? Int, 3)
        XCTAssertTrue(followUps[2]["params"] is NSNull)
    }

    func testSyntheticServerReceivesInitializationThenReadOnlyAccountRequests() throws {
        let fixture = try SyntheticAppServer(script: """
        read line || exit 2
        case "$line" in *initialize*) echo initialize >> \(fixturePath("events"));; *) exit 3;; esac
        printf '{"id":1,"result":{}}\\n'
        for method in initialized account/read account/rateLimits/read; do
          read line || exit 4
          case "$line" in *"$method"*) echo "$method" >> \(fixturePath("events"));; *) exit 5;; esac
        done
        while read line; do :; done
        """)
        let client = AppServerClient(binaryResolver: { fixture.executable.path })
        client.start()

        XCTAssertTrue(waitUntil(timeout: 1) {
            fixture.events == ["initialize", "initialized", "account/read", "account/rateLimits/read"]
        })
        client.stop()
    }

    func testRestartDropsPartialFrameBeforeReplacementHandshake() throws {
        let fixture = try SyntheticAppServer(script: """
        count=0
        if [ -f \(fixturePath("count")) ]; then count=$(cat \(fixturePath("count"))); fi
        count=$((count + 1))
        printf '%s' "$count" > \(fixturePath("count"))
        if [ "$count" -eq 1 ]; then
          echo partial-exit >> \(fixturePath("events"))
          printf '{"id":1'
          exit 0
        fi
        read line || exit 2
        case "$line" in *initialize*) echo replacement-initialize >> \(fixturePath("events"));; *) exit 3;; esac
        printf '{"id":1,"result":{}}\\n'
        for method in initialized account/read account/rateLimits/read; do
          read line || exit 4
          case "$line" in *"$method"*) echo "$method" >> \(fixturePath("events"));; *) exit 5;; esac
        done
        while read line; do :; done
        """)
        let client = AppServerClient(binaryResolver: { fixture.executable.path })
        client.start()

        XCTAssertTrue(waitUntil(timeout: 2.5) {
            fixture.events == ["partial-exit", "replacement-initialize", "initialized", "account/read", "account/rateLimits/read"]
        })
        client.stop()
    }

    func testForegroundTimerDoesNotSendRequestsBeforeReplacementHandshake() throws {
        let fixture = try SyntheticAppServer(script: """
        count=0
        if [ -f \(fixturePath("count")) ]; then count=$(cat \(fixturePath("count"))); fi
        count=$((count + 1))
        printf '%s' "$count" > \(fixturePath("count"))
        if [ "$count" -eq 1 ]; then
          read line || exit 2
          printf '{"id":1,"result":{}}\\n'
          for method in initialized account/read account/rateLimits/read; do read line || exit 3; done
          echo first-exit >> \(fixturePath("events"))
          exit 0
        fi
        read line || exit 4
        case "$line" in *initialize*) echo replacement-initialize >> \(fixturePath("events"));; *) echo premature >> \(fixturePath("events")); exit 5;; esac
        sleep 0.3
        printf '{"id":1,"result":{}}\\n'
        read line || exit 6
        case "$line" in *initialized*) :;; *) echo premature >> \(fixturePath("events")); exit 7;; esac
        for method in account/read account/rateLimits/read; do read line || exit 8; done
        echo replacement-ready >> \(fixturePath("events"))
        while read line; do :; done
        """)
        let client = AppServerClient(binaryResolver: { fixture.executable.path }, refreshInterval: 0.05)
        client.setForegroundActive(true)
        client.start()

        XCTAssertTrue(waitUntil(timeout: 2.5) { fixture.events.contains("replacement-ready") })
        XCTAssertFalse(fixture.events.contains("premature"))
        client.stop()
    }

    func testClosedChildStdinReportsTransportFailureAndRestarts() throws {
        let fixture = try SyntheticAppServer(script: """
        count=0
        if [ -f \(fixturePath("count")) ]; then count=$(cat \(fixturePath("count"))); fi
        count=$((count + 1))
        printf '%s' "$count" > \(fixturePath("count"))
        read line || exit 2
        exec 0<&-
        printf '{"id":1,"result":{}}\\n'
        sleep 2
        """)
        let client = AppServerClient(binaryResolver: { fixture.executable.path })
        let transportFailure = expectation(description: "transport failure")
        transportFailure.assertForOverFulfill = false
        client.onError = { error in
            if error == .transportFailed { transportFailure.fulfill() }
        }
        client.start()

        wait(for: [transportFailure], timeout: 2)
        XCTAssertTrue(waitUntil(timeout: 2.5) { fixture.invocationCount >= 2 })
        client.stop()
    }

    private func fixturePath(_ name: String) -> String {
        "__FIXTURE_\(name.uppercased())__"
    }

    private func waitUntil(timeout: TimeInterval, condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return condition()
    }
}

private final class SyntheticAppServer {
    let directory: URL
    let executable: URL
    private let eventsURL: URL
    private let countURL: URL

    init(script: String) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        executable = directory.appendingPathComponent("synthetic-app-server")
        eventsURL = directory.appendingPathComponent("events")
        countURL = directory.appendingPathComponent("count")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let expanded = script
            .replacingOccurrences(of: "__FIXTURE_EVENTS__", with: shellQuote(eventsURL.path))
            .replacingOccurrences(of: "__FIXTURE_COUNT__", with: shellQuote(countURL.path))
        try ("#!/bin/sh\nset -eu\n" + expanded + "\n").write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
    }

    var events: [String] {
        guard let text = try? String(contentsOf: eventsURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").map(String.init)
    }

    var invocationCount: Int {
        guard let text = try? String(contentsOf: countURL, encoding: .utf8) else { return 0 }
        return Int(text.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }
}

private func shellQuote(_ value: String) -> String {
    "'" + value.replacingOccurrences(of: "'", with: "'\\\"'\\\"'") + "'"
}
