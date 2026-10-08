# Tibo Reset Alerts Design

## Summary

Codex Usage Overlay will monitor public messages from Tibo (`@thsottiaux`) that concern Codex quota resets. While the menu-bar application is running, it will check an independent public feed every five minutes, classify relevant messages, deliver a macOS notification, and retain the latest message in the overlay details with an unread badge.

The feature is informational. It does not claim that a global announcement has reached the signed-in account. The existing Codex App Server quota reading remains the authority for the account's actual remaining quota.

## Goals

- Notify within approximately one to six minutes of a qualifying message becoming available upstream.
- Cover explicit reset plans, completed resets, banked resets, and strong reset hints.
- Notify once for the latest qualifying message on first enablement as an installation test.
- Show an unread badge and retain the latest message, Beijing time, source link, and verification state in the expanded overlay.
- Independently confirm that a feed item belongs to Tibo's X account when X's public oEmbed endpoint is available.
- Avoid extra processes, long-lived connections, foreground activation, or unnecessary repeated downloads.
- Preserve the existing privacy boundary: never send Codex account, quota, task, or session data to the feed or X.

## Non-goals

- Predicting whether or when Tibo will reset quota from historical cadence or community probability scores.
- Confirming that a reset has reached the user's individual account.
- Reading the user's X account, asking for an X API token, or scraping an authenticated X session.
- Keeping a full message archive in the application.
- Showing a floating Tibo window while Codex is not in the foreground.
- Starting the overlay automatically with Codex or at login.

## User-visible behavior

### First run and permissions

On the first launch of a version containing this feature, the application asks once for macOS notification authorization. A denial disables only system banners; feed polling, the unread badge, and overlay details continue to work. The menu provides a notification-permission help action that opens the relevant System Settings page.

The first successful fresh feed read treats the newest qualifying Tibo message as new. It produces the same notification and unread state as a future message, providing an immediate installation test. The message ID is persisted before notification delivery so a crash or restart cannot replay it.

### Compact overlay

The compact quota capsule keeps its current text and width. When there is an unread Tibo message, it adds a small dot with an accessibility label. Color is supplementary; the expanded view always exposes a textual state.

### Expanded overlay

The expanded view adds a `Tibo 动态` section containing:

- message category: `重置预告`, `已完成`, `备用重置`, or `强烈暗示`;
- a bounded Chinese summary;
- publication time in `Asia/Shanghai`;
- one of the verification labels described below;
- `查看原帖`, pointing to the validated canonical X URL;
- `Data: codex-reset.com`, linked to `https://codex-reset.com/`;
- last successful feed-check time and a stale/unavailable note when applicable.

Opening expanded details marks the message read and clears the dot. It does not delete the latest message.

### Notification interaction

The notification title identifies the category and whether X confirmation is pending. Its body contains the bounded Chinese summary and does not imply delivery to the user's account.

Selecting a notification does not activate Codex, open a browser, or create another panel. It records a pending reveal request. The next time Codex becomes foreground and the normal overlay is visible, the overlay expands to the Tibo section. The unread dot remains until that section is shown. The original post opens only from `查看原帖` in the details view.

## Data sources and attribution

### Community feed

The primary endpoint is:

`https://codex-reset.com/api/feed?locale=zh`

The endpoint is unauthenticated and publishes feed freshness, the Tibo profile, normalized tweets, structured events, signals, localized summaries, and canonical source URLs. In accordance with its reuse terms, every displayed message includes a visible linked `Data: codex-reset.com` attribution. Requests identify the project with a stable user agent such as:

`CodexUsageOverlay/<version> (+https://github.com/HarryGz/CodexUsageOverlay)`

Polling occurs at most once every five minutes, well below the source's one-minute maximum. Conditional request headers are used when the server supplies `ETag` or `Last-Modified`.

### X author confirmation

For each new structurally valid message ID, the application requests:

`https://publish.x.com/oembed?url=<canonical-post-url>&omit_script=true`

No X account or API token is required. The response must agree on all of the following:

- `provider_name == "X"`;
- `author_name == "Tibo"`;
- `author_url == "https://x.com/thsottiaux"` after safe normalization;
- returned post URL has the same numeric status ID and canonical author handle.

The application does not render or execute the returned HTML.

