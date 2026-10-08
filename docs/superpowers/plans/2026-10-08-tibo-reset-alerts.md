# Tibo Reset Alerts Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add low-frequency Tibo reset-message monitoring with macOS notifications, an unread overlay badge, retained details, and staged X author confirmation.

**Architecture:** New pure Core models, parsing, persistence, networking, verification, and coordination components keep external data and trust decisions out of AppKit views. The executable target supplies the `UNUserNotificationCenter` adapter and wires the coordinator into the existing overlay lifecycle; one five-minute feed loop runs independently of Codex foreground state, while UI reveal remains deferred until Codex returns to the foreground.

**Tech Stack:** Swift 5.9, Foundation/URLSession, AppKit, UserNotifications, XCTest, Swift Package Manager; no third-party packages.

**Spec:** `docs/superpowers/specs/2026-10-08-tibo-reset-alerts-design.md`

## Global Constraints

- Support macOS 13 or later on Apple Silicon and preserve the existing Swift 5.9 package floor.
- Use only Apple frameworks and Swift Package Manager; add no third-party package dependency.
- Poll `https://codex-reset.com/api/feed?locale=zh` every 300 seconds while the overlay process runs, independent of Codex foreground state, and enforce the same 300-second minimum spacing across timer, manual, and wake triggers.
- Verify each new structurally valid post through `https://publish.x.com/oembed`; never request an X login or API token and never render returned embed HTML.
- Allow outbound HTTPS requests only to `codex-reset.com` and `publish.x.com`; reject redirects to other hosts.
- Treat public announcements as informational; the local Codex App Server remains authoritative for the signed-in account's quota.
- Never send or persist Codex account data, quota snapshots, task identifiers, session content, raw feed bodies, or embed HTML.
- Persist only the approved alert metadata in the existing `local.codex-usage-overlay` UserDefaults domain and retain at most 32 seen message IDs.
- Show linked `Data: codex-reset.com` attribution wherever a feed-derived message appears.
- Do not start the overlay at login, activate Codex, or show an extra panel when a notification is selected.

## Review Focus

- A syntactically valid but oversized, stale, future-dated, wrong-profile, or wrong-host feed must not advance seen state or notify; Task 1 pins every rejection.
- Feed reordering, translation changes, engagement changes, and process restart must not replay an existing ID; Task 2 pins persistence and 32-ID deduplication.
- A wake, timer fire, and manual refresh arriving together must coalesce into one network request and one candidate delivery; Task 3 pins concurrent-trigger behavior.
- An oEmbed result for an older message arriving after a newer message must not confirm, reject, or remove the newer alert; Task 4 pins ID-scoped completion and retry cancellation.
- Selecting a notification while Codex is hidden must defer exactly one reveal and clear unread only after the normal overlay is actually shown; Tasks 4–6 pin callback, store, and panel integration behavior.

---

## File Structure

### New Core files

- `Sources/CodexUsageCore/TiboAlertModels.swift` — normalized messages, verification/health state, persisted alert record, and display-neutral notification request types.
- `Sources/CodexUsageCore/TiboFeedParser.swift` — bounded JSON parsing, source validation, canonical URL reconstruction, and deterministic message classification.
- `Sources/CodexUsageCore/TiboAlertStore.swift` — MainActor state machine, UserDefaults persistence, seen-ID ring, unread state, and pending reveal.
- `Sources/CodexUsageCore/TiboHTTPTransport.swift` — allowlisted URLSession transport and response envelope.
- `Sources/CodexUsageCore/TiboFeedClient.swift` — immediate/five-minute/wake/manual scheduling, request coalescing, cache validators, and feed-result publication.
- `Sources/CodexUsageCore/TiboSourceVerifier.swift` — X oEmbed request construction and identity/status-ID comparison.
- `Sources/CodexUsageCore/TiboAlertCoordinator.swift` — first-run permission, pending notification, confirmation/rejection, and bounded verification retries.
- `Sources/CodexUsageCore/TiboDisplayFormatter.swift` — pure compact/detail presentation models and notification copy.

