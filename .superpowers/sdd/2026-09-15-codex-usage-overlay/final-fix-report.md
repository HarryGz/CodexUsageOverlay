# Final-review fix wave

Date: 2026-09-15
Status: **DONE_WITH_CONCERNS** — all requested Important implementation findings and implementation minors are fixed; live/manual verification remains outstanding as previously recorded. No Critical or Important finding remains open.

Worktree: `outputs/CodexUsageOverlay/.worktrees/usage-overlay-implementation`

Branch: `feature/usage-overlay-implementation`

Review base: `ad1990096599e5a0f8e0ba14b4072ec0013691f0`

Implementation commit: `5425d73` — `fix: address final usage overlay review findings`
This report and the updated verification record are committed separately as `docs: record final overlay fix verification`.

No subagents or reviewers were dispatched. The spec, plan, ledger/rulings, existing code, and review findings were inspected. Review reception, TDD, debugging, and verification skills guided the work. Tests use synthetic protocol data, temporary synthetic session trees, and controlled shell subprocesses.

## 1. JSON numeric zero/one

**Change:** AccountUsageParser now distinguishes CFBoolean identity from NSNumber. JSON numeric `0`, `1`, `0.0`, and `1.0` are valid percentages; JSON booleans remain invalid. The regression also checks numeric duration 1 and reset epoch 0.

**Test:** `AccountUsageParserTests.testJSONNumericZeroAndOneAreNotBooleans`.

**RED:** `swift test --filter AccountUsageParserTests/testJSONNumericZeroAndOneAreNotBooleans` exited 1: 1 test, 12 assertion failures; all four valid numeric fixtures returned nil values.

**GREEN:** `swift test --filter AccountUsageParserTests` exited 0: initially 6 tests, 0 failures; final suite has 9 tests, 0 failures.

## 2. Authoritative reads versus sparse update freshness

**Change:** Result payloads start from an empty authoritative snapshot; params payloads merge sparse updates. At least one valid window field must be supplied. Empty/wholly invalid updates return nil and cannot update the stored timestamp. Missing windows and fields are not inherited by authoritative reads. Valid sparse reset-only updates retain the known percentage and other windows.

**Tests:** `testEmptyAndInvalidUpdatesDoNotManufactureFreshness`, `testAuthoritativeReadRemovesAbsentWindowsAndDoesNotInheritFields`, `testValidSparseResetUpdatePreservesPercentAndOtherWindows`, and the existing sparse-notification preservation case.

**RED:** `swift test --filter AccountUsageParserTests` exited 1: 9 tests, 13 failures. The full read retained the old weekly window, reset, and plan; ten empty/invalid payload variants incorrectly returned a refreshed snapshot.

**GREEN:** Same command exited 0: 9 tests, 0 failures.

## 3. Failed and silent initialization recovery

**Change:** Initialization errors and a five-second timeout use the same owned-process failure path as transport failure. It clears initialization/framing state, cancels refresh/timeout work, closes handles, terminates and reaps the exact owned child, then retries with the existing 1/2/5/15-second backoff. A successful handshake cancels its timeout and resets backoff. Quotas cannot publish before initialization.

**Tests:** `testInitializationErrorReapsChildAndRecovers` and `testSilentInitializationTimesOutReapsChildAndRecovers`. Synthetic first children read initialization and then either send an error or stay silent. Replacement children require the read-only handshake sequence and return a zero-used quota. Tests assert the expected error, recovery, exactly two launches, and ESRCH for the reaped first PID.

**RED:** `swift test --filter 'AppServerClientTests/test(InitializationError|SilentInitialization)'` exited 1: 2 tests, 8 failures. Recovery timed out, launch count stayed at 1, and each failed child was still alive.

**GREEN:** `swift test --filter AppServerClientTests` exited 0: 8 tests, 0 failures. Timeout recovery completed within the bounded test wait.

## 4. Context identity/provenance and compaction invalidation

**Change:** UsageStore has an explicit `invalidateContext` transition. AppDelegate invalidates on selection/provenance changes; the monitor signals invalidation before publishing a changed identity/provenance and when no complete usable post-compaction token event exists. Same-context read failures and aged valid snapshots still retain their prior values as stale. Manual refresh no longer pretends a same-selection refresh is an identity change.

**Tests:** `testSelectionAndProvenanceChangesInvalidateBeforePublishingAnotherSnapshot`, `testSelectingMissingTaskReportsInvalidationInsteadOfRetainingOldIdentity`, `testCompactionClearsStoreAndDisplayUntilDistinctPostCompactionCount`, and existing UsageStore stale/timestamp tests. Cross-component assertions exercise real monitor → store → formatter state, including unknown display after task change/compaction and recovery on a distinct post-compaction count.

