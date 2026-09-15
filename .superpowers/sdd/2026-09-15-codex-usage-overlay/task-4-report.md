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

---

## Fix round 1/5

### Root cause and design choice

The original monitor re-opened a validated pathname, used an unbounded
`readToEnd`, had no callback identity, and could synchronously dispatch its
own teardown. The smallest system-only replacement is descriptor binding:
`open`/`openat` walk every `CODEX_HOME` component with `O_NOFOLLOW`, validate
the resulting regular file with `fstat`, and use that one descriptor for both
bounded `pread` and the filesystem dispatch source. A byte-level structural
scanner replaces line-wide JSON object deserialization; it decodes only
recognized keys and token/session fields and skips all other JSON values.

### Per-finding coverage

1. Queue-aware `performSync` avoids self-redispatch; the release-during-active-
   refresh monitor test covers teardown without deadlock.
2. A monotonically increasing generation is captured on every callback and
   invalidated on select/stop. Tests cover rapid reselection and
   stop-before-main delivery; stale callback ordering remains current-only.
3. `fstat` captures length, then `pread` reads exactly `min(size, 8 MiB)` and
   reports a leading boundary cut. Tests cover file growth after captured size
   and dropping the leading possibly-partial record.
4. Descriptor opening rejects symlink components and keeps the verified object
   bound after pathname replacement. A synthetic external-symlink replacement
   test proves later reads stay on the original descriptor.
5. The scanner exposes only structural number lexemes, then parses that allowed
   primitive with Core Foundation boolean type identity (`CFBooleanGetTypeID`),
   so JSON `0`/`1` pass while `true` is rejected; each has a regression test.
6. The scanner skips unrelated sentinel payload strings without decoding or
   persisting them; parser and resolver sentinel fixtures cover that route.
7. A compaction marker with no bounded pre-marker baseline now stays
   unavailable; a one-post-marker replay fixture covers the case.

The parser no longer substitutes `now()` when both token timestamp and file
metadata are unavailable: it returns no snapshot. Monitor tests also assert
main-thread callback delivery.

### Fix-round RED/GREEN evidence

RED, after adding regressions before the new parser boundary API:

```sh
swift test --filter ContextLogParserTests
swift test --filter SessionPathResolverTests
swift test --filter ContextLogMonitorTests
```

The compile failed as intended with `extra argument
'leadingRecordMayBePartial' in call`, proving the boundary-aware parser
contract did not exist. After implementation, focused GREEN results were:

```sh
swift test --filter ContextLogParserTests
# 12 tests, 0 failures
swift test --filter SessionPathResolverTests
# 7 tests, 0 failures
swift test --filter ContextLogMonitorTests
# 4 tests, 0 failures
swift test
# 44 tests, 0 failures (5.393 seconds)
git diff --check
# exit 0
```

### Fix-round concerns

The structural scanner intentionally treats escaped discriminator strings as
unrecognized rather than decoding them. This is conservative for a security-
bounded telemetry reader; normal token/session schema discriminators are ASCII
and still covered by the synthetic fixtures.

---

## Fix round 2/5

### Regressions and fixes

- `testRejectsNewlineTerminatedIncompleteTokenRecord` proves a record is not
  accepted until every nested object closes and the line is fully consumed.
  `JSONStructuralScanner` now propagates validity through unterminated strings,
  containers, object elements, and trailing data.
- `testRecoversAfterTwoDistinctPostCompactionCountsWithoutBaseline` preserves
  suppression for one count after a marker while allowing the latest count once
  two distinct bounded post-marker usages establish freshness.
- `testReleaseDuringQueuedRefreshCompletesTeardownWithoutDeadlock` uses a
  suspended injected worker queue: queued refresh holds the last reference,
  the test drops its reference, resumes the worker, and waits for weak release.
  The monitor's queue-aware deinit therefore executes on the owning queue
  without sync redispatch.
- `testReturnsNilWhenEventTimestampAndModificationDateAreMissing` explicitly
  locks the unknown-timestamp rule.

### RED/GREEN evidence

After adding the regressions first, ran:

```sh
swift test --filter ContextLogParserTests
swift test --filter ContextLogMonitorTests
```

Both builds failed at RED on the missing deterministic lifecycle seam:
`extra argument 'workerQueue' in call`. The parser regressions were compiled
at the same time and encoded the failing completion/compaction behaviors.

After implementation:

```sh
swift test --filter ContextLogParserTests
# 15 tests, 0 failures
swift test --filter ContextLogMonitorTests
# 4 tests, 0 failures
swift test
# 47 tests, 0 failures (5.172 seconds)
git diff --check
# exit 0
```

### Self-review

- Checked all scanner paths now require a terminal object delimiter and end of
  input before exposing structural fields.
- Checked the two-post-marker path returns only the newest value and preserves
  single-count suppression.
