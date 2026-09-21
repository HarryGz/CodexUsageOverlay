# Account Freshness Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent routine foreground transitions and transient account-read errors from producing misleading `已过期` labels.

**Architecture:** Keep the existing App Server process, 180-second timer, and 300-second freshness boundary. Add one edge-triggered refresh on the background-to-foreground transition, and make `UsageStore.failAccount` preserve a still-fresh snapshot until the existing age policy marks it stale.

**Tech Stack:** Swift 5.9, Foundation `Process`/`DispatchSourceTimer`, XCTest synthetic App Server fixtures.

**Spec:** `docs/superpowers/specs/2026-09-21-account-freshness-recovery-design.md`

## Global Constraints

- Target macOS 13 or later with no new dependencies.
- Keep account requests read-only: `account/read` and `account/rateLimits/read` only.
- Keep the periodic refresh interval at 180 seconds and the stale boundary at 300 seconds.
- Add no background polling, independent network client, credential reads, or persistence.
- Do not change context failure or strict context-display behavior.

## Review Focus

- Initial startup must not duplicate the post-initialize account requests.
- Repeated `setForegroundActive(true)` calls must not refresh repeatedly during window movement.
- A background-to-foreground transition before initialization must rely on the normal post-initialize requests.
- A recent account snapshot must remain live after one failure, but still become stale when its real age exceeds 300 seconds.
- Missing account data and context failures must retain their existing unavailable/stale behavior.

---

### Task 1: Refresh Account Quota on Foreground Entry

**Files:**
- Modify: `Sources/CodexUsageCore/AppServerClient.swift:85-89`
- Test: `Tests/CodexUsageCoreTests/AppServerClientTests.swift`

**Interfaces:**
- Consumes: `AppServerClient.setForegroundActive(_:)`, `sendReadOnlyAccountRequests()`, and the existing synthetic App Server fixture.
- Produces: Edge-triggered immediate refresh when `foregroundActive` changes from `false` to `true` after initialization.

- [ ] **Step 1: Write the failing resume test**

Add `testForegroundResumeRefreshesImmediatelyWithoutWaitingForPeriodicTimer`. Use a synthetic server that completes initialization and the first account reads, then waits for a second `account/read` and `account/rateLimits/read` pair. Construct the client with `refreshInterval: 60`, enter foreground, start it, wait for the initial sequence, transition false then true, and require the second pair within one second.

```swift
func testForegroundResumeRefreshesImmediatelyWithoutWaitingForPeriodicTimer() throws {
    let fixture = try SyntheticAppServer(script: """
    read line || exit 2
    printf '{"id":1,"result":{}}\\n'
    for method in initialized account/read account/rateLimits/read; do read line || exit 3; done
    echo initial-ready >> __FIXTURE_EVENTS__
    for method in account/read account/rateLimits/read; do read line || exit 4; done
    echo resumed-ready >> __FIXTURE_EVENTS__
    while read line; do :; done
    """)
    let client = AppServerClient(binaryResolver: { fixture.executable.path }, refreshInterval: 60)
    defer { client.stop() }
    client.setForegroundActive(true)
    client.start()
    XCTAssertTrue(waitUntil(timeout: 1) { fixture.events.contains("initial-ready") })
    client.setForegroundActive(false)
    client.setForegroundActive(true)
    XCTAssertTrue(waitUntil(timeout: 1) { fixture.events.contains("resumed-ready") })
}
```

- [ ] **Step 2: Run the resume test and verify RED**

Run: `PATH=/tmp/codex-usage-overlay-tools:$PATH swift test --disable-sandbox --filter AppServerClientTests/testForegroundResumeRefreshesImmediatelyWithoutWaitingForPeriodicTimer`

Expected: FAIL by timeout because the current implementation schedules the next read 60 seconds later.

- [ ] **Step 3: Implement edge-triggered foreground refresh**

Update `setForegroundActive(_:)` to capture `becameActive = active && !foregroundActive`, store the new state, and call `sendReadOnlyAccountRequests()` only when `becameActive && initialized`, before configuring the existing timer.

```swift
public func setForegroundActive(_ active: Bool) {
    queue.async {
        let becameActive = active && !self.foregroundActive
        self.foregroundActive = active
        if becameActive, self.initialized { self.sendReadOnlyAccountRequests() }
        self.configureRefreshTimer()
    }
}
```