**RED:** `swift test --filter 'ContextLogMonitorTests/test(SelectionAndProvenance|SelectingMissing)'` exited 1: 2 tests, 3 failures; no invalidation arrived and replacement publication preceded invalidation. The store/compaction test initially failed compilation with `UsageStore has no member invalidateContext`, the required missing state transition.

**GREEN:** `swift test --filter 'ContextLogMonitorTests|UsageStoreTests'` exited 0 after implementation: 14 tests, 0 failures. Subsequent expanded context/store/selection coverage passed 25 tests.

## 5. Missing-log discovery and delayed rotation

**Change:** The monitor retains either an explicit thread target or a fallback intention. Missing resolution retries at 1, 2, 5, then every 15 seconds while enabled. Rename/delete gaps enter the same retry path. `refreshNow()` re-resolves immediately while enabled, including an initially missing log and a newer fallback. A valid descriptor cancels discovery retries.

**Tests:** `testMissingSelectedRolloutIsDiscoveredAfterCreation`, `testRefreshNowRetriesMissingResolution`, `testDelayedReplacementAfterRotationIsDiscovered`, and `testMissingFallbackIsDiscoveredAfterFirstRolloutAppears`.

**RED:** `swift test --filter 'ContextLogMonitorTests/test(MissingSelected|RefreshNowRetries|DelayedReplacement|BackgroundDisconnect|SelectionDoesNot)'` exited 1: 5 tests, 5 failures. The three discovery cases timed out after the initially absent or rotated file appeared.

**GREEN:** Same command exited 0: 5 tests, 0 failures. Missing selected and rotated logs recovered on the first retry; explicit refresh recovered within its 0.5-second wait. Added missing-fallback coverage also passed in the final context suite.

## 6. Foreground-only log activity

**Change:** ContextLogMonitor begins disabled. Selection updates retain intention without opening files. AppDelegate starts monitoring on a valid foreground placement and stops it on nil placement. Stop cancels debounce/discovery work, invalidates queued callbacks, and closes the watcher descriptor; foreground return resolves the retained target. IPC disconnect/fallback selection and refresh while background cannot reactivate monitoring.

**Tests:** `testBackgroundDisconnectCannotRestartWatchingAndForegroundResumesIntent`, `testSelectionDoesNotMonitorBeforeForegroundStart`, `testBackgroundStopClosesOwnedRolloutDescriptor`, `testStoppingMissingDiscoveryCancelsRetryUntilForegroundReturns`, and the existing queued-callback/teardown cases. The descriptor test matches only synthetic fixture device/inode metadata in the test process and verifies one descriptor before stop, none after cancellation drains.

**RED:** The same five-case command listed under finding 5 exited 1. Both foreground-gating regressions fulfilled inverted expectations by publishing in the background.

**GREEN:** The five-case command exited 0. Expanded `swift test --filter 'ContextLogMonitorTests|ContextSelectionTests|UsageStoreTests'` passed 25 tests. The missing-discovery stop test remains quiet beyond the first retry interval, has no open fixture descriptor, and recovers only after start.

## 7. Degraded window revalidation

**Change:** CodexWindowTracker owns a separate two-second fallback timer only while the app is running, Codex is foreground, and Accessibility window observation is unavailable. It re-evaluates Quartz window presence even if no plausible window is currently selected, so close/minimize and later restore are observed. AX success, background/hidden/terminated state, and stop cancel it. The existing bounded movement timer remains separate.

**Test:** `OverlayPlacementTests.testDegradedWindowRevalidationRunsOnlyInForegroundWithoutAccessibility` covers foreground enablement, conservative interval bounds, and cancellation policy for AX availability/background/stop. The tested policy is consumed by the actual timer setup; cancellation paths were also inspected.

**RED:** `swift test --filter OverlayPlacementTests/testDegradedWindowRevalidationRunsOnlyInForegroundWithoutAccessibility` exited 1 with the missing `WindowObservationPolicy` symbol.

**GREEN:** `swift test --filter OverlayPlacementTests` exited 0: 13 tests, 0 failures. Actual AX permission/window interaction was not performed in this wave.

## 8. Ambiguous multi-window routes

**Change:** More than one active IPC route becomes `uncertainSelected`, carrying `ambiguousThread` provenance through AppDelegate and the context monitor. Both compact and detail formatters render `可能非当前任务`. One active route remains selected. The existing arrival-order choice is retained only as an uncertain candidate; no AX/IPC identity join is invented.