- Checked worker-queue injection is a normal scheduling dependency, not a
  test-only lifecycle method; production defaults remain unchanged.
- Used synthetic fixtures only; no real session or credential data entered the
  tests or report.

---

## Fix round 3/5

### Regressions and fixes

- `testRejectsTokenRecordWithTrailingRootComma` rejects a root-object comma
  without a following key/value.
- `testRejectsTokenRecordWithIgnoredFieldMissingValue` rejects a missing value
  in an ignored field.
- `testRejectsTokenRecordWithMalformedIgnoredContainer` rejects an ignored
  nested object/array with mismatched delimiters.
- `testReleaseDuringQueuedRefreshCompletesTeardownWithoutDeadlock` now waits
  for both weak release and a sentinel enqueued on the same worker. The latter
  proves queue-aware deinit/stop returned rather than merely beginning.

`JSONStructuralScanner` now validates ignored values as complete JSON grammar:
objects and arrays have matching delimiters and required members/elements;
strings validate JSON escapes without decoding their contents; literals and
numbers are structurally checked. It still decodes only recognized schema
keys/values, with no logging or persistence of ignored values.

### RED/GREEN evidence

After adding the three parser regressions, before changing the scanner:

```sh
swift test --filter ContextLogParserTests
# 18 tests: the 3 new tests failed because malformed records yielded snapshots
swift test --filter ContextLogMonitorTests
# 4 tests, 0 failures; the strengthened sentinel lifecycle assertion already
# passed against the existing queue-aware teardown implementation
```

After the grammar fix:

```sh
swift test --filter ContextLogParserTests
# 18 tests, 0 failures
swift test --filter ContextLogMonitorTests
# 4 tests, 0 failures
swift test
# 50 tests, 0 failures (5.465 seconds)
git diff --check
# exit 0
```

### Self-review and concerns

- Reviewed comma and delimiter handling in both recognized objects and skipped
  nested values; incomplete, mismatched, and trailing-comma values cannot
  publish a snapshot.
- The sentinel test is bounded at two seconds and avoids a hanging RED path;
  it proves the post-deinit worker queue continues.
- All fixtures remain synthetic structural token metadata. No message,
  prompt, response, tool-output, authentication, cookie, or credential data
  is read, logged, or persisted.

---

## Fix round 4/5

### Finding and smallest fix

Ignored objects and arrays recursively called `skipValue` without a nesting
bound, allowing a record well below the 8 MiB tail limit to exhaust the stack.
`JSONStructuralScanner` now explicitly permits at most 64 nested ignored
containers. Both container paths check the same depth before entering another
container; exceeding it invalidates the entire record. Recognized schema
objects have a separate fixed call depth of four. Scalar and string scanning
remain iterative, and ignored strings are still skipped without decoding or
materializing their contents.

### Files changed

- `Sources/CodexUsageCore/ContextLogParser.swift`
- `Tests/CodexUsageCoreTests/ContextLogParserTests.swift`
- This report: `.superpowers/sdd/2026-09-15-codex-usage-overlay/task-4-report.md`

### RED evidence

Added regression tests before modifying production code, then ran:

```sh
swift test --filter ContextLogParserTests
# exit 1; 22 tests, 3 assertion failures, 0 unexpected failures
```

The array and object tests first attempt 65 nested containers. The mixed test
first attempts 33 array/object pairs (66 containers), which also detects
incorrect separate budgets for each container type. Each failed because a
snapshot was returned. Each test stops immediately after that shallow failure,
so the unfixed scanner never receives its stress fixture. The first RED run
used 65 mixed pairs; a second RED run confirmed the stronger 33-pair fixture.
The 64-level sibling acceptance test passed before the fix.

### GREEN evidence

After adding the shared depth bound:

```sh
swift test --filter ContextLogParserTests
# exit 0; 22 tests, 0 failures (0.185 seconds)
swift test
# exit 0; 54 tests, 0 failures (5.840 seconds)
git diff --check
# exit 0; no whitespace errors
```

All three stress paths now run: 200,000 arrays, 200,000 objects, and 200,000
array/object pairs. Each synthetic record is asserted below the 8 MiB cap and
is rejected. Two sibling ignored values at the supported 64-level boundary
still produce the expected token snapshot.

### Self-review and concerns

- Both recursive edges propagate one shared depth, so mixed containers cannot
  bypass the bound. No recursive path decodes ignored keys or string values.
- Rejection preserves `isValid == false` through unwinding and prevents all
  accumulated token fields from being published.
- The production bound is fixed and conservative; no test-only safety seam
  or configurable bypass was added.
- Intentionally, otherwise valid JSON with more than 64 ignored container
  levels is ignored as an untrusted record. No additional concerns remain for
  the reported stack-overflow finding.
