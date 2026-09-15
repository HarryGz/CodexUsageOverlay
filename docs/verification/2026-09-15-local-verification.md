# Local verification — 2026-09-15

Status: **DONE_WITH_CONCERNS**. Automated checks and the safe live checks below passed. The full manual acceptance criteria remain incomplete; cases marked **NEEDS USER VERIFICATION（需要用户验证）** are not implied to pass.

## Final-review fix verification

Implementation commit: `5425d73`. The live observations in the remaining sections were made before these fixes, at `ad19900`; they are historical evidence and do not certify the revised UI or window behavior. This fix wave did not launch or install the app, change permissions, operate Codex windows/tasks, or read real account/session data.

| Fresh check after the fixes | Result |
| --- | --- |
| Focused parser, transport, context, routing, formatting, geometry, resolver, and store suites | PASS; 80 tests, 0 failures |
| `swift test` | PASS; 135 tests, 0 failures |
| `./scripts/package_app.sh` | PASS; reran 135 tests, release arm64 build, plist validation, staged and final signatures |
| Independent `codesign --verify --deep --strict --verbose=2 dist/CodexUsageOverlay.app` | PASS; valid on disk, designated requirement satisfied |
| `test -x`, `file`, `lipo -archs` on the packaged executable | PASS; executable Mach-O, arm64 only |
| `xcrun vtool -show-build` on the packaged executable | PASS; `LC_BUILD_VERSION`, platform MACOS, `minos 13.0` |
| Packaged plist and signature metadata | PASS; `LSMinimumSystemVersion=13.0`, `LSUIElement=true`, ad-hoc |
| License and third-party notice `cmp` checks | PASS; both packaged resources match exactly |
| `git diff --check` | PASS |

The fix wave adds explicit context invalidation, foreground-only log watching/discovery, missing-log retry, a two-second foreground window check when Accessibility is unavailable, multi-window uncertainty labels, complete update/reset details, and account/framing/recovery corrections. README now describes these behaviors. Synthetic tests also verify descriptor closure and silence across background/disconnect/foreground transitions. The old closed-stdin test exposed its previously deferred ordering race during the combined run; closing stdin before announcing initialization fixed the fixture, and all subsequent focused/full/package runs passed.

Per-finding RED/GREEN evidence is recorded in [the final fix report](../../.superpowers/sdd/2026-09-15-codex-usage-overlay/final-fix-report.md). The pre-existing partial-frame subprocess timing weakness and missing exact temporary-probe compilation arguments remain non-blocking documentation/test limitations; no missing commands were invented. All manual acceptance cases listed later still require user verification.

## Host and artifact

| Item | Observed value |
| --- | --- |
| macOS | 26.6.2, build 25G83 |
| Architecture | arm64 |
| Swift | Apple Swift 6.4, swiftlang-6.4.0.34.1; compiler target arm64-apple-macosx26.0 |
| Resolved Codex binary | `/Applications/ChatGPT.app/Contents/Resources/codex` |
| App launched | `dist/CodexUsageOverlay.app`, directly from this worktree; not installed |
| Bundle | `local.codex-usage-overlay`, version 0.1.0 (1), `LSUIElement=true`, minimum macOS 13.0 |
| Executable | Mach-O 64-bit arm64 |
| Signature | Ad-hoc; strict deep verification passed; not notarized |
| Displays reported | 3; no display or Space was changed by verification |
| Accessibility observation | Read-only `AXIsProcessTrusted()` returned true for the external verification observer. This does not establish the companion's own authorization. No permission was changed. |

## Live acceptance evidence

Evidence came from generic process/window metadata and allowlisted values from the companion's Accessibility tree. No screenshot, Codex task text, raw IPC frame, or raw server response was captured. Window counts establish presence/absence only, not visual alignment or rendering quality.