### New executable file

- `Sources/CodexUsageOverlay/TiboNotificationController.swift` — `UNUserNotificationCenter` adapter and notification-selection callback.

### New tests

- `Tests/CodexUsageCoreTests/TiboFeedParserTests.swift`
- `Tests/CodexUsageCoreTests/TiboAlertStoreTests.swift`
- `Tests/CodexUsageCoreTests/TiboFeedClientTests.swift`
- `Tests/CodexUsageCoreTests/TiboSourceVerifierTests.swift`
- `Tests/CodexUsageCoreTests/TiboAlertCoordinatorTests.swift`
- `Tests/CodexUsageCoreTests/TiboDisplayFormatterTests.swift`

### Existing files modified

- `Sources/CodexUsageOverlay/AppDelegate.swift` — construct, start, stop, refresh, wake, reveal, and open-link wiring.
- `Sources/CodexUsageOverlay/OverlayPanelController.swift` — hold Tibo snapshot, expose deferred reveal, and emit read/open actions.
- `Sources/CodexUsageOverlay/OverlayViews.swift` — unread dot and Tibo details section.
- `Sources/CodexUsageOverlay/StatusItemController.swift` — notification-permission help entry.
- `Sources/CodexUsageCore/AppServerClient.swift` and `Tests/CodexUsageCoreTests/AppServerClientTests.swift` — release client version bump only.
- `Resources/Info.plist` — release version `0.2.0` / build `2`.
- `README.md` and `THIRD_PARTY_NOTICES.md` — source, attribution, network, persistence, notification, and troubleshooting disclosure.

---

### Task 1: Normalized Models and Feed Parser

**Files:**
- Create: `Sources/CodexUsageCore/TiboAlertModels.swift`
- Create: `Sources/CodexUsageCore/TiboFeedParser.swift`
- Create: `Tests/CodexUsageCoreTests/TiboFeedParserTests.swift`

**Interfaces:**
- Produces: `TiboMessageCategory`, `TiboVerificationState`, `TiboMessage`, `TiboAlertRecord`, `TiboFeedHealth`, `TiboAlertSnapshot`, `TiboFeedResult`, `TiboFeedParserError`, and `TiboFeedParser.parse(data:now:)`.
- `TiboMessage` is `Codable`, `Equatable`, and `Sendable` with `id`, `category`, `localizedSummary`, `publishedAt`, and reconstructed `canonicalURL`.
- `TiboFeedResult` exposes `fetchedAt`, `health`, and `newestQualifyingMessage`.
- Consumes: Foundation only; no network or persistence.

- [ ] **Step 1: Write parser source/freshness rejection tests**

Add tests named `testRejectsWrongSourceScopeOrProfile`, `testRejectsStaleOrOlderThanFifteenMinutes`, `testRejectsFutureDatedAndNonCanonicalPost`, and `testRejectsResponseOverOneMiB`. Assert each throws the matching `TiboFeedParserError` and returns no candidate state.

- [ ] **Step 2: Write category and false-positive tests**

Add table-driven fixtures for:

- future reset plan → `.resetAnnouncement`;
- reset processed/propagated → `.resetCompleted`;
- banked grant/arrival → `.bankedReset`;
- `Over the next 28 days ... improvement ... or ... full reset` → `.strongHint`;
- ordinary feature post, unrelated reply, probability/cadence update, and monitoring-account observation without a Tibo post → no message.

Assert category, numeric ID, bounded Chinese summary, exact Beijing-independent `Date`, and canonical `https://x.com/thsottiaux/status/<id>` URL.

- [ ] **Step 3: Run the focused tests to verify RED**

Run: `swift test --filter TiboFeedParserTests`

Expected: FAIL because the models and parser do not exist.

- [ ] **Step 4: Add the domain models**

Implement the named types in `TiboAlertModels.swift`. Pin limits as constants: response body `1_048_576` bytes, summary `500` Unicode scalars and six lines, status ID `1...32` decimal digits, feed age `0...900` seconds, and publication future tolerance `300` seconds.

