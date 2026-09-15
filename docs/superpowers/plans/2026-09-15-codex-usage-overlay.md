# Codex Usage Overlay Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Build a native macOS companion that follows the active Codex window and displays remaining account quotas and remaining context-window capacity.

**Architecture:** A Swift Package separates pure parsing and state logic into CodexUsageCore from AppKit presentation in CodexUsageOverlay. Account data comes through a read-only Codex App Server child process, active-task identity comes through validated local IPC, context metrics come from bounded reads of local token-count events, and an event-driven Accessibility tracker positions a non-activating NSPanel.

**Tech Stack:** Swift 5 language mode, Swift Package Manager, Foundation, AppKit, ApplicationServices, Network.framework, XCTest, shell packaging scripts.

**Spec:** docs/superpowers/specs/2026-09-15-codex-usage-overlay-design.md

## Global Constraints

- Target macOS 13 or later; produce the first local build for Apple Silicon.
- Use only Apple system frameworks and Swift Package Manager; add no third-party runtime dependency.
- Treat account percentages and task-context tokens as separate measurements.
- Display remaining account percentages, calculated as clamp(100 - usedPercent, 0...100).
- Never read auth.json, browser cookies, access tokens, message text, prompts, responses, or tool outputs.
- Do not inject into, modify, re-sign, or replace Codex Desktop.
- Keep unknown values unknown; never translate missing data to zero or 100%.
- Keep the panel hidden unless Codex is the foreground application.
- Preserve both upstream MIT notices for any substantial adapted code.
- Use synthetic fixtures only; never copy a real Codex rollout into tests.

---

## File Map

- Package.swift — declares the core library, AppKit executable, and test targets.
- Sources/CodexUsageCore/UsageModels.swift — shared immutable account, context, provenance, and combined snapshot types.
- Sources/CodexUsageCore/AccountUsageParser.swift — converts App Server JSON objects into normalized quota snapshots.
- Sources/CodexUsageCore/JSONRPCLineCodec.swift — newline-delimited JSON framing used by App Server.
- Sources/CodexUsageCore/CodexBinaryLocator.swift — resolves the bundled or PATH Codex executable.
- Sources/CodexUsageCore/AppServerClient.swift — owns the read-only App Server subprocess and refresh lifecycle.
- Sources/CodexUsageCore/SessionPathResolver.swift — maps a thread UUID to safe rollout segments beneath CODEX_HOME.
- Sources/CodexUsageCore/ContextLogParser.swift — parses the newest complete token_count event from a bounded tail.
- Sources/CodexUsageCore/ContextLogMonitor.swift — watches the selected task and publishes context snapshots.
- Sources/CodexUsageCore/ActiveThreadRouter.swift — pure state machine for IPC follow/unfollow broadcasts.
- Sources/CodexUsageCore/CodexIPCClient.swift — validates and reads the local IPC Unix socket.
- Sources/CodexUsageCore/UsageStore.swift — merges independently refreshed account and context states.
- Sources/CodexUsageCore/OverlayPlacement.swift — pure frame-selection and upper-right placement calculations.
- Sources/CodexUsageOverlay/CodexWindowTracker.swift — NSWorkspace and Accessibility observation.
- Sources/CodexUsageOverlay/OverlayViews.swift — compact capsule and expanded detail AppKit views.
- Sources/CodexUsageOverlay/OverlayPanelController.swift — non-activating NSPanel lifecycle and rendering.
- Sources/CodexUsageOverlay/StatusItemController.swift — menu-bar commands and diagnostics.
- Sources/CodexUsageOverlay/AppDelegate.swift — composes services and controls foreground refresh.
- Sources/CodexUsageOverlay/main.swift — launches NSApplication.
- Tests/CodexUsageCoreTests/UsageModelsTests.swift — remaining-value arithmetic and color thresholds.
- Tests/CodexUsageCoreTests/AccountUsageParserTests.swift — account response and sparse-update parsing.
- Tests/CodexUsageCoreTests/JSONRPCLineCodecTests.swift — fragmented and multi-line App Server frames.
- Tests/CodexUsageCoreTests/CodexBinaryLocatorTests.swift — deterministic executable discovery.
- Tests/CodexUsageCoreTests/SessionPathResolverTests.swift — safe thread-to-rollout resolution.
- Tests/CodexUsageCoreTests/ContextLogParserTests.swift — token-count and compaction handling.
- Tests/CodexUsageCoreTests/ActiveThreadRouterTests.swift — multi-window IPC routing.
- Tests/CodexUsageCoreTests/CodexIPCSecurityTests.swift — local socket validation.
- Tests/CodexUsageCoreTests/UsageStoreTests.swift — independent live, stale, and unavailable state.
- Tests/CodexUsageCoreTests/OverlayPlacementTests.swift — deterministic window selection and geometry.
- Tests/CodexUsageCoreTests/DisplayFormattingTests.swift — Chinese compact and detail formatting.
- Resources/Info.plist — menu-bar application metadata.
- scripts/package_app.sh — release build, app bundle assembly, and ad-hoc signing.
- scripts/install.sh — copies the built app to the user Applications directory.
- scripts/uninstall.sh — removes only the installed companion app.
- README.md — installation, permissions, data meanings, and troubleshooting.
- THIRD_PARTY_NOTICES.md — upstream MIT attribution.