## Message qualification

The application evaluates only feed entries tied to the validated `thsottiaux` profile and canonical Tibo status URLs. A message qualifies in one of four categories:

1. **Reset announcement**: an explicit future or in-progress quota-reset plan.
2. **Reset completed**: an explicit statement that a reset was processed, propagated, or completed.
3. **Banked reset**: a grant, arrival, or availability update for banked quota resets.
4. **Strong hint**: Tibo-authored reset-related content with a concrete conditional or campaign promise, not a community probability change. The 28-day statement—each day ships either a broadly relevant improvement or a full reset—is the required positive fixture for this category.

Structured fields such as event group, reset kind, banked state, active signal, and `tibo_lane` take precedence over text. A small deterministic text classifier handles only gaps in those structured fields. Ordinary product announcements, unrelated replies, prediction scores, cadence estimates, and community observations without a Tibo post do not qualify.

Only a new numeric Tibo post ID creates an alert. Translation changes, engagement counts, classifier revisions, and edits to a previously seen ID update retained display data without creating another notification.

## Trust and verification states

Verification is intentionally staged so a timely warning does not wait for X availability.

### `… 等待 X 确认`

Before notifying, the application requires the fresh feed to pass structural checks:

- `source == "x-api"`;
- `source_scope == "timeline"`;
- `profile.handle == "thsottiaux"`;
- message ID is decimal digits within a bounded length;
- URL is exactly `https://x.com/thsottiaux/status/<same-id>` after safe normalization;
- publication time is valid and not unreasonably in the future;
- entry passes the local qualification rules.

After these checks, a new message is persisted, marked pending, shown as unread, and notified immediately with an explicit unconfirmed label. X oEmbed confirmation starts asynchronously.

### `✓ X 已确认`

When oEmbed matches the expected provider, author, handle, and status ID, the retained message changes to confirmed. Confirmation does not produce a second system notification.

### `⚠ 来源异常`

If X returns a successful response whose provider, author, handle, or status ID conflicts with the feed, the application marks the item anomalous, removes its delivered notification by stable identifier, and hides its summary and original-post action. The details view retains only the anomaly status and diagnostic-safe timestamps. A structurally invalid feed item is rejected before notification and never becomes the retained latest message.

If oEmbed is merely unavailable or returns a transient server/rate-limit error, the state remains pending rather than anomalous.

## Components

### `TiboFeedClient`

A Foundation networking component owns the five-minute schedule and request lifecycle. It is independent of Codex foreground state. It performs one immediate check at startup, respects HTTP caching, enforces response-size and timeout limits, and publishes parsed results or typed failures. It uses no child process and no long-lived connection.

Sleep does not create catch-up requests. On wake, the client performs at most one immediate check and restarts the five-minute schedule.

### `TiboFeedParser`

A pure parser validates the top-level source and freshness fields, extracts bounded message fields, applies category rules, and returns normalized candidate models. It never exposes raw feed dictionaries to UI code.

Freshness requires both `stale == false` and a parseable `fetched_at` no more than fifteen minutes old. A stale response may update health diagnostics but cannot create a notification or advance the seen-message state.

### `TiboSourceVerifier`

This component validates canonical URLs and performs the X oEmbed check. It accepts only the fixed X endpoint and ignores the returned embed HTML. Transient confirmation failures retry after 15 minutes, then one hour, then every six hours while the same latest item remains pending. A new message replaces that retry target.

### `TiboAlertStore`

The store holds the current feed health, latest retained message, unread state, pending-reveal flag, and verification state. It emits combined changes for the AppDelegate and overlay.

The following data is persisted in the existing `local.codex-usage-overlay` UserDefaults domain:

- latest message ID, category, bounded localized summary, published time, canonical URL, and verification state;
- unread state and pending-reveal state;
- last successful feed-check time;
- the most recent 32 seen message IDs for deduplication;
- HTTP cache validators when Foundation does not manage them automatically;
- whether notification permission has already been requested.

No raw feed body, embed HTML, account identifier, quota snapshot, task identifier, or session content is persisted.

### `TiboNotificationController`

A thin wrapper around `UNUserNotificationCenter` requests authorization, submits notifications using the message ID as a stable identifier, removes an anomalous delivered notification, and converts notification selection into a pending-reveal callback. A protocol boundary makes these behaviors testable without displaying real notifications.

