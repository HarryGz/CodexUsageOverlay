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

`—` means a usable value is missing, unreadable, invalid, or unsupported; it never means zero. Account and context failures are independent. Last known values are retained with a stale label after an error or more than five minutes without a fresh snapshot. Visible countdowns and age labels refresh every 15 seconds without changing the data's timestamp.

When local IPC has no selected route, the app chooses a recent compatible rollout and labels its context **可能非当前任务** (“may not be the current task”). Multiple Codex windows use the most recently received route; routing is not guaranteed to identify the frontmost window. A remembered route survives an unfollow event until IPC disconnects or changes selection. Fallback is approximate and must not be treated as confirmed current-task usage.

## Build, install, and open

From the repository root:

```sh
./scripts/package_app.sh
./scripts/install.sh
open "$HOME/Applications/CodexUsageOverlay.app"
```

Packaging runs all tests, builds a release arm64 executable, includes the license notices, and ad-hoc signs and verifies `dist/CodexUsageOverlay.app`. Installation replaces only the validated `~/Applications/CodexUsageOverlay.app`; the script accepts no destination argument and refuses symlinked paths or an unrelated existing bundle. It does not start the app. This is a local ad-hoc build, not a notarized distribution.

The app has no Dock icon. Use its gauge menu bar icon for show/hide, refresh, position offsets, permission help, data sources, and quit. The overlay is visible only while a supported Codex window is in the foreground. Hiding the overlay does not change the foreground account-refresh policy. Account polling runs every three minutes while Codex is foreground; initial account reads start on the first valid foreground placement. IPC and the selected log watcher stay active until quit.

### Accessibility

Open System Settings → Privacy & Security → Accessibility, add `~/Applications/CodexUsageOverlay.app`, and enable it. The menu's permission-help action can open this settings page; the app never invokes an automatic Accessibility permission prompt. After changing permission, switch away from and back to Codex, or restart the overlay.

**Accessibility usage explanation:** Codex Usage Overlay uses Accessibility access to read the position, size, focus, and minimized state of Codex windows so the floating usage panel can follow them. It does not read editor text or send keystrokes. Without permission, it uses an on-screen window check and a fixed screen-corner position. macOS does not provide a dedicated Info.plist prompt string for AX trust.

### Update and uninstall

Quit the running overlay from its menu before updating. Obtain the updated source, then rerun `./scripts/package_app.sh`, `./scripts/install.sh`, and the `open` command above. Position offsets remain in UserDefaults. A new local signature may require removing and re-adding the app in Accessibility settings.

To uninstall, quit the app, then run:

```sh
./scripts/uninstall.sh
```

This removes only the validated `~/Applications/CodexUsageOverlay.app`. UserDefaults and Accessibility authorization are not removed automatically. You can remove the app's entry manually in Accessibility settings. To also discard saved position offsets, run `defaults delete local.codex-usage-overlay` after quitting. No session data is removed.

## Local data access and privacy

The overlay stores only `overlayOffsetX` and `overlayOffsetY` in the `local.codex-usage-overlay` UserDefaults domain. It does not log or persist account identifiers, credentials, raw responses, task identifiers, session text, messages, prompts, model responses, or tool output. Task routing identifiers exist only in memory. It adds no analytics or direct network client; the local Codex App Server may use Codex's normal authenticated network access to obtain account quota.

The following sources are read:

| Source | Exact location or contract | Retained data |
| --- | --- | --- |
| Codex executable | `CODEX_BINARY`, then `/Applications/ChatGPT.app/Contents/Resources/codex`, `/Applications/Codex.app/Contents/Resources/codex`, `/opt/homebrew/bin/codex`, `/usr/local/bin/codex`, `~/.local/bin/codex` | Executable path for launching `app-server --listen stdio://` |
| App Server | `initialize`, `initialized`, `account/read` with `refreshToken: false`, and `account/rateLimits/read` over child-process stdio | Quota windows, reset times, plan type, update time; unrelated response fields are discarded |
| IPC sockets | Absolute `$CODEX_HOME/ipc/ipc.sock`, `~/.codex/ipc/ipc.sock`, absolute `$TMPDIR/codex-ipc/ipc.sock`, `/tmp/codex-ipc/ipc.sock`, in that order | Routing metadata described below; socket and parent ownership/type/permissions are validated |
| Session logs | `sessions/**/rollout-*.jsonl` and `archived_sessions/**/rollout-*.jsonl` under absolute `$CODEX_HOME`, otherwise `~/.codex` | Session metadata matching and latest complete token-count fields; no-symlink descriptor-based reads |
| macOS window metadata | NSWorkspace, on-screen Quartz window metadata, and optionally Accessibility window attributes for `com.openai.codex` / `com.openai.chatgpt` | Foreground/window geometry used for placement; no text content |