---

### Task 1: Package Foundation and Domain Models

**Files:**
- Create: Package.swift
- Create: Sources/CodexUsageCore/UsageModels.swift
- Create: Sources/CodexUsageOverlay/main.swift
- Create: Tests/CodexUsageCoreTests/UsageModelsTests.swift

**Interfaces:**
- Produces: QuotaWindow, AccountUsageSnapshot, ContextUsageSnapshot, SnapshotProvenance, UsageValueState, CombinedUsageSnapshot, CapacityColor.
- Produces: QuotaWindow.remainingPercent and ContextUsageSnapshot.remainingTokens/remainingPercent.

- [ ] **Step 1: Write the failing domain-model tests**

Add XCTest cases that lock down remaining-value semantics:

    import XCTest
    @testable import CodexUsageCore

    final class UsageModelsTests: XCTestCase {
        func testQuotaRemainingClampsServerUsedPercent() {
            XCTAssertEqual(QuotaWindow(usedPercent: 25, durationMinutes: 300, resetsAt: nil).remainingPercent, 75)
            XCTAssertEqual(QuotaWindow(usedPercent: -5, durationMinutes: 300, resetsAt: nil).remainingPercent, 100)
            XCTAssertEqual(QuotaWindow(usedPercent: 140, durationMinutes: 300, resetsAt: nil).remainingPercent, 0)
        }

        func testContextRemainingUsesLatestRequestTotal() {
            let snapshot = ContextUsageSnapshot(
                threadID: "thread-1",
                usedTokens: 180_000,
                windowTokens: 258_400,
                updatedAt: Date(timeIntervalSince1970: 100),
                provenance: .selectedThread
            )
            XCTAssertEqual(snapshot.remainingTokens, 78_400)
            XCTAssertEqual(snapshot.remainingPercent, 30.34, accuracy: 0.01)
        }

        func testUnknownContextLimitKeepsRemainingUnknown() {
            let snapshot = ContextUsageSnapshot(
                threadID: "thread-1",
                usedTokens: 10,
                windowTokens: nil,
                updatedAt: Date(),
                provenance: .selectedThread
            )
            XCTAssertNil(snapshot.remainingTokens)
            XCTAssertNil(snapshot.remainingPercent)
        }
    }

- [ ] **Step 2: Run the focused tests and confirm the target does not exist**

Run:

    swift test --filter UsageModelsTests

Expected: FAIL because Package.swift and CodexUsageCore do not exist.

- [ ] **Step 3: Create the Swift package and minimal model implementation**

Create Package.swift with macOS 13, a CodexUsageCore library, a CodexUsageOverlay executable, and a CodexUsageCoreTests test target:

    // swift-tools-version: 5.9
    import PackageDescription

    let package = Package(
        name: "CodexUsageOverlay",
        platforms: [.macOS(.v13)],
        products: [
            .library(name: "CodexUsageCore", targets: ["CodexUsageCore"]),
            .executable(name: "CodexUsageOverlay", targets: ["CodexUsageOverlay"])
        ],
        targets: [
            .target(name: "CodexUsageCore"),
            .executableTarget(name: "CodexUsageOverlay", dependencies: ["CodexUsageCore"]),
            .testTarget(name: "CodexUsageCoreTests", dependencies: ["CodexUsageCore"])
        ],
        swiftLanguageVersions: [.v5]
    )

Implement Sendable value types with these signatures. Give every public struct a public memberwise initializer matching the argument labels used in the tests:

    public struct QuotaWindow: Equatable, Sendable {
        public let usedPercent: Double
        public let durationMinutes: Int?
        public let resetsAt: Date?
        public var remainingPercent: Double { min(100, max(0, 100 - usedPercent)) }
    }

    public enum SnapshotProvenance: Equatable, Sendable {
        case appServer
        case selectedThread
        case fallbackThread
    }

    public struct ContextUsageSnapshot: Equatable, Sendable {
        public let threadID: String
        public let usedTokens: Int64?
        public let windowTokens: Int64?
        public let updatedAt: Date
        public let provenance: SnapshotProvenance
        public var remainingTokens: Int64? {
            guard let usedTokens, let windowTokens, windowTokens > 0 else { return nil }
            return max(0, windowTokens - max(0, usedTokens))
        }
        public var remainingPercent: Double? {
            guard let remainingTokens, let windowTokens, windowTokens > 0 else { return nil }
            return Double(remainingTokens) / Double(windowTokens) * 100
        }
    }

    public struct AccountUsageSnapshot: Equatable, Sendable {
        public let windows: [QuotaWindow]
        public let planType: String?
        public let updatedAt: Date
    }

    public enum UsageValueState<Value: Equatable & Sendable>: Equatable, Sendable {
        case unavailable(reason: String)
        case live(Value)
        case stale(Value, reason: String)
    }

    public struct CombinedUsageSnapshot: Equatable, Sendable {
        public let account: UsageValueState<AccountUsageSnapshot>
        public let context: UsageValueState<ContextUsageSnapshot>
    }

    public enum CapacityColor: Equatable, Sendable {
        case healthy
        case warning
        case critical
        case unavailable

        public static func classify(remainingPercent: Double?) -> Self {
            guard let value = remainingPercent else { return .unavailable }
            if value > 50 { return .healthy }
            if value >= 20 { return .warning }
            return .critical
        }
    }