| Case | Result | Evidence and limits |
| --- | --- | --- |
| Launch packaged app | PASS | `open dist/CodexUsageOverlay.app` exited 0. Baseline companion count 0; settled launch count 1. |
| Owned App Server count | PASS | Settled companion had exactly 1 direct child. Parent relationship and the child's executable path were checked before any termination. Reopening the bundle still yielded 1 companion and 1 owned child. |
| Available quota display | PASS, weekly only | Compact Accessibility value showed `周 62%`. Independent fresh local `account/rateLimits/read` returned one usable weekly window: 10080 minutes, `100 − 38 = 62%`. Production parser and independent numeric inspection both found one usable window. A production-client initial read plus explicit refresh also returned the weekly value. |
| Companion refresh action | PASS | Companion-only Accessibility press of `展开用量详情` and then `刷新用量` both returned success (0). A subsequent compact observation still showed weekly 62%. No Codex task action was sent. |
| Short-window quota | NEEDS USER VERIFICATION（需要用户验证） | This live response supplied no usable short window. Its duration and remaining display cannot be verified from this account observation; none was fabricated. |
| Reset information | NEEDS USER VERIFICATION（需要用户验证） | Weekly reset timestamp was present. Exact reset timestamps were deliberately omitted under the stricter redaction boundary. The visible countdown was not compared with the server timestamp. |
| Codex foreground / background | PASS, metadata only | Settled observations showed Codex foreground with 1 companion on-screen window, another application foreground with 0, and Codex foreground again with 1. Foreground changes occurred naturally during the run; verification did not move or activate Codex windows. This does not establish every transition's timing. |
| No keyboard focus theft | NEEDS USER VERIFICATION（需要用户验证） | Codex remained foreground before/after the observed expand and refresh presses. No typing or focused responder test was performed. A second `open` had a transient non-Codex foreground snapshot; its exact owner was not retained, so launch/focus behavior is not certified. |
| Owned-child reconnect | PASS | Two controlled SIGTERM checks targeted only the verified direct child. A replacement child appeared each time; maximum sampled owned-child count was 1. The foreground check observed retained 62% with an `已过期` label after termination, then 62% without that label after recovery. |
| Current observed fallback | PASS, label only | `可能非当前任务` was exposed in the companion's compact/expanded Accessibility values. This confirms honest fallback labeling, not successful selection of the active task or proof that the socket was unavailable. |
| Start with IPC unavailable | NEEDS USER VERIFICATION（需要用户验证） | Not induced: no socket, directory, Codex process, or connection configuration was modified. Naturally observed fallback is not a controlled unavailable-IPC test. |
| Switch two completed tasks; new-turn context update | NEEDS USER VERIFICATION（需要用户验证） | No task was opened or sent a new turn. Task suffix-change outcome: not tested. No task identifier or context token count was recorded. |
| Select task with no completed response | NEEDS USER VERIFICATION（需要用户验证） | No task selection/content mutation was performed. Live context `—` behavior for that exact case remains unverified. |
| Move/resize; minimize/restore | NEEDS USER VERIFICATION（需要用户验证） | No Codex window was moved, resized, minimized, or restored. |
| Switch Spaces; move between displays | NEEDS USER VERIFICATION（需要用户验证） | Three displays were reported, but no Space/display movement was performed. |
| Close one of multiple Codex windows | NEEDS USER VERIFICATION（需要用户验证） | No Codex window was closed. |
| Denied Accessibility, conservative placement, permission help | NEEDS USER VERIFICATION（需要用户验证） | Companion AX trust was not directly established; no grant/revoke/reset or settings navigation was performed. Placement geometry and permission-help UI were not exercised. |
| Graceful cleanup | PASS | Requested termination on the exact bundle's running application. Its previously owned child was gone; the next fresh process snapshot confirmed companion count 0. The first polling snapshot still had a cached companion entry, so cleanup is based on the subsequent fresh snapshot. |

There were no established product FAIL results in this run. Deferred manual cases are release limitations, not passes.

## Commands and results

Repository commands ran from the implementation worktree. `work/` probe paths below refer to the surrounding task workspace, outside the repository; the probes were temporary verification instrumentation and are not application changes.

