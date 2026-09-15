# Codex Usage Overlay Design

Date: 2026-09-15

## Purpose

Build a small native macOS companion for Codex that shows two different kinds
of remaining capacity in one control:

- ChatGPT/Codex account quota windows, including the short window and weekly
  window returned by the signed-in account.
- The context-window capacity remaining in the task currently selected in
  Codex Desktop.

The overlay follows the upper-right corner of the active Codex main window. It
is visible only while Codex is the foreground application. It does not modify,
inject into, re-sign, or replace Codex Desktop.

## Scope

The first release targets macOS 13 or later and Apple Silicon. The source must
remain portable to Intel, but producing an Intel binary is not required for the
first local build.

The release includes:

- A native Swift executable packaged as a menu-bar-only `.app`.
- A compact, non-activating overlay and an expanded detail view.
- Read-only Codex App Server, local IPC, and local session-log integrations.
- A menu-bar menu for refresh, settings, permission help, and quit.
- Unit tests built from synthetic account, IPC, and session-log data.
- Build, package, install, and uninstall scripts for a local ad-hoc-signed app.
- Third-party notices preserving the reused MIT license text and attribution.

The first release does not include App Store distribution, Developer ID
notarization, cloud synchronization, billing-cost estimates, quota-reset
redemption, task control, or modifications to Codex configuration.

## User Experience

### Compact overlay

The default presentation is a single compact capsule anchored inside the
upper-right edge of the active Codex main window. It does not become the key
window and does not take focus from the Codex editor.

The capsule uses short labels and remaining percentages:

```text
5h 72% · 周 84% · 上下文 41%
```

The short-window label comes from the duration reported by Codex. It must not
claim a five-hour window when the account reports a different duration. If a
window is absent, its segment is omitted rather than rendered as unlimited.

Capacity colors are:

- Green: more than 50% remaining.
- Amber: 20% through 50% remaining.
- Red: less than 20% remaining.
- Neutral gray: unavailable or stale.

### Expanded view

Clicking the capsule expands a detail panel without activating the app. The
panel shows:

- Each available account window's remaining percentage, duration, reset
  countdown, and local reset time.
- Context used, context limit, remaining tokens, and remaining percentage.
- The selected task identifier in shortened form.
- Last successful update time and any stale, fallback, or unavailable state.
- Explicit refresh and collapse actions.

Clicking outside the panel collapses it. The overlay never expands itself in
response to an error or notification.

### Window behavior

- When Codex becomes foreground, the overlay binds to its focused main window.
- Moving, resizing, changing Spaces, changing displays, minimizing, restoring,
  opening, or closing the Codex window updates placement through workspace and
  Accessibility events.
- When Codex is no longer foreground, is hidden, is minimized, or exits, the
  overlay hides.
- The user may adjust a small x/y offset in settings. The default avoids Codex
  title-bar controls and remains within the visible window frame.
- Without Accessibility permission, the app shows a permission-help item in
  the menu bar and uses a conservative fixed upper-right screen position while
  Codex is foreground.

## Architecture

The application is a Swift Package with a menu-bar executable and focused core
modules:

```text
Codex app-server ──> AccountUsageService ──┐
                                          ├─> UsageStore ─> OverlayController
Codex local IPC ──> ActiveThreadService ──┤
                                          │
Codex session JSONL ─> ContextUsageService┘

NSWorkspace + Accessibility ─> CodexWindowTracker ─> OverlayController
```

### `AccountUsageService`

Starts the locally installed Codex binary as `codex app-server --stdio`,
performs the JSON-RPC initialization handshake, and sends read-only requests:

- `account/read`
- `account/rateLimits/read`

It consumes `account/rateLimits/updated` notifications and performs a fallback
refresh every three minutes while Codex is in the foreground. The service does
not invoke reset-credit or mutation methods. `usedPercent` is converted to a
clamped remaining percentage with `100 - usedPercent`.

### `ActiveThreadService`

Connects read-only to the Codex Desktop local IPC Unix socket. It validates
that the socket is owned by the current user and that its containing directory
is not writable by other users. It tracks `thread-stream-following-changed` and
client-disconnection broadcasts to identify the task selected by the most
recent active Codex window.

If IPC is unavailable, it returns an explicit fallback state instead of
silently presenting another task as current.

### `ContextUsageService`

Resolves the selected thread to its root session JSONL under `$CODEX_HOME` or
`~/.codex`. It tails a bounded portion of the file and reads only complete
`event_msg` records whose payload type is `token_count`.

For the latest valid record:

```text
used = last_token_usage.total_tokens
limit = model_context_window
remaining = max(0, limit - used)
remainingPercent = remaining / limit * 100
```

It does not add cached input or reasoning counters again. When the task has no
fresh post-compaction token snapshot, context values remain unavailable until
a distinct valid snapshot arrives.