IPC accepts only `broadcast` routing events: `thread-stream-following-changed` reads `sourceClientId` and `params.hostId`, `conversationId`, `following`; `client-status-changed` reads `params.clientId` and `status`. Identifiers are used transiently to select a log and never saved; details show only the final eight characters of a task identifier to help distinguish readings. Unrelated IPC message bodies are structurally skipped. The app does not send task actions through IPC.

Session discovery considers up to 128 candidates, prefers matching `session_meta` / `history_base` metadata found in a bounded 64 KiB prefix, and then orders candidates by modification time. It reads at most the last 8 MiB of the chosen rollout for token-count events, skips partial records, and uses the event timestamp when available. Unknown JSON values are skipped structurally rather than decoded into text. Reading a bounded byte range can include unrelated record bytes in transient memory; those records are not extracted, displayed, logged, or persisted. No database, credential file, or Keychain entry is read directly by the overlay. Do not share real session logs or raw server responses when reporting a problem.

Environment overrides apply only if inherited by the launched app. A Finder launch does not necessarily inherit terminal variables. For an explicit local invocation after quitting other copies:

```sh
CODEX_BINARY=/absolute/path/to/codex CODEX_HOME=/absolute/path/to/codex-home \
  "$HOME/Applications/CodexUsageOverlay.app/Contents/MacOS/CodexUsageOverlay"
```

## Troubleshooting

- **Codex binary missing:** check one of the listed executable paths exists and is executable, or launch with an absolute `CODEX_BINARY` override. Return Codex to the foreground and use Refresh after fixing it.
- **App Server initialization/authentication failure:** open Codex normally, confirm you are signed in, and check that Codex itself can show account limits. Then refresh or restart the overlay. The overlay does not perform login or request refresh-token rotation. Missing quota fields may be normal for an unsupported account plan.
- **IPC unavailable or fallback shown:** ensure Codex is running and select a task. The private local IPC contract can change between versions. Check only socket existence and ownership/permissions at the listed locations; do not make the socket directory world-writable. The overlay retries with bounded backoff and shows fallback context while disconnected.
- **Session log missing or no token event:** the task may have no compatible local rollout yet, may be remote, or may not have produced a complete token-count event. Confirm the intended `CODEX_HOME`, then refresh after task activity. Refresh re-resolves missing/rotated logs and chooses a newer fallback if available. Context limits are not guessed from a model name.
- **No overlay / fixed corner:** bring a non-minimized Codex window on screen, select Show in the menu, and check Accessibility permission for the installed app. With permission denied or unsupported, fixed-corner placement is expected. The tracker hides the overlay for other foreground apps, hidden/minimized/off-screen windows, and unsuitable window metadata. Reset the position offset if needed.
- **Stale values:** context updates follow log writes; account quota polls only while Codex is foreground. Use Refresh. Source errors preserve the last known value and original timestamp instead of manufacturing a fresh reading.

## Verification and licenses

```sh
swift test
./scripts/package_app.sh
codesign --verify --deep --strict --verbose=2 dist/CodexUsageOverlay.app
test -x dist/CodexUsageOverlay.app/Contents/MacOS/CodexUsageOverlay
```

Tests use synthetic protocol and log fixtures; they do not need your account, real session content, or Accessibility permission. Building and signature verification do not launch the overlay. Manual checks of window movement, multiple displays/Spaces, permission changes, and real Codex integration are separate from the automated checks.

Released under [MIT](LICENSE). See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the complete notices from `caisimai/codex-usage-overlay` and `soleillevant0125/codex-token-overlay`.