- [ ] **Step 5: Implement `TiboFeedParser.parse(data:now:)`**

Decode only required fields. Require `source == "x-api"`, `source_scope == "timeline"`, `profile.handle == "thsottiaux"`, `stale == false`, and a fresh `fetched_at`. Prefer structured event/tweet fields; use bounded deterministic text rules only when structured fields do not assign one of the four categories. Reconstruct rather than trust the canonical URL.

- [ ] **Step 6: Run the focused tests to verify GREEN**

Run: `swift test --filter TiboFeedParserTests`

Expected: all parser tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/CodexUsageCore/TiboAlertModels.swift Sources/CodexUsageCore/TiboFeedParser.swift Tests/CodexUsageCoreTests/TiboFeedParserTests.swift
git commit -m "feat: parse trusted Tibo reset messages"
```

---

### Task 2: Persistent Alert State and Deduplication

**Files:**
- Create: `Sources/CodexUsageCore/TiboAlertStore.swift`
- Create: `Tests/CodexUsageCoreTests/TiboAlertStoreTests.swift`

**Interfaces:**
- Consumes: Task 1's `TiboMessage`, `TiboAlertRecord`, `TiboVerificationState`, `TiboFeedHealth`, and `TiboAlertSnapshot`.
- Produces: `@MainActor public final class TiboAlertStore` with `init(defaults:)`, read-only `snapshot`, `onChange`, `accept(_:checkedAt:) -> Bool`, `updateHealth(_:)`, `markConfirmed(id:)`, `markAnomalous(id:at:)`, `markRead()`, `requestReveal(id:)`, `consumePendingReveal(for:) -> Bool`, and `setNotificationPermissionRequested()`.
- `accept` returns `true` only after a new ID and its seen-state have been synchronously persisted.

- [ ] **Step 1: Write first-acceptance, persistence, and replay tests**

Use a unique `UserDefaults(suiteName:)` per test. Assert the first message becomes pending, unread, and seen before `accept` returns; reconstructing the store preserves it; accepting the same ID after restart returns `false` and does not change unread state.

- [ ] **Step 2: Write the 32-ID ring and mutation-isolation tests**

Assert 33 accepted IDs retain only the newest 32; a reordered old ID, changed translation, or changed engagement data cannot notify again; corrupt persisted Tibo data is discarded without reading or deleting unrelated offset keys.

- [ ] **Step 3: Write verification and reveal transition tests**

Assert confirmation mutates only the matching ID; anomaly clears content/URL but retains safe ID/time; stale completion for an older ID is ignored; `requestReveal` persists; `consumePendingReveal` consumes once; `markRead` clears unread only when called.

- [ ] **Step 4: Run the focused tests to verify RED**

Run: `swift test --filter TiboAlertStoreTests`

Expected: FAIL because `TiboAlertStore` does not exist.

- [ ] **Step 5: Implement `TiboAlertStore` and private Codable persistence**

Persist one versioned `Data` value under a Tibo-specific key plus the permission-request flag. Validate every decoded field before publishing it. Keep all mutations on MainActor and fire `onChange` only when `snapshot` changes.

- [ ] **Step 6: Run the focused tests to verify GREEN**

Run: `swift test --filter TiboAlertStoreTests`

Expected: all store tests pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/CodexUsageCore/TiboAlertStore.swift Tests/CodexUsageCoreTests/TiboAlertStoreTests.swift
git commit -m "feat: persist Tibo alert state"
```

---

### Task 3: Restricted HTTP Transport and Five-minute Feed Client

**Files:**
- Create: `Sources/CodexUsageCore/TiboHTTPTransport.swift`
- Create: `Sources/CodexUsageCore/TiboFeedClient.swift`
- Create: `Tests/CodexUsageCoreTests/TiboFeedClientTests.swift`