| Command / operation | Exit / result |
| --- | --- |
| `git status --short` (before verification) | 0; clean |
| `sw_vers` | 0; host version above |
| `uname -m` | 0; arm64 |
| `swift --version` | 0; Swift version above |
| `plutil -p dist/CodexUsageOverlay.app/Contents/Info.plist` | 0; bundle metadata above |
| `file dist/CodexUsageOverlay.app/Contents/MacOS/CodexUsageOverlay` | 0; arm64 Mach-O |
| `codesign --verify --deep --strict --verbose=2 dist/CodexUsageOverlay.app` | 0; valid on disk, designated requirement satisfied |
| `codesign -d --verbose=2 dist/CodexUsageOverlay.app` | 0; ad-hoc signature |
| `cmp LICENSE dist/CodexUsageOverlay.app/Contents/Resources/LICENSE` | 0; exact match |
| `cmp THIRD_PARTY_NOTICES.md dist/CodexUsageOverlay.app/Contents/Resources/THIRD_PARTY_NOTICES.md` | 0; exact match |
| `open dist/CodexUsageOverlay.app` (initial and repeat) | 0 both times |
| `work/task10-runtime-probe snapshot` | 0; sanitized app/child/window counts and allowlisted quota/label states |
| `work/task10-runtime-probe snapshot '展开用量详情'` | 0; companion AX action result 0 |
| `work/task10-runtime-probe snapshot '刷新用量'` | 0; companion AX action result 0 |
| `work/task10-runtime-probe snapshot '收起用量详情'` | 0; compact state already observed, so no successful collapse action is claimed |
| `work/task10-runtime-probe reconnect` (twice) | 0 both times; verified owned child terminated/replaced |
| `work/task10-account-probe` | 0; initial production-client read, refresh, numeric-only output, client stopped |
| `work/task10-wire-probe` | 0; independent rate-limit read, numeric-only output, owned child reaped |
| `work/task10-runtime-probe quit` | 0; graceful quit requested; followed by fresh snapshot confirming 0 companions |
| `swift test` | 0; 112 XCTest tests, 0 failures |
| `./scripts/package_app.sh` | 0; reran 112 tests with 0 failures, release arm64 build, plist validation, staged and final strict signature checks |
| `git diff --check` | 0 |
| `git status --short` (before commit) | 0; only this new verification document |

The external runtime probe initially failed compilation once because an SDK macro was unavailable in Swift (exit 1). Using the equivalent `4 * MAXPATHLEN` expression compiled successfully (exit 0). An early child-count probe matched only the Codex.app path and incorrectly counted zero; the corrected probe recognized the actual executable and verified its path with `proc_pidpath`. Neither instrumentation issue is recorded as an application failure, and no child was terminated before the corrected ownership guard succeeded.

## Boundaries, restoration, and redaction audit

- No installation/uninstallation script was run. Only the generated `dist` bundle was rebuilt after the launched companion had exited.
- No Accessibility or Screen Recording permission was granted, revoked, reset, or prompted by the verifier. No System Settings page was opened.
- No Codex Desktop process or unrelated App Server was signaled. Reconnect checks used verified parentage plus executable path. Separate read probes stopped/reaped only the processes they created.
- No credential file, session log, task content, application file, or IPC socket was edited. The verifier did not directly open real session logs or `auth.json`; the running companion used its normal data sources. This is not a syscall-level audit of Codex App Server's internal authenticated operation.
- No account identifiers, task UUIDs/suffixes, raw protocol data, session lines, prompt/response/tool content, or screenshots were saved in this record. Only generic metadata, durations, a remaining-percentage calculation, reset-presence boolean, and static UI-label outcomes were retained.
- Temporary probe code contains paths and generic checks only; server and AX data were transient in memory, with strict output filtering. Probe output did not include task identifiers, exact reset timestamps, account plan/identity, or context token values.
- No position offset was changed. No Codex task/window/display/Space was deliberately changed. Final fresh process observation: 0 launched companions and no surviving previously owned child.
- README was unchanged: weekly-only responses and approximate fallback are already documented; no new setup caveat was established.

## Remaining user verification

Launch `dist/CodexUsageOverlay.app` when convenient. Verify task switching and a new completed turn, the no-completed-response case, moving/resizing/minimizing/restoring Codex, Spaces/displays, closing one of several windows, keyboard focus while typing/clicking the overlay, and reset countdown accuracy. Verify unavailable-IPC and Accessibility-denied/allowed behavior only through deliberate user-controlled setup. Stop the companion with its menu's Quit action afterward. None of these remaining steps was silently treated as completed here.