- [ ] **Step 4: Add the duplicate-notification regression test**

Add `testRepeatedForegroundTrueDoesNotSendDuplicateImmediateRefresh`. After one successful resume refresh, call `setForegroundActive(true)` again and use an inverted expectation to prove no third request pair arrives before the long periodic interval.

```swift
func testRepeatedForegroundTrueDoesNotSendDuplicateImmediateRefresh() throws {
    let fixture = try SyntheticAppServer(script: """
    read line || exit 2
    printf '{"id":1,"result":{}}\\n'
    for method in initialized account/read account/rateLimits/read; do read line || exit 3; done
    echo initial-ready >> __FIXTURE_EVENTS__
    for method in account/read account/rateLimits/read; do read line || exit 4; done
    echo resumed-ready >> __FIXTURE_EVENTS__
    if read line; then echo unexpected-request >> __FIXTURE_EVENTS__; fi
    """)
    let client = AppServerClient(binaryResolver: { fixture.executable.path }, refreshInterval: 60)
    defer { client.stop() }
    client.setForegroundActive(true)
    client.start()
    XCTAssertTrue(waitUntil(timeout: 1) { fixture.events.contains("initial-ready") })
    client.setForegroundActive(false)
    client.setForegroundActive(true)
    XCTAssertTrue(waitUntil(timeout: 1) { fixture.events.contains("resumed-ready") })
    client.setForegroundActive(true)
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
    XCTAssertFalse(fixture.events.contains("unexpected-request"))
}
```

- [ ] **Step 5: Run App Server client tests and verify GREEN**

Run: `PATH=/tmp/codex-usage-overlay-tools:$PATH swift test --disable-sandbox --filter AppServerClientTests`

Expected: all App Server client tests pass with no unexpected failures.

- [ ] **Step 6: Commit Task 1**

```bash
git add Sources/CodexUsageCore/AppServerClient.swift Tests/CodexUsageCoreTests/AppServerClientTests.swift
git commit -m "fix: refresh quota on foreground resume"
```

### Task 2: Let Snapshot Age Govern Transient Account Failures

**Files:**
- Modify: `Sources/CodexUsageCore/UsageStore.swift:20-22`
- Test: `Tests/CodexUsageCoreTests/UsageStoreTests.swift`

**Interfaces:**
- Consumes: `AccountUsageSnapshot.updatedAt` and the existing 300-second stale boundary.
- Produces: `failAccount(_:, now:)` that keeps a recent account snapshot live and preserves existing behavior for expired, stale, or unavailable states.

- [ ] **Step 1: Write the failing recent-failure test**

Add `testRecentAccountFailureKeepsSnapshotLiveUntilAgeThreshold`. Store an account snapshot updated at time 100, call `failAccount("temporary", now: 400)`, and assert the account state remains `.live` with the same value at the inclusive 300-second boundary.

```swift
func testRecentAccountFailureKeepsSnapshotLiveUntilAgeThreshold() {
    let store = UsageStore()
    store.updateAccount(account)
    store.failAccount("temporary", now: Date(timeIntervalSince1970: 400))
    guard case .live(let value) = store.snapshot.account else {
        return XCTFail("recent account snapshot should stay live")
    }
    XCTAssertEqual(value, account)
}
```

- [ ] **Step 2: Run the recent-failure test and verify RED**

Run: `PATH=/tmp/codex-usage-overlay-tools:$PATH swift test --disable-sandbox --filter UsageStoreTests/testRecentAccountFailureKeepsSnapshotLiveUntilAgeThreshold`

Expected: FAIL because the current implementation immediately converts every live snapshot to `.stale`.

- [ ] **Step 3: Implement age-aware account failure handling**

Change the public signature to `failAccount(_ reason: String, now: Date = Date())`. For `.live`, preserve the state when `now - updatedAt <= 300`; otherwise return `.stale` with the error reason. Preserve `.stale` as stale with the latest reason and `.unavailable` as unavailable. Leave `failContext` on the existing generic failure path.