**Tests:** `testTwoActiveRoutesCannotClaimTheForegroundTaskWithoutANewBroadcast` covers two active routes, repeated status with no new broadcast after possible focus changes, and restoration of the one remaining route. `testAmbiguousWindowRouteIsLabeledInCompactAndDetail` covers both UI presentations.

**RED:** `swift test --filter ContextSelectionTests` exited 1: 3 tests, 2 failures because the multi-window state still claimed selected. The new formatting case separately exited 1 with 2 missing-label failures.

**GREEN:** `swift test --filter 'ContextSelectionTests|DisplayFormattingTests'` exited 0: 15 tests, 0 failures.

## 9. Expanded details

**Change:** Details show each window's local reset timestamp, context used tokens, and separate last-success timestamp/age rows for account and context. Stale values retain their original timestamps. Time-zone injection makes timestamp formatting deterministic in tests.

**Test:** `testDetailsIncludeUsedTokensLocalResetAndIndependentSuccessAges` uses a fixed UTC+8 zone and distinct source timestamps. It expects reset `1970-01-01 09:00:00`, account `08:00:00（2分前）`, context `08:01:00（1分前）`, and used `59k`.

**RED:** `swift test --filter DisplayFormattingTests/testDetailsIncludeUsedTokensLocalResetAndIndependentSuccessAges` exited 1: 1 test, 4 failures because all four required rows were missing.

**GREEN:** Formatting and geometry suites passed 23 tests at that step; the final formatting suite passed 12 tests.

## 10. App Server frame size and boundaries

**Change:** JSONRPCLineCodec checks size before buffering/decoding every segment. Once a frame exceeds 4 MiB, it discards until that frame's newline, then resumes at the following frame. Oversized complete lines and fragmented overflows cannot bypass the cap or turn a discarded suffix into a new message.

**Tests:** `testCodecDropsOversizedUnterminatedFrame` now asserts discard-through-newline. `testOversizedTerminatedFrameCannotBypassCap` checks a terminated oversized valid JSON frame followed by a valid frame, both in one append and fragmented into 65,537-byte chunks.

**RED:** `swift test --filter JSONRPCLineCodecTests` exited 1: 5 tests, 5 failures; the old decoder accepted oversized complete frames and interpreted an overflow suffix as a new frame.

**GREEN:** Same command exited 0: 5 tests, 0 failures.

## 11. Newest fallback beyond arbitrary first 128

**Change:** Discovery traverses both session roots, retains a bounded newest set of 128 candidate paths by modification time/path tie-break, and only then reads bounded metadata prefixes. Arbitrary directory enumeration order can no longer exclude the newest compatible fallback/continuation. At most 128 metadata prefixes are inspected.

**Test:** `testNewestFallbackIsConsideredAfterMoreThan128Histories` creates 140 older session files and a newer archived session. It checks both fallback and explicit-thread resolution.

**RED:** `swift test --filter SessionPathResolverTests/testNewestFallbackIsConsideredAfterMoreThan128Histories` exited 1: 1 test, 2 failures; both returned an old session file instead of the newest archived file.

**GREEN:** `swift test --filter SessionPathResolverTests` exited 0: 8 tests, 0 failures.

## 12–14. Deferred-minor triage

- **12, closed stdin:** The first final combined focused run reproduced the deferred timing problem: 80 tests, 1 failure, with the closed-stdin test timing out waiting for transport failure. Its synthetic server had sent initialization success before closing stdin, allowing all client writes to win the race. The fixture now closes stdin before announcing success, with waits that account for bounded child cleanup and retry. The focused case then passed 1 test; later focused/full/package runs all passed. No production transport change was needed for this test correction. The pre-existing partial-frame subprocess timing limitation remains non-blocking and was not rewritten.
- **13, focus priority:** The focused test now compares a 600×400 focused window with a 1200×800 competitor. It passed in the geometry suite (13 final tests). This strengthens a test for already-correct production behavior, so no production RED/fix cycle was required.
- **14, temporary probe compilation:** Deferred as authorized. This wave did not rerun or reconstruct the old temporary probes, and there is no verified exact historical compile command to add. Existing probe outcomes remain historical evidence; no command arguments were invented.

One test-harness iteration overfulfilled an inverted background expectation before the intended RED run. The expectation was corrected to accept multiple forbidden callbacks as a normal assertion failure; the subsequent five-case RED above failed for the expected behavior reasons.

## Final verification

All commands ran in the implementation worktree. These checks were fresh after the final code/test changes:

