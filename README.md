# Codex Usage Overlay

A small, independent macOS menu bar app showing account quota and task context remaining beside the foreground Codex window. Click the capsule for details. It does not take keyboard focus. This project is not affiliated with or endorsed by OpenAI.

## Requirements

- macOS 13 or later on Apple Silicon (arm64).
- Xcode Command Line Tools with Swift 5.9 or later for building; Apple frameworks and Swift Package Manager only, with no third-party package dependencies.
- A local Codex installation and a signed-in account that exposes quota information through Codex App Server.
- Accessibility permission is optional: without it, a visible Codex window enables a fixed screen-corner placement; with it, the overlay follows the window.

## What the numbers mean

Account quota is the percentage remaining in each reported limit window: `100 − usedPercent`, clamped to 0–100. The five-hour and weekly windows are account limits, shared with other usage covered by that account, not a token budget for the selected task. Reset countdowns come from the server's reset timestamps. Unsupported window durations remain visible in details.

Context remaining is the selected task's model context window minus `last_token_usage.total_tokens` from its latest complete `event_msg` / `token_count` record, clamped to the window size. It is a recent measurement, not a guarantee of how much further work will fit. Compaction or subsequent activity can change it.

For account quota, `—` means a usable value is missing, unreadable, invalid, or unsupported; it never means zero. Account and context failures are independent. Context is shown only for a fresh, complete token snapshot from one uniquely active IPC route. A changed task, ambiguous or missing routing, a read failure, compaction without a fresh token snapshot, or a value older than five minutes hides context completely. Details include local reset times, used/remaining tokens, and each visible source's last successful update and age; visible countdowns and ages refresh every 15 seconds.

The app never guesses the foreground task from the newest rollout. If local IPC has no active route, more than one active route, or only a remembered but no longer active route, the compact capsule and expanded details omit context. Context appears automatically when IPC identifies exactly one active task and its rollout contains a fresh, complete token-count event.

## Tibo reset alerts

While the overlay process is running, version 0.2.0 checks the public `https://codex-reset.com/api/feed?locale=zh` feed no more than once every five minutes, including while Codex is not foreground. It retains and alerts only Tibo-authored messages classified as a reset announcement, completed reset, banked reset, or strong reset hint. Ordinary product posts, community probability changes, and cadence guesses do not qualify. The first successful fresh read alerts the newest qualifying item once as an installation test; its ID is saved before notification delivery so restarting cannot replay it.

The compact capsule shows a small unread dot. Expanded details retain the newest message, Beijing publication time, `查看原帖`, and the required linked `Data: codex-reset.com` attribution. Source status is staged:

- `… 等待 X 确认`: the fresh feed and canonical Tibo post URL passed local structural checks, and the alert was delivered immediately.
- `✓ X 已确认`: X's public oEmbed response independently matched provider, author, handle, and post ID. Confirmation does not create another banner.
- `⚠ 来源异常`: a successful X response conflicted with the feed; the delivered notification is removed and untrusted text/link are hidden.

These are public announcements, not proof that a reset or banked grant reached your signed-in account. The local Codex App Server remains authoritative for personal quota. Selecting a macOS notification never activates Codex or opens a browser: it records one pending reveal, then expands the normal overlay the next time Codex is foreground. Unread clears only after those details are actually visible. The original post opens only from `查看原帖`.

## Build, install, and open

From the repository root:

```sh
./scripts/package_app.sh
./scripts/install.sh
open "$HOME/Applications/CodexUsageOverlay.app"
```

Packaging runs all tests, builds a release arm64 executable, includes the license notices, and ad-hoc signs and verifies `dist/CodexUsageOverlay.app`. Installation replaces only the validated `~/Applications/CodexUsageOverlay.app`; the script accepts no destination argument and refuses symlinked paths or an unrelated existing bundle. It does not start the app. This is a local ad-hoc build, not a notarized distribution.

The app has no Dock icon. Use its gauge menu bar icon for show/hide, refresh, position offsets, Accessibility and notification permission help, data sources, and quit. The overlay is visible only while a supported Codex window is in the foreground. Hiding the overlay through its menu does not stop the five-minute Tibo feed check. Account polling runs every three minutes while Codex is foreground; initial account reads start on the first valid foreground placement. IPC stays active until quit. Log descriptors and discovery retries stop when Codex hides, exits, has no visible main window, or leaves the foreground; the intended selection is retained in memory and resumes on return.

### Notifications

