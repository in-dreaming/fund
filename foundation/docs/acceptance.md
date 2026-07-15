# Foundation Acceptance Checklist

CI verifies this report through the `check`, `release-check`, profile, ABI, and example lanes.

- Core builds with all optional modules gated out and has no implicit executor, event loop, database, or network construction.
- Profile tests exercise cancellation, error categories, shared-buffer ownership, executor affinity, mock backends, and deadline-bounded shutdown.
- Boundary scanning rejects vendor API use outside `adapters`; public C ABI compilation is checked from C and C++.
- Every manifest has an immutable source pin, a release-input license text, and a corresponding entry in `THIRD_PARTY_NOTICES.txt`.
- Network integration tests use loopback fixtures only; Windows-only curl and libuv lanes are explicitly scoped in CI.
- HTTP completion transfers `Result` ownership to the callback. The callback calls `Result.deinit`; executor rejection, queued-task discard, and operation teardown reclaim undelivered results without invoking business callbacks.
- HTTP TLS verification is always enabled. Tests may select an explicit localhost CA bundle, but the production API has no insecure verification switch. Python 3 is a test-only prerequisite for the loopback TLS fixture and is not a release dependency.
- Dynamic plugins are loaded and executed in the ABI lane on Windows and POSIX. Their lifecycle is `loaded -> started -> loaded -> unloaded`; live leases reject unload and unloaded plugins reject every subsequent operation.
- Process operations deep-copy borrowed requests before work submission, separate work and completion executors, and suppress queued callbacks after teardown. Windows grouped children use a kill-on-close Job Object; POSIX grouped children use a new process group.
- libuv write completion reports both a stable error category and the native status. Queued watch/read/accept deliveries retain owner state and suppress business callbacks after teardown; loop shutdown never waits on an unclosed native handle indefinitely.
- Logging and C-buffer ownership paths are tested at every allocator failure point. Metric identity includes name, kind, ordered label keys and values, and histogram bounds; cardinality counts distinct label value sets.