```swift
public func failAccount(_ reason: String, now: Date = Date()) {
    let next: UsageValueState<AccountUsageSnapshot>
    switch snapshot.account {
    case .live(let value) where now.timeIntervalSince(value.updatedAt) <= 300:
        next = .live(value)
    case .live(let value), .stale(let value, _):
        next = .stale(value, reason: reason)
    case .unavailable:
        next = .unavailable(reason: reason)
    }
    replace(CombinedUsageSnapshot(account: next, context: snapshot.context))
}
```

- [ ] **Step 4: Add expired and missing-state regression coverage**

Add `testExpiredAccountFailureMarksSnapshotStale` using time 401 and `testAccountFailureWithoutPriorValueRemainsUnavailable`. Assert the stale reason and unavailable reason respectively.

```swift
func testExpiredAccountFailureMarksSnapshotStale() {
    let store = UsageStore()
    store.updateAccount(account)
    store.failAccount("temporary", now: Date(timeIntervalSince1970: 401))
    guard case .stale(let value, let reason) = store.snapshot.account else {
        return XCTFail("expired account snapshot should be stale")
    }
    XCTAssertEqual(value, account)
    XCTAssertEqual(reason, "temporary")
}

func testAccountFailureWithoutPriorValueRemainsUnavailable() {
    let store = UsageStore()
    store.failAccount("temporary", now: Date(timeIntervalSince1970: 100))
    guard case .unavailable(let reason) = store.snapshot.account else {
        return XCTFail("missing account snapshot should remain unavailable")
    }
    XCTAssertEqual(reason, "temporary")
}
```

- [ ] **Step 5: Run store tests and verify GREEN**

Run: `PATH=/tmp/codex-usage-overlay-tools:$PATH swift test --disable-sandbox --filter UsageStoreTests`

Expected: all Usage Store tests pass with no unexpected failures.

- [ ] **Step 6: Run the complete suite**

Run: `PATH=/tmp/codex-usage-overlay-tools:$PATH swift test --disable-sandbox`

Expected: all tests pass with zero failures.

- [ ] **Step 7: Commit Task 2**

```bash
git add Sources/CodexUsageCore/UsageStore.swift Tests/CodexUsageCoreTests/UsageStoreTests.swift docs/superpowers/specs/2026-09-21-account-freshness-recovery-design.md docs/superpowers/plans/2026-09-21-account-freshness-recovery.md
git commit -m "fix: keep recent quota snapshot fresh"
```

### Task 3: Review, Package, Install, and Verify

**Files:**
- Verify: all branch changes since `0214ccc`
- Build artifact: `dist/CodexUsageOverlay.app`
- Install artifact: `/Users/harry/Applications/CodexUsageOverlay.app`

**Interfaces:**
- Consumes: Task 1 foreground refresh and Task 2 age-aware failure behavior.
- Produces: Reviewed commit range, updated PR branch, signed installed app, and live evidence that foreground return refreshes account quota without manual interaction.

- [ ] **Step 1: Generate a whole-branch review package and request independent review**

Run the executing-plans review workflow for `0214ccc..HEAD`. Resolve any Critical or Important finding with a new RED-GREEN test; record Minor findings without expanding scope.

- [ ] **Step 2: Package and verify the app**

Run: `PATH=/tmp/codex-usage-overlay-tools:$PATH scripts/package_app.sh`

Expected: all tests pass, the release build succeeds, and `codesign --verify --deep --strict dist/CodexUsageOverlay.app` succeeds.

- [ ] **Step 3: Push the existing PR branch**

Run: `git push origin fix/restore-auto-refresh`

Expected: `origin/fix/restore-auto-refresh` advances to the verified head commit.

- [ ] **Step 4: Install and restart**

Replace `/Users/harry/Applications/CodexUsageOverlay.app` with the verified package, preserving a recoverable backup, then restart the app.

- [ ] **Step 5: Verify live foreground recovery**

Confirm the installed process maps `/Users/harry/Applications/CodexUsageOverlay.app/Contents/MacOS/CodexUsageOverlay`, the compact UI shows current account quota without `已过期`, and returning to Codex triggers a new successful update without pressing Refresh.

- [ ] **Step 6: Record final verification**

Run: `git diff --check && git status --short --branch`

Expected: no whitespace errors; branch is clean and synchronized with its remote after the push.