macOS asks for alert, badge, and sound permission once on the first launch of this feature. Denying permission disables banners only: feed checks, the unread dot, and retained details continue. Use the menu's `通知权限` item to open System Settings. Wake performs at most one due check and restarts the five-minute interval; it does not replay missed checks.

### Accessibility

Open System Settings → Privacy & Security → Accessibility, add `~/Applications/CodexUsageOverlay.app`, and enable it. The menu's permission-help action can open this settings page; the app never invokes an automatic Accessibility permission prompt. After changing permission, switch away from and back to Codex, or restart the overlay.

**Accessibility usage explanation:** Codex Usage Overlay uses Accessibility access to read the position, size, focus, and minimized state of Codex windows so the floating usage panel can follow them. It does not read editor text or send keystrokes. Without usable Accessibility observation, it uses a fixed screen-corner position and rechecks window visibility every two seconds while Codex is foreground. This timer stops when Accessibility works, Codex leaves the foreground, or the tracker stops. macOS does not provide a dedicated Info.plist prompt string for AX trust.

### Update and uninstall

Quit the running overlay from its menu before updating. Obtain the updated source, then rerun `./scripts/package_app.sh`, `./scripts/install.sh`, and the `open` command above. Position offsets remain in UserDefaults. A new local signature may require removing and re-adding the app in Accessibility settings.

To uninstall, quit the app, then run:

```sh
./scripts/uninstall.sh
```

This removes only the validated `~/Applications/CodexUsageOverlay.app`. UserDefaults and Accessibility authorization are not removed automatically. You can remove the app's entry manually in Accessibility settings. To also discard saved position offsets, run `defaults delete local.codex-usage-overlay` after quitting. No session data is removed.

## Local data access and privacy

The overlay stores `overlayOffsetX` and `overlayOffsetY` plus a versioned Tibo-alert record in the `local.codex-usage-overlay` UserDefaults domain. Alert state contains only the latest message ID/category/bounded localized summary/publication time/canonical URL/verification state, unread and pending-reveal flags, feed health and last successful check, the newest 32 seen IDs, HTTP `ETag`/`Last-Modified` validators, and whether notification permission was requested. It does not persist raw feed bodies, oEmbed HTML, account identifiers, credentials, quota snapshots, task identifiers, session text, prompts, model responses, or tool output. Task routing identifiers exist only in memory.

The only direct external HTTPS hosts are `codex-reset.com` for the community feed and `publish.x.com` for public author confirmation; cross-host redirects are rejected. Requests contain a stable project user agent but no per-user identifier, Codex state, account quota, task ID, or session content. There is no analytics, authenticated X session, X API token, child process, or long-lived connection for alerts. To remove all saved overlay preferences and alert state after quitting, run:

```sh
defaults delete local.codex-usage-overlay
```

The following sources are read:

| Source | Exact location or contract | Retained data |
| --- | --- | --- |
| Codex executable | `CODEX_BINARY`, then `/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex`, the legacy `/Applications/ChatGPT.app/Contents/Resources/codex`, `/Applications/Codex.app/Contents/Resources/codex`, `/opt/homebrew/bin/codex`, `/usr/local/bin/codex`, `~/.local/bin/codex` | Executable path for launching `app-server --listen stdio://` |
| App Server | `initialize`, `initialized`, `account/read` with `refreshToken: false`, and `account/rateLimits/read` over child-process stdio | Quota windows, reset times, plan type, update time; unrelated response fields are discarded |
| IPC sockets | Absolute `$CODEX_HOME/ipc/ipc.sock`, `~/.codex/ipc/ipc.sock`, absolute `$TMPDIR/codex-ipc/ipc.sock`, `/tmp/codex-ipc/ipc.sock`, in that order | Routing metadata described below; socket and parent ownership/type/permissions are validated |
| Session logs | `sessions/**/rollout-*.jsonl` and `archived_sessions/**/rollout-*.jsonl` under absolute `$CODEX_HOME`, otherwise `~/.codex` | Session metadata matching and latest complete token-count fields; no-symlink descriptor-based reads |
| macOS window metadata | NSWorkspace, on-screen Quartz window metadata, and optionally Accessibility window attributes for `com.openai.codex` / `com.openai.chatgpt` | Foreground/window geometry used for placement; no text content |
| Tibo community feed | `https://codex-reset.com/api/feed?locale=zh`, at most once per five minutes | Bounded normalized latest message, health, cache validators, and a 32-ID deduplication ring |
| X public oEmbed | `https://publish.x.com/oembed` for the reconstructed canonical Tibo post URL | Provider/author/author URL/post URL comparison only; returned HTML is ignored and never saved |

