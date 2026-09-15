# Task 4 — Context Session Resolution and Token Parsing

## Status

Implemented the safe selected-session resolver, bounded structural token parser,
and selected-log file monitor. All fixtures are synthetic temporary JSONL files;
no real Codex rollout, message, prompt, response, tool output, auth file, cookie,
or credential was read or included.

## Files changed

- `Sources/CodexUsageCore/SessionPathResolver.swift`
- `Sources/CodexUsageCore/ContextLogParser.swift`
- `Sources/CodexUsageCore/ContextLogMonitor.swift`
- `Tests/CodexUsageCoreTests/SessionPathResolverTests.swift`
- `Tests/CodexUsageCoreTests/ContextLogParserTests.swift`
- `Tests/CodexUsageCoreTests/ContextLogMonitorTests.swift`

## TDD evidence

### RED

1. Added resolver and parser tests before their production types existed.
2. Ran:

   ```sh
   swift test --filter SessionPathResolverTests
   swift test --filter ContextLogParserTests
   ```

   Both failed at compile time for the intended reason: `cannot find
   'SessionPathResolver' in scope` and `cannot find 'ContextLogParser' in scope`.
3. Added the focused monitor stale-callback test before re-adding its production
   type. Ran:

   ```sh
   swift test --filter ContextLogMonitorTests
   ```

   It failed for the intended missing symbols: `ContextLogMonitor` and
   `ContextLogMonitorError` were not in scope.

### GREEN

After the minimal implementations:

```sh
swift test --filter SessionPathResolverTests
# 4 tests, 0 failures
swift test --filter ContextLogParserTests
# 7 tests, 0 failures
swift test --filter ContextLogMonitorTests
# 1 test, 0 failures
swift test
# 33 tests, 0 failures (5.192 seconds)
git diff --check
# exit 0, no whitespace errors
```

## Security and bounds checks

- The resolver accepts only canonical UUID syntax, searches only `sessions` and
  `archived_sessions`, caps matching discovery at 128, admits only
  `rollout-*.jsonl` regular files, and resolves paths before requiring that they
  remain under the supplied `CODEX_HOME`.
- Metadata selection reads at most the first 64 KiB and recognizes only
  `session_meta` / `history_base` identifiers. It neither stores nor logs event
  body text.
- The parser limits input to the final 8 MiB, drops incomplete leading/trailing
  JSONL records, and recognizes only the root/payload/info fields needed for a
  valid `token_count` or structural compaction marker.
- The monitor uses `DispatchSourceFileSystemObject` for writes, renames, and
  deletion; it debounces write refreshes by 100 ms, closes the descriptor by the
  source cancellation handler, and independently limits its file read to 8 MiB.

## Callback ruling

`ContextUsageSnapshot` deliberately remains unchanged and has no stale field.
When an event is older than 300 seconds, `ContextLogMonitor` sends the snapshot
through `onSnapshot` on the main queue and then sends
`ContextLogMonitorError.staleSnapshot` through `onError` on the same queue.
The monitor test verifies this order. Task 6/9 can therefore retain the value as
stale without a contradictory snapshot flag.

## Self-review

- Confirmed resolver tests cover canonical UUID lookup, traversal rejection,
  external symlink rejection, and latest valid continuation preference.
- Confirmed parser tests cover valid structural token data, partial trailing
  writes, disallowed `total_token_usage`, zero/missing limits, compaction
  suppression/recovery, and timestamp fallback.
- Confirmed the monitor never prints or reports parsed log contents; errors are
  fixed generic reasons only.
- Confirmed `swift test` and `git diff --check` passed after the final changes.

## Concerns

The monitor’s filesystem behavior is proven with a deterministic synthetic
initial refresh and stale-callback test; actual `DispatchSource` rename/delete
delivery is platform-provided and remains exercised through the production
lifecycle rather than timing-sensitive integration tests.