When IPC is disconnected, the service may inspect the newest compatible root
session as a convenience fallback, but the UI must label it `可能非当前任务`.
Session freshness is based on the token event timestamp when present and file
modification time only as a secondary signal.

### `UsageStore`

Combines account and context snapshots without forcing their refresh cycles to
match. Each value carries its own timestamp and provenance. Missing new data
does not overwrite a valid snapshot with zero. Snapshots older than five
minutes are marked stale.

### `CodexWindowTracker`

Uses `NSWorkspace` notifications, `AXObserver`, and a short movement timer only
while the user is actively dragging or resizing. It recognizes the official
Codex/ChatGPT desktop bundle identifiers and selects a plausible main window by
visibility, size, focus, and on-screen geometry. Idle placement is event-driven
and does not poll continuously.

### `OverlayController`

Owns a borderless `NSPanel`, compact and expanded Swift/AppKit views, menu-bar
commands, and persisted appearance/offset preferences. The panel uses a
non-activating style, joins all Spaces as appropriate, and is ordered only while
the target Codex window is foreground.

## Data and State Rules

- Account percentages describe subscription quota windows; context tokens
  describe one task's next-request capacity. They are never added together.
- All user-facing account values are remaining values, even though the server
  reports `usedPercent`.
- Unknown means unknown. Missing fields display `—`, not zero or 100%.
- A cached value is visually labeled and retains its original timestamp.
- Reset countdowns are calculated locally from the server's Unix timestamp.
- The UI follows reported window durations instead of hard-coding plan rules.
- Context is an estimate from the latest recorded request and may lag work that
  has not yet been written to the session log.

## Failure Handling

- App Server launch failure: show account values as unavailable, surface a
  concise menu-bar diagnostic, and retry with bounded backoff.
- App Server protocol or authentication failure: preserve a labeled stale
  snapshot and retry; never read credentials directly as a workaround.
- IPC unavailable or incompatible: switch to labeled fallback-session mode and
  retry the validated socket candidates.
- Session missing, compressed, malformed, or not yet written: show context as
  unavailable and keep monitoring for a compatible record.
- Accessibility denied: use conservative screen-relative placement and provide
  instructions for enabling the permission.
- Codex exits: hide the panel, stop active file monitoring, and retain only
  non-sensitive preferences and the last display snapshot in memory.

Errors in one data source do not hide valid data from another source.

## Privacy and Security

- No telemetry, analytics, ads, crash upload, or independent network client.
- The companion communicates with OpenAI only indirectly through the installed
  Codex App Server, which owns authentication and token refresh.
- The application never reads `auth.json`, browser cookies, access tokens,
  message text, prompts, responses, or tool outputs.
- Session parsing is bounded to token-count metadata and thread metadata.
- No raw App Server responses, task logs, or task identifiers are written to
  disk.
- Accessibility access is used only for application/window identification and
  geometry.

## Community Code Reuse

The implementation may adapt focused portions of these MIT-licensed projects:

- `caisimai/codex-usage-overlay`: App Server lifecycle, account response
  parsing, `NSPanel` presentation, and Codex window tracking.
- `soleillevant0125/codex-token-overlay`: local IPC routing, session resolution,
  and `token_count` parsing.

Adapted code must be reviewed rather than copied wholesale. Namespaces,
interfaces, and tests should be normalized to this project's architecture.
The original copyright and permission notices must be retained in
`THIRD_PARTY_NOTICES.md` and in copied source files when the copied portion is
substantial.

## Testing and Verification

Automated tests use only synthetic fixtures and cover:

- Account-window parsing, sparse updates, missing windows, clamping, and reset
  timestamps.
- Remaining-context arithmetic, malformed and partial JSONL records, stale
  events, and post-compaction recovery.
- IPC routing across multiple Codex windows, follow/unfollow events,
  disconnections, oversized frames, and socket validation.
- Store merging so unavailable sources cannot replace valid values with zero.
- Window-frame selection and overlay placement using deterministic geometry.

Release verification includes:

1. `swift test`.
2. Release build and local `.app` packaging.
3. Ad-hoc code-signature verification.
4. Manual launch against the installed Codex app.
5. Foreground/background, move, resize, minimize/restore, Space, and
   multi-display checks.
6. Current-task switching and context updates after completed turns.
7. App Server, IPC, Accessibility, and session-log failure simulations.

## Deliverable

The completed project lives in the `outputs/CodexUsageOverlay` repository. It
contains source, tests, documentation, third-party notices, local build and
install scripts, and a locally built `.app` artifact when the host toolchain can
produce it. Installation remains an explicit user action because macOS may ask
for Accessibility permission and confirmation for an ad-hoc-signed app.