- [ ] **Step 4: Run the domain tests**

Run:

    swift test --filter UsageModelsTests

Expected: PASS.

- [ ] **Step 5: Commit the foundation**

    git add Package.swift Sources Tests
    git commit -m "feat: add usage domain models"

---

### Task 2: Account Quota Parsing

**Files:**
- Create: Sources/CodexUsageCore/AccountUsageParser.swift
- Create: Tests/CodexUsageCoreTests/AccountUsageParserTests.swift

**Interfaces:**
- Consumes: QuotaWindow and AccountUsageSnapshot from Task 1.
- Produces: AccountUsageParser.parse(message:mergingWith:now:) -> AccountUsageSnapshot?.
- Produces: AccountUsageParser accepts both rateLimits and rateLimitsByLimitId payload shapes and sparse update notifications.

- [ ] **Step 1: Write failing parser tests with inline synthetic JSON**

Cover a full read response, a sparse account/rateLimits/updated notification, a weekly-only account, and malformed percentages:

    func testParsesPrimaryAndSecondaryWindows() throws {
        let message: [String: Any] = [
            "id": 7,
            "result": [
                "rateLimits": [
                    "primary": ["usedPercent": 25, "windowDurationMins": 300, "resetsAt": 1_800_000_000],
                    "secondary": ["usedPercent": 40, "windowDurationMins": 10_080, "resetsAt": 1_800_604_800],
                    "planType": "plus"
                ]
            ]
        ]
        let result = AccountUsageParser.parse(message: message, mergingWith: nil, now: Date(timeIntervalSince1970: 100))
        XCTAssertEqual(result?.windows.map(\.remainingPercent), [75, 60])
        XCTAssertEqual(result?.planType, "plus")
    }

    func testSparseNotificationPreservesMissingWeeklyWindow() {
        let old = AccountUsageSnapshot(
            windows: [
                QuotaWindow(usedPercent: 25, durationMinutes: 300, resetsAt: nil),
                QuotaWindow(usedPercent: 40, durationMinutes: 10_080, resetsAt: nil)
            ],
            planType: "plus",
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let message: [String: Any] = [
            "method": "account/rateLimits/updated",
            "params": ["rateLimits": ["primary": ["usedPercent": 30, "windowDurationMins": 300]]]
        ]
        let result = AccountUsageParser.parse(message: message, mergingWith: old, now: Date(timeIntervalSince1970: 2))
        XCTAssertEqual(result?.windows.map(\.usedPercent), [30, 40])
    }

- [ ] **Step 2: Run the parser tests and verify failure**

Run:

    swift test --filter AccountUsageParserTests

Expected: FAIL because AccountUsageParser does not exist.

- [ ] **Step 3: Implement normalized quota parsing**

Implement:

    public enum AccountUsageParser {
        public static func parse(
            message: [String: Any],
            mergingWith previous: AccountUsageSnapshot?,
            now: Date = Date()
        ) -> AccountUsageSnapshot?
    }

Rules:

- Read the quota root from result or params.
- Prefer rateLimitsByLimitId["codex"] when present; otherwise use rateLimits.
- Parse primary and secondary independently.
- Match sparse update windows to previous windows by duration, then by primary/secondary position.
- Reject non-numeric usedPercent and non-positive durationMinutes.
- Preserve a previous plan type when a sparse update omits it.
- Sort valid windows by duration ascending; put unknown durations last.
- Return nil when the message contains no recognized quota payload.

- [ ] **Step 4: Run parser and full tests**

Run:

    swift test --filter AccountUsageParserTests
    swift test

Expected: PASS.

- [ ] **Step 5: Commit the account parser**

    git add Sources/CodexUsageCore/AccountUsageParser.swift Tests/CodexUsageCoreTests/AccountUsageParserTests.swift
    git commit -m "feat: parse Codex account quota windows"

---

### Task 3: App Server Transport and Account Service

**Files:**
- Create: Sources/CodexUsageCore/JSONRPCLineCodec.swift
- Create: Sources/CodexUsageCore/CodexBinaryLocator.swift
- Create: Sources/CodexUsageCore/AppServerClient.swift
- Create: Tests/CodexUsageCoreTests/JSONRPCLineCodecTests.swift
- Create: Tests/CodexUsageCoreTests/CodexBinaryLocatorTests.swift

**Interfaces:**
- Consumes: AccountUsageParser from Task 2.
- Produces: JSONRPCLineCodec.append(_:) -> [[String: Any]] and encode(_:) throws -> Data.
- Produces: CodexBinaryLocator.resolve(environment:fileExists:) -> String?.
- Produces: AppServerClient.onSnapshot, AppServerClient.onError, start(), stop(), refreshNow().

- [ ] **Step 1: Write failing codec and executable-location tests**

Use fragmented and multi-message NDJSON:

    func testCodecBuffersFragmentedLines() throws {
        var codec = JSONRPCLineCodec()
        XCTAssertTrue(codec.append(Data("{\"id\":1".utf8)).isEmpty)
        let messages = codec.append(Data(",\"result\":{}}\n{\"method\":\"x\"}\n".utf8))
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[0]["id"] as? Int, 1)
        XCTAssertEqual(messages[1]["method"] as? String, "x")
    }