### Existing application integration

`AppDelegate` starts the feed client when the menu-bar app launches and stops it during termination. It does not tie feed polling to `codexForeground`. When notification selection sets a pending reveal, the next valid Codex foreground placement asks `OverlayPanelController` to expand and focus the Tibo section within the existing non-activating panel.

`OverlayPanelController`, `OverlayViews`, and `StatusItemController` receive display-only models. They do not parse network responses or decide trust.

## Scheduling and resource use

- Normal feed interval: five minutes while the overlay process is running.
- Initial feed read: once at startup.
- Wake behavior: one read, then resume the normal interval.
- Feed failure: retain the latest trusted message and use bounded retry/backoff without increasing normal frequency.
- X verification: once for a new ID plus the stated pending retry schedule.
- No request is triggered by every 15-second display refresh.
- No polling occurs after application termination.

## Failure behavior

- **Feed timeout, transport failure, invalid JSON, oversize response, stale feed, or HTTP error:** retain the last message, show source health as unavailable/stale, and do not notify.
- **No qualifying messages:** store a successful check time without changing the message or unread state.
- **Notification permission denied:** continue polling and show unread state; expose permission help in the menu.
- **oEmbed timeout, rate limit, or server error:** retain pending status and retry on the bounded schedule.
- **oEmbed identity mismatch:** mark anomalous, remove the corresponding delivered notification, and hide untrusted content.
- **Persistence corruption:** discard invalid Tibo-specific fields without affecting quota or context state; rebuild a baseline from the next fresh feed.
- **Clock anomaly:** reject messages too far in the future and never infer a publication time from local receipt time.

## Security and privacy constraints

- Outbound hosts are allowlisted to `codex-reset.com` and `publish.x.com`, over HTTPS only.
- Redirects to other hosts are rejected.
- Feed and oEmbed responses have explicit byte limits; user-facing strings have scalar and line limits.
- Canonical post URLs are reconstructed from the validated numeric ID rather than trusted verbatim.
- No embed markup is rendered.
- The notification body is plain text.
- Neither endpoint receives Codex state or a per-user tracking identifier.
- README and the in-app data-source explanation document this new network access, attribution, persistence, and the distinction between public announcement and personal quota delivery.

## Testing

### Unit tests

- Parse valid feed fixtures and reject wrong source, scope, profile, URL, ID, time, size, and stale data.
- Classify reset announcements, completed resets, banked resets, and strong hints.
- Use Tibo's 28-day “improvement or full reset” message as a positive strong-hint fixture.
- Reject ordinary feature posts, unrelated replies, community-only observations, and probability changes.
- Verify oEmbed success, author mismatch, status-ID mismatch, transient failure, and retry scheduling.
- Verify first-enable notification, stable notification identifiers, no confirmation duplicate, anomaly removal, and denied-permission behavior through fakes.
- Verify 32-ID deduplication across restart, feed reordering, and translation/engagement updates.
- Verify unread clearing on expansion and pending reveal only when Codex next becomes foreground.
- Verify five-minute scheduling, wake coalescing, cancellation, conditional requests, and backoff.
- Verify persistence validation and that corruption is isolated from existing usage state.

### Integration and manual verification

- Run the complete Swift test suite and package/sign the release app.
- With a controlled local HTTP fixture, exercise initial pending notification followed by confirmed state without a second notification.
- Verify the current latest qualifying feed item produces the one-time installation-test notification.
- Deny notification permission and confirm the badge/details path still works.
- Select a notification while another app is foreground and confirm no application switch or temporary panel appears; return to Codex and confirm automatic expansion.
- Validate `查看原帖` opens only the canonical Tibo status URL.
- Observe Activity Monitor/network behavior to confirm one process, no long-lived connection, and the five-minute cadence.

## Acceptance criteria

The feature is complete when a fresh qualifying Tibo message is retained and notified once, the compact overlay shows an unread badge, the expanded details expose the message and staged source state, X confirmation updates without a duplicate alert, a notification selection defers expansion until Codex is foreground, stale or malformed sources cannot create an alert, and existing quota/context behavior remains unchanged with the full test suite passing.