**Interfaces:**
- Consumes: `TiboFeedParser.parse(data:now:)` and `TiboFeedResult` from Task 1.
- Produces: `TiboHTTPResponse`, `TiboHTTPTransport`, `TiboURLSessionTransport`, `TiboFeedServing`, `TiboFeedClientError`, and `TiboFeedClient`.
- `TiboHTTPTransport.response(for:) async throws -> TiboHTTPResponse` returns status, final URL, lowercased headers, and body.
- `TiboFeedServing` exposes settable `onResult: ((Result<TiboFeedResult, TiboFeedClientError>) -> Void)?`, `start()`, `stop()`, `refreshNow()`, and `handleWake()`; `TiboFeedClient` conforms.
- `TiboFeedClient`'s public initializer uses interval/minimum spacing `300`; an internal initializer injects transport, clock, and async sleeper for tests.

- [ ] **Step 1: Write request-contract and response tests**

Assert the exact feed URL, `Accept: application/json`, project-identifying `User-Agent`, conditional `If-None-Match`/`If-Modified-Since`, 304 no-change behavior, parser publication for 200, one-MiB limit, and rejection of non-HTTPS or non-allowlisted final URLs.

- [ ] **Step 2: Write scheduling and lifecycle tests**

Assert `start()` performs one immediate read, then 300-second reads; `stop()` cancels future work; timer/manual/wake triggers inside the 300-second minimum spacing do not issue a request; a due wake performs one read and restarts the interval; sleep does not replay missed ticks; callbacks arrive on main.

- [ ] **Step 3: Add the Review Focus concurrency test**

Hold a fake transport request open, invoke timer/wake/manual triggers, then finish it. Assert only one transport call ran and only one `TiboFeedResult` was published; one queued refresh may run afterward, never three concurrent requests.

- [ ] **Step 4: Run the focused tests to verify RED**

Run: `swift test --filter TiboFeedClientTests`

Expected: FAIL because the transport and client do not exist.

- [ ] **Step 5: Implement the restricted transport**

Use an ephemeral/default-cache `URLSession` with a delegate that cancels redirects outside the two approved hosts. Do not add cookies or credentials. Return a response envelope and let callers enforce endpoint-specific limits.

- [ ] **Step 6: Implement `TiboFeedClient`**

Use one owned asynchronous loop/task, explicit cancellation, and an in-flight/coalesced-refresh flag. Preserve and emit cache validators without treating 304 as an error. Convert all transport/parser failures into typed errors without advancing candidate state.

- [ ] **Step 7: Run the focused tests to verify GREEN**

Run: `swift test --filter TiboFeedClientTests`

Expected: all feed-client tests pass.

- [ ] **Step 8: Commit**

```bash
git add Sources/CodexUsageCore/TiboHTTPTransport.swift Sources/CodexUsageCore/TiboFeedClient.swift Tests/CodexUsageCoreTests/TiboFeedClientTests.swift
git commit -m "feat: poll Tibo feed safely"
```

---

### Task 4: X Verification and Alert Coordination

**Files:**
- Create: `Sources/CodexUsageCore/TiboSourceVerifier.swift`
- Create: `Sources/CodexUsageCore/TiboAlertCoordinator.swift`
- Create: `Tests/CodexUsageCoreTests/TiboSourceVerifierTests.swift`
- Create: `Tests/CodexUsageCoreTests/TiboAlertCoordinatorTests.swift`

**Interfaces:**
- Consumes: Tasks 1–3 models, store, transport, and feed client.
- Produces: `TiboVerificationResult`, `TiboSourceVerifying`, `TiboSourceVerifier`, `TiboNotificationRequest`, `@MainActor TiboNotificationSending`, and `@MainActor TiboAlertCoordinator`.
- `TiboSourceVerifying.verify(_:) async -> TiboVerificationResult` returns `.confirmed`, `.transientFailure`, or `.anomalous` for the exact message ID; `TiboSourceVerifier` conforms.
- `TiboNotificationSending` exposes settable `onSelection: ((String) -> Void)?`, `requestAuthorization() async -> Bool`, `deliver(_:) async`, and `removeDelivered(id:)`.
- `TiboAlertCoordinator` provides `start()`, `stop()`, `refreshNow()`, and `handleWake()` and owns the 15-minute, one-hour, then six-hour confirmation retry sequence.