For the locator, pass a synthetic environment and fileExists closure. Verify CODEX_BINARY wins, then the installed ChatGPT bundle path, then common PATH locations, and that a nonexistent set returns nil.

- [ ] **Step 2: Run focused tests and verify failure**

Run:

    swift test --filter JSONRPCLineCodecTests
    swift test --filter CodexBinaryLocatorTests

Expected: FAIL because the types do not exist.

- [ ] **Step 3: Implement the codec and binary locator**

JSONRPCLineCodec must:

- Buffer bytes until newline.
- Ignore empty or malformed lines without discarding later complete lines.
- Cap the buffer at 4 MiB; clear an oversized unterminated frame.
- Serialize request dictionaries with JSONSerialization and append one newline.

CodexBinaryLocator must check, in order:

1. CODEX_BINARY when it names an executable file.
2. /Applications/ChatGPT.app/Contents/Resources/codex.
3. /Applications/Codex.app/Contents/Resources/codex.
4. /opt/homebrew/bin/codex.
5. /usr/local/bin/codex.
6. ~/.local/bin/codex.

- [ ] **Step 4: Implement the App Server client**

Create a single serial dispatch queue. Launch:

    codex app-server --listen stdio://

Send this initialization request:

    {
      "id": 1,
      "method": "initialize",
      "params": {
        "clientInfo": { "name": "codex-usage-overlay", "version": "0.1.0" },
        "capabilities": { "experimentalApi": true }
      }
    }

After a successful response, send initialized and read-only account requests:

    { "method": "initialized" }
    { "id": 2, "method": "account/read", "params": { "refreshToken": false } }
    { "id": 3, "method": "account/rateLimits/read", "params": null }

AppServerClient must:

- Publish AccountUsageSnapshot on the main queue.
- Merge account/rateLimits/updated through AccountUsageParser.
- Refresh every 180 seconds only while enabled by setForegroundActive(_:).
- Restart an unexpectedly terminated child after 1, 2, 5, then 15 seconds.
- Discard stderr, credentials, raw responses, and account email.
- Cancel timers and readability handlers during stop().

- [ ] **Step 5: Run all automated tests and a process smoke check**

Run:

    swift test
    /Applications/ChatGPT.app/Contents/Resources/codex app-server --help

Expected: all tests PASS; help lists stdio:// as a supported transport.

- [ ] **Step 6: Commit the App Server service**

    git add Sources/CodexUsageCore/JSONRPCLineCodec.swift Sources/CodexUsageCore/CodexBinaryLocator.swift Sources/CodexUsageCore/AppServerClient.swift Tests/CodexUsageCoreTests
    git commit -m "feat: read quotas through Codex App Server"

---

### Task 4: Context Session Resolution and Token Parsing

**Files:**
- Create: Sources/CodexUsageCore/SessionPathResolver.swift
- Create: Sources/CodexUsageCore/ContextLogParser.swift
- Create: Sources/CodexUsageCore/ContextLogMonitor.swift
- Create: Tests/CodexUsageCoreTests/SessionPathResolverTests.swift
- Create: Tests/CodexUsageCoreTests/ContextLogParserTests.swift

**Interfaces:**
- Consumes: ContextUsageSnapshot and SnapshotProvenance from Task 1.
- Produces: SessionPathResolver.resolve(threadID:codexHome:) throws -> URL.
- Produces: ContextLogParser.parseLatest(data:threadID:updatedAt:provenance:) -> ContextUsageSnapshot?.
- Produces: ContextLogMonitor.select(threadID:provenance:), selectFallbackRootSession(provenance:), start(), stop(), refreshNow().

- [ ] **Step 1: Write failing resolver tests with temporary synthetic directories**

Create rollout filenames containing a known UUID under sessions/YYYY/MM/DD and archived_sessions. Verify exact UUID matching, reject a traversal-like thread ID, reject symlinks resolving outside CODEX_HOME, and prefer the latest valid continuation segment for the same thread.

- [ ] **Step 2: Write failing parser tests**

Use newline-delimited synthetic events:

    let tokenLine = """
    {"timestamp":"2026-09-15T10:00:00Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"total_tokens":180000},"model_context_window":258400}}}
    """

Verify:

- usedTokens is 180000 and windowTokens is 258400.
- The parser walks backward past an unfinished trailing line.
- It ignores total_token_usage for context capacity.
- It returns nil when model_context_window is missing or zero.
- A post-compaction marker followed by no distinct token_count returns nil.
- A new distinct token_count after compaction becomes live.

- [ ] **Step 3: Run focused tests and verify failure**

Run:

    swift test --filter SessionPathResolverTests
    swift test --filter ContextLogParserTests

Expected: FAIL because resolver and parser types do not exist.

- [ ] **Step 4: Implement safe bounded session resolution**

SessionPathResolver must:

- Accept only canonical UUID strings.
- Search sessions and archived_sessions under the supplied codexHome.
- Consider only rollout-*.jsonl regular files.
- Resolve standardized paths and reject any result outside codexHome.
- Inspect session_meta or history_base metadata when multiple segments match.
- Limit discovery to 128 matching candidates.
- Return a typed unavailable error rather than falling back inside the resolver.

- [ ] **Step 5: Implement bounded token parsing**

ContextLogParser must inspect at most the final 8 MiB, split complete lines, walk backward, and accept only:

    root.type == "event_msg"
    payload.type == "token_count"
    info.last_token_usage.total_tokens is numeric
    info.model_context_window is numeric and greater than zero

Clamp usedTokens at a minimum of zero. Detect contextCompaction items or legacy compact events in the bounded tail; do not publish a pre-compaction count until a distinct subsequent count exists.
Parse the event's ISO 8601 timestamp when valid. Use the supplied file modification date only when the event timestamp is absent or invalid.

- [ ] **Step 6: Implement the file monitor**

ContextLogMonitor must:

- Resolve a new path immediately when select(threadID:provenance:) changes.
- Use DispatchSourceFileSystemObject for writes, renames, and deletion.
- Debounce writes for 100 ms so a partial JSON line is not treated as final.
- Read only the bounded tail and publish on the main queue.
- Mark a snapshot stale when its event timestamp is older than 300 seconds.
- Stop its file descriptor and source when the selected task changes or Codex hides.

- [ ] **Step 7: Run tests and commit**

Run:

    swift test --filter SessionPathResolverTests
    swift test --filter ContextLogParserTests
    swift test

Expected: PASS.

    git add Sources/CodexUsageCore/SessionPathResolver.swift Sources/CodexUsageCore/ContextLogParser.swift Sources/CodexUsageCore/ContextLogMonitor.swift Tests/CodexUsageCoreTests
    git commit -m "feat: read selected task context usage"

---

### Task 5: Active Task IPC Routing

**Files:**
- Create: Sources/CodexUsageCore/ActiveThreadRouter.swift
- Create: Sources/CodexUsageCore/CodexIPCClient.swift
- Create: Tests/CodexUsageCoreTests/ActiveThreadRouterTests.swift
- Create: Tests/CodexUsageCoreTests/CodexIPCSecurityTests.swift

**Interfaces:**
- Produces: ActiveThreadStatus with threadID, activeWindowCount, connected, version, and error.
- Produces: ActiveThreadRouter.process(frame:) -> Bool and reset().
- Produces: CodexIPCClient.onStatus, start(), stop().
- Consumes: ContextLogMonitor.select(threadID:provenance:) from Task 4.

- [ ] **Step 1: Write failing router tests**

Cover:

- A thread-stream-following-changed frame with following true selects its conversationId.
- A later active window wins without destroying the older mapping.
- following false restores the previous still-active window.
- client-status-changed with disconnected removes only that client's windows.
- reset clears the route and increments version.
- Malformed and unrelated broadcasts do not mutate state.

Use frames with this exact shape:

    [
      "type": "broadcast",
      "method": "thread-stream-following-changed",
      "sourceClientId": "client-a",
      "params": [
        "conversationId": "11111111-1111-1111-1111-111111111111",
        "hostId": "local",
        "following": true
      ]
    ]

- [ ] **Step 2: Write failing socket-security tests**

Extract a pure validator:

    SocketSecurityValidator.validate(
        socketURL: URL,
        currentUserID: uid_t,
        attributes: SocketFileAttributes
    ) -> Bool

Verify it accepts a Unix socket owned by the current user in a safe directory and rejects a regular file, foreign owner, group-writable directory, or world-writable directory.

- [ ] **Step 3: Run focused tests and verify failure**

Run:

    swift test --filter ActiveThreadRouterTests
    swift test --filter CodexIPCSecurityTests

Expected: FAIL because IPC types do not exist.

- [ ] **Step 4: Implement router and validated IPC client**

Candidate socket order:

1. $CODEX_HOME/ipc/ipc.sock.
2. ~/.codex/ipc/ipc.sock.
3. $TMPDIR/codex-ipc/ipc.sock.
4. /tmp/codex-ipc/ipc.sock.

CodexIPCClient must:

- Validate each candidate before connecting with Network.framework.
- Decode the local broadcast frame as a four-byte little-endian UInt32 payload length followed by UTF-8 JSON, matching the audited reference implementation.
- Cap a wire frame at 256 MiB and a decoded JSON frame at 4 MiB.
- Publish a disconnected status and retry candidates with bounded backoff.
- Never create, delete, chmod, or replace a socket.
- Preserve the last selected thread only during a connected follow/unfollow transition; clear it on a true disconnect.

- [ ] **Step 5: Connect IPC status to the context monitor**

When status contains a thread ID:

    contextMonitor.select(threadID: id, provenance: .selectedThread)

When disconnected:

    contextMonitor.selectFallbackRootSession(provenance: .fallbackThread)

The fallback path must carry fallbackThread provenance through to the UI.

- [ ] **Step 6: Run tests and commit**

Run:

    swift test --filter ActiveThreadRouterTests
    swift test --filter CodexIPCSecurityTests
    swift test

