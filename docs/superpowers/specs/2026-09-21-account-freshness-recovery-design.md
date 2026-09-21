# Account Freshness Recovery Design

Date: 2026-09-21

## Problem

Account quota snapshots refresh every 180 seconds while Codex is foreground.
When Codex leaves the foreground, the timer stops. Returning to Codex starts a
new timer whose first refresh is another 180 seconds away, while the UI marks
snapshots older than 300 seconds stale. A normal foreground/background cycle
can therefore show `已过期` for up to three minutes even though a read-only
refresh could recover immediately.

Separately, any transient App Server request error currently changes a recent
valid account snapshot to stale immediately. Snapshot age, rather than one
failed attempt, should determine whether a cached account value is stale.

## Required Behavior

- A transition from background to foreground sends one immediate pair of
  read-only `account/read` and `account/rateLimits/read` requests when the App
  Server is already initialized.
- Repeated foreground notifications while already foreground do not send
  additional immediate requests.
- Initial App Server startup keeps its existing handshake and post-initialize
  request sequence without duplicates.
- The existing 180-second foreground refresh interval remains unchanged.
- A request error preserves a valid account snapshot as live while its age is
  at most 300 seconds.
- An account snapshot older than 300 seconds becomes stale, and a failure with
  no prior snapshot remains unavailable.
- Context failure semantics remain unchanged.

## Resource and Security Constraints

- Recovery is event-driven; no new timer, polling loop, background process, or
  network client is added.
- Account reads continue through the installed Codex App Server and remain
  read-only.
- No credentials, raw responses, or user content are read or persisted.

## Verification

- Synthetic App Server tests prove foreground resume sends requests promptly
  with a long periodic interval and that duplicate foreground notifications do
  not send duplicate refreshes.
- Store tests prove a recent account snapshot survives one failure as live and
  an expired snapshot is stale.
- The complete Swift test suite, release packaging, signature verification,
  installation, and a live foreground/background refresh check must pass.