- [ ] **Step 1: Write oEmbed request and identity tests**

Assert the exact `publish.x.com/oembed` request with `omit_script=true`; a valid response requires provider `X`, author name `Tibo`, normalized author URL `https://x.com/thsottiaux`, and matching numeric status ID. Assert returned HTML is ignored. Test mismatched author/ID/provider as anomalous and timeout/429/5xx as transient.

- [ ] **Step 2: Run verifier tests to verify RED**

Run: `swift test --filter TiboSourceVerifierTests`

Expected: FAIL because the verifier does not exist.

- [ ] **Step 3: Implement `TiboSourceVerifier`**

Build the oEmbed URL from the reconstructed canonical post URL, use the restricted transport, cap the response at `262_144` bytes, and parse only `provider_name`, `author_name`, `author_url`, and `url`.

- [ ] **Step 4: Run verifier tests to verify GREEN**

Run: `swift test --filter TiboSourceVerifierTests`

Expected: all verifier tests pass.

- [ ] **Step 5: Write coordinator notification-state tests**

With fake feed client, verifier, notifier, sleeper, and isolated store, assert:

- first fresh qualifying item is persisted before one pending notification;
- permission is requested only once across store reconstruction;
- confirmation updates state without a second notification;
- transient confirmation keeps pending and retries at `900`, `3_600`, then `21_600` seconds;
- anomaly removes the delivered notification and hides content;
- denied authorization does not stop polling/store updates;
- selecting a notification calls `requestReveal(id:)` but does not mark read;
- an old verification completion after a newer alert is ignored and cannot remove or confirm the new alert.

- [ ] **Step 6: Run coordinator tests to verify RED**

Run: `swift test --filter TiboAlertCoordinatorTests`

Expected: FAIL because the coordinator and notification protocol do not exist.

- [ ] **Step 7: Implement `TiboAlertCoordinator`**

Keep orchestration on MainActor. Start permission and feed work once, cancel feed/retry work synchronously on stop, use message IDs to scope every async completion, and build pending notification copy that explicitly says `尚未经 X 二次确认` and never claims personal quota delivery.

- [ ] **Step 8: Run coordinator tests to verify GREEN**

Run: `swift test --filter 'Tibo(AlertCoordinator|SourceVerifier)Tests'`