Expected: PASS.

    git add Sources/CodexUsageCore/ActiveThreadRouter.swift Sources/CodexUsageCore/CodexIPCClient.swift Tests/CodexUsageCoreTests
    git commit -m "feat: follow the active Codex task"

---

### Task 6: Independent Snapshot Store and Staleness

**Files:**
- Create: Sources/CodexUsageCore/UsageStore.swift
- Create: Tests/CodexUsageCoreTests/UsageStoreTests.swift

**Interfaces:**
- Consumes: all Task 1 snapshot types.
- Produces: @MainActor UsageStore with updateAccount(_:), failAccount(_:), updateContext(_:), failContext(_:), snapshot, and onChange.

- [ ] **Step 1: Write failing state-transition tests**

Verify:

- Account updates do not erase a live context value.
- Context failures do not erase a live account value.
- A failure turns an existing value stale with its original timestamp.
- A failure with no prior value becomes unavailable.
- refreshStaleness(now:) marks values older than 300 seconds stale.
- A new live update replaces stale state.

Example:

    @MainActor
    func testContextFailurePreservesLiveAccount() {
        let store = UsageStore()
        store.updateAccount(sampleAccount)
        store.failContext("IPC unavailable")
        guard case .live = store.snapshot.account else {
            return XCTFail("account state was lost")
        }
        guard case .unavailable(let reason) = store.snapshot.context else {
            return XCTFail("context should be unavailable")
        }
        XCTAssertEqual(reason, "IPC unavailable")
    }

- [ ] **Step 2: Run tests and verify failure**

Run:

    swift test --filter UsageStoreTests

Expected: FAIL because UsageStore does not exist.

- [ ] **Step 3: Implement the MainActor store**

UsageStore publishes only when CombinedUsageSnapshot changes. It never mutates snapshot timestamps. Add:

    @MainActor
    public final class UsageStore {
        public private(set) var snapshot: CombinedUsageSnapshot
        public var onChange: ((CombinedUsageSnapshot) -> Void)?

        public func updateAccount(_ value: AccountUsageSnapshot)
        public func failAccount(_ reason: String)
        public func updateContext(_ value: ContextUsageSnapshot)
        public func failContext(_ reason: String)
        public func refreshStaleness(now: Date = Date())
    }

- [ ] **Step 4: Run tests and commit**

Run:

    swift test --filter UsageStoreTests
    swift test

Expected: PASS.

    git add Sources/CodexUsageCore/UsageStore.swift Tests/CodexUsageCoreTests/UsageStoreTests.swift
    git commit -m "feat: merge independent usage states"

---

### Task 7: Window Selection and Overlay Placement

**Files:**
- Create: Sources/CodexUsageCore/OverlayPlacement.swift
- Create: Sources/CodexUsageOverlay/CodexWindowTracker.swift
- Create: Tests/CodexUsageCoreTests/OverlayPlacementTests.swift

**Interfaces:**
- Produces: WindowCandidate and OverlayPlacement.frame(window:panelSize:offset:visibleFrame:) -> CGRect.
- Produces: CodexWindowTracker.onPlacementChange: ((CGRect?) -> Void)? and start()/stop().
- Consumes: OverlayPanelController.setTargetFrame(_:) in Task 8.

- [ ] **Step 1: Write failing pure placement tests**

Test a 1200 x 800 Codex window, a 250 x 30 capsule, a 12-point inset, and a visible screen frame. Verify the result sits inside the upper-right edge. Add cases for a window near the screen edge, a negative display origin, a user offset, and a panel wider than the available title area.

Also test main-window selection:

- Focused visible window wins.
- Windows smaller than 500 x 300 are ignored.
- Minimized and off-screen windows are ignored.
- A plausible standard-level window wins over a pet, popover, or utility window.

- [ ] **Step 2: Run focused tests and verify failure**

Run:

    swift test --filter OverlayPlacementTests

Expected: FAIL because placement types do not exist.

- [ ] **Step 3: Implement pure geometry**

Use CoreGraphics-only value types in CodexUsageCore. Clamp the frame to the selected window and visible screen frame. Preserve the configured x/y offset only when the resulting capsule remains fully visible.

- [ ] **Step 4: Implement the event-driven Codex window tracker**

Recognize current Codex/ChatGPT bundle identifiers, including com.openai.codex and com.openai.chatgpt. Use:

- NSWorkspace.didActivateApplicationNotification.
- NSWorkspace.didHideApplicationNotification.
- NSWorkspace.didUnhideApplicationNotification.
- NSWorkspace.didLaunchApplicationNotification.
- NSWorkspace.didTerminateApplicationNotification.
- NSWorkspace.activeSpaceDidChangeNotification.
- AX focused-window, created, destroyed, moved, resized, minimized, and restored notifications.

When Accessibility is not trusted, fall back to CGWindowListCopyWindowInfo and screen-relative upper-right placement. During a drag/resize event, use a timer no faster than 30 Hz for at most one second; stop polling when movement ends.

- [ ] **Step 5: Run tests and commit**

Run:

    swift test --filter OverlayPlacementTests
    swift test

Expected: PASS.

    git add Sources/CodexUsageCore/OverlayPlacement.swift Sources/CodexUsageOverlay/CodexWindowTracker.swift Tests/CodexUsageCoreTests/OverlayPlacementTests.swift
    git commit -m "feat: follow the active Codex window"