| Command | Exit / evidence |
| --- | --- |
| `swift test --filter 'AccountUsageParserTests\|AppServerClientTests\|ContextLogMonitorTests\|ContextSelectionTests\|DisplayFormattingTests\|JSONRPCLineCodecTests\|OverlayPlacementTests\|SessionPathResolverTests\|UsageStoreTests'` | 0; 80 tests, 0 failures |
| `swift test` | 0; 135 XCTest tests, 0 failures |
| `./scripts/package_app.sh` | 0; 135 tests, 0 failures; release build complete; plist OK; staged/final signatures valid |
| `codesign --verify --deep --strict --verbose=2 dist/CodexUsageOverlay.app` | 0; “valid on disk”; “satisfies its Designated Requirement” |
| `test -x dist/CodexUsageOverlay.app/Contents/MacOS/CodexUsageOverlay` | 0 |
| `file dist/CodexUsageOverlay.app/Contents/MacOS/CodexUsageOverlay` | 0; Mach-O 64-bit executable arm64 |
| `lipo -archs dist/CodexUsageOverlay.app/Contents/MacOS/CodexUsageOverlay` | 0; arm64 |
| `xcrun vtool -show-build dist/CodexUsageOverlay.app/Contents/MacOS/CodexUsageOverlay` | 0; LC_BUILD_VERSION, platform MACOS, minos 13.0 |
| `plutil -p dist/CodexUsageOverlay.app/Contents/Info.plist` | 0; LSMinimumSystemVersion 13.0, LSUIElement true |
| `codesign -d --verbose=2 dist/CodexUsageOverlay.app` | 0; Signature=adhoc, thin arm64 |
| `cmp LICENSE dist/CodexUsageOverlay.app/Contents/Resources/LICENSE` | 0; exact match |
| `cmp THIRD_PARTY_NOTICES.md dist/CodexUsageOverlay.app/Contents/Resources/THIRD_PARTY_NOTICES.md` | 0; exact match |
| `git diff --check` | 0 |

The generated `dist/CodexUsageOverlay.app` was rebuilt/replaced by the authorized packaging script. It is reproducible from the committed source. No installed application was replaced.

## Files and commits

Implementation commit `5425d73` changes:

- `README.md`.
- Core: `AccountUsageParser.swift`, `AppServerClient.swift`, `ContextLogMonitor.swift`, `ContextSelection.swift`, `JSONRPCLineCodec.swift`, `OverlayPlacement.swift`, `SessionPathResolver.swift`, `UsageModels.swift`, `UsageStore.swift`.
- App: `AppDelegate.swift`, `CodexWindowTracker.swift`.
- Tests: `AccountUsageParserTests.swift`, `AppServerClientTests.swift`, `ContextLogMonitorTests.swift`, `ContextSelectionTests.swift`, `DisplayFormattingTests.swift`, `JSONRPCLineCodecTests.swift`, `OverlayPlacementTests.swift`, `SessionPathResolverTests.swift`.

The separate evidence commit changes this report and `docs/verification/2026-09-15-local-verification.md`. The verification record distinguishes the pre-fix live evidence at `ad19900` from fresh automated checks at `5425d73`.

## Security and self-review

- No live app launch, install/uninstall, permission change, prompt, settings navigation, Codex task/window operation, or direct telemetry/network client was used or added.
- No real credentials, auth file, cookie/token, account payload, rollout content, message, prompt, response, or tool output was accessed by this fix wave. Synthetic metadata/protocol fixtures were used throughout.
- The product still uses only Apple frameworks/SPM. No new dependency, persistence key, external service, or direct authentication path was added.
- App Server retry cleanup targets the exact owned Process; initialization timeout and stale-reader identity guards are canceled/checked on replacement. Request methods remain the original read-only allowlist.
- Log discovery still uses no-symlink descriptor opens and bounded structural metadata parsing. The newest-candidate fix bounds retained paths/prefix reads, while scanning filename/attribute metadata across the roots to avoid enumeration-order loss.
- Main-thread delivery, generation checks, worker-queue teardown, source cancellation, and foreground gating were inspected together. Cross-component tests verify invalidation and descriptor closure, rather than just parser output.
- Snapshot timestamps are never manufactured from empty quota updates or rewritten by age formatting. Missing context remains unknown after identity/provenance changes and compaction.
- Multi-window uncertainty is explicitly displayed; the implementation does not claim a reliable foreground-window mapping.
- Remaining limits: actual AppKit layout, focus while typing, AX permission transitions, real task switching, window close/minimize timing, Spaces/displays, and live reset comparisons still require manual user verification. This wave does not convert the prior manual gaps into passes.