Expected: both suites pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/CodexUsageCore/TiboSourceVerifier.swift Sources/CodexUsageCore/TiboAlertCoordinator.swift Tests/CodexUsageCoreTests/TiboSourceVerifierTests.swift Tests/CodexUsageCoreTests/TiboAlertCoordinatorTests.swift
git commit -m "feat: verify and coordinate Tibo alerts"
```

---

### Task 5: Display Models, Badge, and Expanded Details

**Files:**
- Create: `Sources/CodexUsageCore/TiboDisplayFormatter.swift`
- Create: `Tests/CodexUsageCoreTests/TiboDisplayFormatterTests.swift`
- Modify: `Sources/CodexUsageOverlay/OverlayViews.swift`
- Modify: `Sources/CodexUsageOverlay/OverlayPanelController.swift`

**Interfaces:**
- Consumes: Task 2's `TiboAlertSnapshot` and Task 1's category/verification models.
- Produces: `TiboDetailPresentation`, `TiboDisplayFormatter.detail(snapshot:now:timeZone:)`, `OverlayPanelController.renderTibo(_:)`, `revealTiboDetails() -> Bool`, `onTiboPresented`, and `onOpenTiboPost`.
- `revealTiboDetails()` returns `false` without mutating read state when the normal Codex placement is hidden; it returns `true` only after expanded Tibo content is visible.

- [ ] **Step 1: Write presentation-format tests**

Assert Chinese category labels, `Asia/Shanghai` time, the three exact verification labels, stale/unavailable health text, attribution label/URL, and omission of summary/link for anomalous records. Assert pending text never claims the account itself was reset.

- [ ] **Step 2: Run formatter tests to verify RED**

Run: `swift test --filter TiboDisplayFormatterTests`

Expected: FAIL because the formatter does not exist.

- [ ] **Step 3: Implement `TiboDisplayFormatter`**

Return display-only values; keep URL validation in the parser/verifier. Use the fixed `Asia/Shanghai` zone for publication time and local/current time only for existing quota rows.

- [ ] **Step 4: Run formatter tests to verify GREEN**

Run: `swift test --filter TiboDisplayFormatterTests`

Expected: all formatter tests pass.

- [ ] **Step 5: Add the compact unread badge**

Update `CompactOverlayView` to accept `showsUnreadTibo`. Draw a six-point dot as an overlay that does not participate in stack sizing, append `有未读 Tibo 动态` to accessibility value, and keep existing quota text/order unchanged.

- [ ] **Step 6: Add expanded Tibo details**

Update `ExpandedOverlayView` to accept an optional `TiboDetailPresentation` and an open-link callback. Render textual category/verification state, bounded summary, time, `查看原帖`, and linked attribution. Do not create a web view or render feed/embed markup.

- [ ] **Step 7: Add panel state and reveal semantics**

Store the Tibo snapshot separately from `CombinedUsageSnapshot`. Rebuild on either input change. Emit `onTiboPresented` only after expanded content with a retained record is visible; refuse deferred reveal when `targetFrame == nil`; preserve existing collapse/mouse-monitor cleanup.

- [ ] **Step 8: Run all Core tests and manually compile the executable**

Run: `swift test && swift build`

Expected: all tests pass and the AppKit target compiles.

- [ ] **Step 9: Commit**

```bash
git add Sources/CodexUsageCore/TiboDisplayFormatter.swift Tests/CodexUsageCoreTests/TiboDisplayFormatterTests.swift Sources/CodexUsageOverlay/OverlayViews.swift Sources/CodexUsageOverlay/OverlayPanelController.swift
git commit -m "feat: display Tibo alert details"
```

---

### Task 6: Native Notifications and Application Lifecycle Integration

**Files:**
- Create: `Sources/CodexUsageOverlay/TiboNotificationController.swift`
- Modify: `Sources/CodexUsageOverlay/AppDelegate.swift`
- Modify: `Sources/CodexUsageOverlay/StatusItemController.swift`
- Modify: `Sources/CodexUsageCore/AppServerClient.swift`
- Modify: `Tests/CodexUsageCoreTests/AppServerClientTests.swift`
- Modify: `Resources/Info.plist`

**Interfaces:**
- Consumes: Task 4's coordinator/notifier protocol and Task 5's panel callbacks.
- Produces: `@MainActor final class TiboNotificationController: NSObject, TiboNotificationSending, UNUserNotificationCenterDelegate`.
- Notification selection passes only the stable message ID to the coordinator; it never opens a URL or activates an application.

- [ ] **Step 1: Add the concrete notification adapter**

Request `.alert`, `.badge`, and `.sound` authorization once when directed by the coordinator. Deliver plain-text notifications with identifier `tibo-reset-<message-id>`, remove anomalous delivered/pending requests by that identifier, and complete every UserNotifications callback exactly once.

- [ ] **Step 2: Wire startup, change propagation, and refresh**

In `AppDelegate`, construct one standard-defaults store, restricted transport, feed client, verifier, notification controller, and coordinator. Render store changes into the panel. Start after UI construction; stop before dropping callbacks. Extend the existing Refresh action to call `coordinator.refreshNow()` without changing account/context behavior.

- [ ] **Step 3: Wire deferred reveal and read state**

On notification selection, let the coordinator persist pending reveal. After each non-nil tracker placement, call `consumePendingReveal` only if `panel.revealTiboDetails()` succeeds. Wire `onTiboPresented` to `markRead()` and `onOpenTiboPost` to `NSWorkspace.shared.open` for the already validated canonical URL.

- [ ] **Step 4: Wire sleep/wake without duplicate observers**

Register once for `NSWorkspace.didWakeNotification`, call `coordinator.handleWake()`, and remove the observer during application termination. Do not issue catch-up requests for elapsed five-minute periods.

- [ ] **Step 5: Add notification-permission help and data-source copy**

Add a `通知权限` menu item that opens macOS Notification settings. Update the in-app data-source explanation to distinguish community feed, X confirmation, and account-local quota truth.

- [ ] **Step 6: Bump release metadata consistently**

Set `CFBundleShortVersionString` to `0.2.0`, `CFBundleVersion` to `2`, and App Server `clientInfo.version` to `0.2.0`; update the existing protocol assertion.

- [ ] **Step 7: Run the full suite and build**

Run: `swift test && swift build`

Expected: all tests pass, including the updated App Server version assertion, and the executable target compiles with AppKit/UserNotifications.

- [ ] **Step 8: Commit**

```bash
git add Sources/CodexUsageOverlay/TiboNotificationController.swift Sources/CodexUsageOverlay/AppDelegate.swift Sources/CodexUsageOverlay/StatusItemController.swift Sources/CodexUsageCore/AppServerClient.swift Tests/CodexUsageCoreTests/AppServerClientTests.swift Resources/Info.plist
git commit -m "feat: integrate native Tibo notifications"
```

---

### Task 7: Documentation, Packaging, and Live Acceptance

**Files:**
- Modify: `README.md`
- Modify: `THIRD_PARTY_NOTICES.md`
- Verify: `scripts/package_app.sh`
- Verify artifact: `dist/CodexUsageOverlay.app`

**Interfaces:**
- Consumes: all prior tasks.
- Produces: documented, packaged, signed `0.2.0` application and verification evidence; no new runtime interface.

- [ ] **Step 1: Update user and privacy documentation**

Document the five-minute background request, four qualifying categories, first-run test notification, pending/confirmed/anomalous labels, click/deferred-reveal behavior, notification permission, exact persisted fields, deletion command, fixed hosts, visible attribution requirement, and the distinction between public announcement and personal quota delivery.

- [ ] **Step 2: Record third-party service attribution**

Add `codex-reset.com` as the independent data service with its developer/terms link and note that no service code is copied. Document X oEmbed as the independent author-confirmation step.

- [ ] **Step 3: Run final automated verification**

Run:

```bash
swift test
git diff --check
./scripts/package_app.sh
codesign --verify --deep --strict --verbose=2 dist/CodexUsageOverlay.app
test -x dist/CodexUsageOverlay.app/Contents/MacOS/CodexUsageOverlay
```

Expected: all tests pass, no whitespace errors, packaging succeeds, signature verification succeeds, and the release executable exists.

- [ ] **Step 4: Run controlled integration verification**

Use a local fixture transport in tests to prove pending notification → confirmed state with no duplicate. Confirm the packaged app does not contact a non-allowlisted redirect and does not create a second process or long-lived connection.

- [ ] **Step 5: Install and verify the one-time current-message alert**

Quit the installed overlay, preserve a recoverable backup, install the packaged app, and launch through its bundle. Confirm notification permission appears once; the current newest qualifying message generates one pending notification and unread dot; the details show attribution and later `✓ X 已确认` without a second banner.

- [ ] **Step 6: Verify deferred notification selection**

With Codex not foreground, select the notification and confirm no app switch or panel appears. Return to Codex, confirm the normal overlay expands once, and confirm unread clears only after the Tibo section is visible.

- [ ] **Step 7: Verify denied-permission and resource behavior**

Using a clean test preference domain or controlled permission state, verify the badge/details path without banners. Observe one overlay process, no persistent network connection, and no feed cadence faster than five minutes.

- [ ] **Step 8: Commit documentation**

```bash
git add README.md THIRD_PARTY_NOTICES.md
git commit -m "docs: document Tibo reset alerts"
```

- [ ] **Step 9: Request whole-branch review and address findings**

Review the complete branch against `docs/superpowers/specs/2026-10-08-tibo-reset-alerts-design.md`, rerun Task 7 Step 3 after fixes, and leave the feature branch/worktree available for PR feedback.