---

### Task 8: Compact and Expanded Overlay UI

**Files:**
- Create: Sources/CodexUsageOverlay/OverlayViews.swift
- Create: Sources/CodexUsageOverlay/OverlayPanelController.swift
- Create: Sources/CodexUsageOverlay/StatusItemController.swift
- Create: Tests/CodexUsageCoreTests/DisplayFormattingTests.swift
- Modify: Sources/CodexUsageCore/UsageModels.swift

**Interfaces:**
- Consumes: CombinedUsageSnapshot and CapacityColor from Tasks 1 and 6.
- Produces: DisplayFormatter.compactSegments(snapshot:now:) and detailRows(snapshot:now:).
- Produces: OverlayPanelController.render(_:), setTargetFrame(_:), show(), hide(), collapse().
- Produces: StatusItemController callbacks for refresh, offset adjustments, permission help, and quit.

- [ ] **Step 1: Write failing display-formatting tests**

Verify these exact behaviors:

- 300 minutes formats as 5h; 10,080 minutes formats as 周; other durations format without pretending they are 5h.
- 75.4 remaining formats as 75%.
- 78,400 tokens formats as 78.4k.
- Missing values format as —.
- Fallback context includes 可能非当前任务.
- A reset 90 minutes away formats as 1小时30分.
- Compact segments are omitted for an absent quota window, not rendered as 100%.
- Expanded details shorten a task UUID to its final eight characters.

- [ ] **Step 2: Run formatting tests and verify failure**

Run:

    swift test --filter DisplayFormattingTests

Expected: FAIL because DisplayFormatter does not exist.

- [ ] **Step 3: Implement deterministic display formatting**

Keep formatting pure and locale-stable for tests. The Chinese compact output for a complete snapshot must follow this order:

    5h 72% · 周 84% · 上下文 41%

Do not color the entire capsule from one metric. Give each segment its own NSColor derived from CapacityColor.

- [ ] **Step 4: Implement AppKit views**

Build programmatic AppKit views without storyboards:

- Compact capsule: NSVisualEffectView, horizontal stack, 12-point horizontal padding, 6-point vertical padding, rounded continuous corners.
- Expanded detail: maximum width 320 points, separate account and context sections, reset countdowns, stale/fallback labels, refresh and collapse controls.
- Support light/dark appearance through semantic colors.
- Make every control accessible with concise labels and values.

- [ ] **Step 5: Implement the non-activating panel controller**

Create NSPanel with borderless and nonactivatingPanel style masks. Set:

    panel.level = .floating
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.hidesOnDeactivate = false
    panel.isOpaque = false
    panel.backgroundColor = .clear

Order it front only while CodexWindowTracker supplies a target frame. Mouse interaction must not activate the companion application or steal focus from the Codex editor. Collapse on an outside click monitor and remove that monitor when hidden.

- [ ] **Step 6: Implement the menu-bar controller**

The status item menu contains:

- 显示/隐藏.
- 刷新.
- 位置偏移 submenu with 左移、右移、上移、下移 in eight-point steps and 重置位置.
- 辅助功能权限.
- 关于数据来源.
- 退出.

Persist only the x/y offset in UserDefaults. Do not persist account snapshots or thread IDs.

- [ ] **Step 7: Run tests and commit**

Run:

    swift test --filter DisplayFormattingTests
    swift test

Expected: PASS.

    git add Sources/CodexUsageCore/UsageModels.swift Sources/CodexUsageOverlay Tests/CodexUsageCoreTests/DisplayFormattingTests.swift
    git commit -m "feat: render Codex usage overlay"

---

### Task 9: Application Composition, Packaging, and Documentation

**Files:**
- Create: Sources/CodexUsageOverlay/AppDelegate.swift
- Modify: Sources/CodexUsageOverlay/main.swift
- Create: Resources/Info.plist
- Create: scripts/package_app.sh
- Create: scripts/install.sh
- Create: scripts/uninstall.sh
- Create: README.md
- Create: THIRD_PARTY_NOTICES.md
- Create: LICENSE

**Interfaces:**
- Consumes: every service and controller from Tasks 1 through 8.
- Produces: a launchable CodexUsageOverlay.app and documented local installation flow.

- [ ] **Step 1: Wire services in AppDelegate**

At launch:

1. Create UsageStore.
2. Connect AppServerClient callbacks to account store methods.
3. Connect CodexIPCClient status to ContextLogMonitor selection.
4. Connect ContextLogMonitor callbacks to context store methods.
5. Connect UsageStore.onChange to OverlayPanelController.render.
6. Connect CodexWindowTracker placement to panel visibility and App Server foreground activity.
7. Connect status-item refresh to both data services.
8. Start IPC and window tracking; start account refresh only when Codex is foreground.

At termination, stop every service, timer, file source, event monitor, and child process.

- [ ] **Step 2: Add application metadata**

Info.plist must set:

    CFBundleIdentifier = local.codex-usage-overlay
    CFBundleName = Codex Usage Overlay
    CFBundleDisplayName = Codex Usage Overlay
    CFBundleShortVersionString = 0.1.0
    CFBundleVersion = 1
    LSMinimumSystemVersion = 13.0
    LSUIElement = true