IPC sends the standard `initialize` registration request so Codex can replay the current route after the overlay starts or reconnects. After initialization it accepts only `broadcast` routing events: `thread-stream-following-changed` reads `sourceClientId` and `params.hostId`, `conversationId`, `following`; `client-status-changed` reads `params.clientId` and `status`. Identifiers are used transiently to select a log and never saved; for one verified active task, details show only the final eight characters of its identifier to help distinguish readings. Unrelated IPC message bodies are structurally skipped. The app does not send task actions through IPC and does not infer selection from task recency.

Session discovery scans candidate paths and file attributes across both session roots, retains the newest 128 candidates, then prefers matching `session_meta` / `history_base` metadata found in a bounded 64 KiB prefix. It reads at most the last 8 MiB of the chosen rollout for token-count events, skips partial records, and uses the event timestamp when available. Unknown JSON values are skipped structurally rather than decoded into text. Reading a bounded byte range can include unrelated record bytes in transient memory; those records are not extracted, displayed, logged, or persisted. No database, credential file, or Keychain entry is read directly by the overlay. Do not share real session logs or raw server responses when reporting a problem.

Environment overrides apply only if inherited by the launched app. A Finder launch does not necessarily inherit terminal variables. For an explicit local invocation after quitting other copies:

```sh
CODEX_BINARY=/absolute/path/to/codex CODEX_HOME=/absolute/path/to/codex-home \
  "$HOME/Applications/CodexUsageOverlay.app/Contents/MacOS/CodexUsageOverlay"
```

## Troubleshooting

- **Codex binary missing:** check one of the listed executable paths exists and is executable, or launch with an absolute `CODEX_BINARY` override. Return Codex to the foreground and use Refresh after fixing it.
- **App Server initialization/authentication failure:** a failed handshake or five-second handshake timeout reaps the owned child and retries after 1, 2, 5, then at most every 15 seconds. Open Codex normally and check its login and quota status. The overlay does not perform login or request refresh-token rotation. Missing quota fields may be normal for an unsupported account plan.
- **Context is hidden:** ensure Codex is running and has exactly one active task route. Switching away from the task or opening multiple routed windows intentionally hides context. The private local IPC contract can change between versions. Check only socket existence and ownership/permissions at the listed locations; do not make the socket directory world-writable. The overlay retries IPC with bounded backoff but never substitutes a recent task.
- **Session log missing or no token event:** the verified task may have no compatible local rollout yet, may be remote, or may not have produced a complete token-count event. While Codex is foreground, missing/rotated logs are rediscovered after 1, 2, 5, then at most every 15 seconds. Refresh re-resolves the verified selection immediately. Confirm the intended `CODEX_HOME`. Context limits are not guessed from a model name.
- **No overlay / fixed corner:** bring a non-minimized Codex window on screen, select Show in the menu, and check Accessibility permission for the installed app. With permission denied or unsupported, fixed-corner placement is expected. The tracker hides the overlay for other foreground apps, hidden/minimized/off-screen windows, and unsuitable window metadata. Reset the position offset if needed.
- **Stale values:** context updates follow log writes; account quota polls only while Codex is foreground. Use Refresh. Empty or invalid quota updates do not advance freshness; authoritative reads replace absent windows, while valid sparse notifications preserve omitted windows. Stale account values remain visibly labeled; stale or failed context is hidden until a fresh verified snapshot arrives. Task changes and compaction invalidate old context values.
- **No Tibo banner:** check the unread dot/details first, because denied notification permission does not stop feed processing. Use `通知权限` in the menu to open System Settings. A stale, malformed, oversized, wrong-profile, wrong-host, or more-than-15-minute-old feed cannot create an alert. Manual Refresh still observes the five-minute minimum network spacing.

## Verification and licenses

```sh
swift test
./scripts/package_app.sh
codesign --verify --deep --strict --verbose=2 dist/CodexUsageOverlay.app
test -x dist/CodexUsageOverlay.app/Contents/MacOS/CodexUsageOverlay
```

Tests use synthetic protocol and log fixtures; they do not need your account, real session content, or Accessibility permission. Building and signature verification do not launch the overlay. Manual checks of window movement, multiple displays/Spaces, permission changes, and real Codex integration are separate from the automated checks.

Released under [MIT](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the complete notices from `caisimai/codex-usage-overlay` and `soleillevant0125/codex-token-overlay`.