Include an English Accessibility usage explanation in README because macOS does not provide a dedicated Info.plist prompt string for AX trust.

- [ ] **Step 3: Add packaging and install scripts**

package_app.sh must:

- Run swift test.
- Run swift build -c release --arch arm64.
- Create dist/CodexUsageOverlay.app/Contents/MacOS and Resources.
- Copy the executable and Info.plist.
- Ad-hoc sign with codesign --force --deep --sign -.
- Verify with codesign --verify --deep --strict --verbose=2.

install.sh must copy the packaged app to ~/Applications/CodexUsageOverlay.app after checking the source and destination are explicit app paths. uninstall.sh must remove only that exact installed app and print that UserDefaults and Accessibility authorization are not removed automatically.

- [ ] **Step 4: Add licensing and user documentation**

LICENSE uses the MIT license for this project. THIRD_PARTY_NOTICES.md includes the complete MIT texts and copyright lines from:

- Copyright (c) 2026 Local developer — caisimai/codex-usage-overlay.
- Copyright (c) 2026 soleillevant0125 — codex-token-overlay.

README documents:

- What account quota and context remaining mean.
- macOS 13+ and Apple Silicon requirements.
- Build, install, open, grant Accessibility, update, and uninstall steps.
- The exact files and IPC metadata read.
- Why missing values display —.
- Why fallback context is labeled 可能非当前任务.
- How to diagnose missing Codex binary, App Server auth, IPC, session log, and Accessibility permission.
- The fact that the project is independent and not endorsed by OpenAI.

- [ ] **Step 5: Run the full automated and packaging verification**

Run:

    swift test
    ./scripts/package_app.sh
    codesign --verify --deep --strict --verbose=2 dist/CodexUsageOverlay.app
    test -x dist/CodexUsageOverlay.app/Contents/MacOS/CodexUsageOverlay

Expected: all tests PASS; package script exits 0; codesign verification exits 0; executable test exits 0.

- [ ] **Step 6: Commit the runnable application**

    git add Sources/CodexUsageOverlay Resources scripts README.md THIRD_PARTY_NOTICES.md LICENSE
    git commit -m "feat: package Codex usage overlay app"

---

### Task 10: Manual Integration Verification and Release Record

**Files:**
- Create: docs/verification/2026-09-15-local-verification.md
- Modify: README.md only if verification discovers a real setup caveat.

**Interfaces:**
- Consumes: the packaged app from Task 9.
- Produces: evidence for each manual acceptance criterion and an installable local artifact.

- [ ] **Step 1: Launch the packaged application without installing it**

Run:

    open dist/CodexUsageOverlay.app

Verify in Activity Monitor or ps that there is one companion process and at most one child codex app-server process.

- [ ] **Step 2: Verify account display against a fresh read**

Use the companion refresh command and compare the displayed remaining values with a fresh local App Server read. Record the short-window duration, weekly duration, reset timestamps, and whether the UI correctly calculates 100 - usedPercent. Do not record account identifiers or raw responses.

- [ ] **Step 3: Verify current-task context switching**

Open two existing Codex tasks with completed turns. Switch between them and confirm the task ID suffix and context percentage update to each task's latest token_count snapshot. Complete one new turn and confirm the context updates without restarting the companion.

- [ ] **Step 4: Verify window lifecycle**

Check and record:

- Moving and resizing the Codex window.
- Minimizing and restoring it.
- Switching to another application.
- Switching Spaces.
- Moving Codex between displays when another display is available.
- Closing one of multiple Codex windows.

Expected: the overlay remains attached to the active Codex main window and is hidden everywhere else.

- [ ] **Step 5: Verify failure states**

Temporarily test each reversible state, restoring it immediately afterward:

- Stop the companion's App Server child and confirm reconnect with stale quota labeling.
- Start with IPC unavailable and confirm 可能非当前任务.
- Select a task without a completed response and confirm context —.
- Deny Accessibility and confirm conservative placement plus permission help.

Do not edit auth.json, Codex session logs, or Codex application files.

- [ ] **Step 6: Record evidence and rerun automated checks**

The verification document must list the host macOS version, architecture, Swift version, Codex binary path, commands run, exit codes, manual cases, and any limitation actually observed. It must not include account identifiers, task UUIDs, or raw session contents.

Run:

    swift test
    ./scripts/package_app.sh
    git status --short

Expected: tests and packaging PASS. git status lists only the new verification document or an intentional README correction.

- [ ] **Step 7: Commit verification evidence**

    git add docs/verification/2026-09-15-local-verification.md README.md
    git commit -m "test: verify Codex overlay integration"

---

## Completion Criteria

- The compact overlay displays available account windows and selected-task context as remaining values.
- It follows the active Codex main window and hides when Codex loses foreground.
- It does not steal keyboard focus from Codex.
- Account, IPC, context, and Accessibility failures degrade independently and honestly.
- No credentials or message content are read, logged, or persisted.
- All XCTest suites pass.
- The Apple Silicon app package builds and passes ad-hoc signature verification.
- Manual verification evidence covers task switching and window lifecycle behavior.
- The repository retains required third-party MIT notices.
