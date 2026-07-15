# Task 19: Platform runtime acceptance closure

## Objective

Close the runtime-verification gaps left by the Foundation review fixes on native Windows and Linux hosts, without weakening production security or treating cross-compilation as runtime evidence.

## Rationale

The ownership, lifecycle, process, curl, and libuv fixes compile and pass the available Windows suites. The repository also contains a Python loopback HTTP/TLS fixture and fixed localhost CA/server material. Two acceptance areas still need direct host evidence: the curl fixture has not run because Python 3 was unavailable on the implementation host, and the POSIX plugin/process-group behavior has only been compiled rather than exercised on Linux.

## Implementation scope

- Add a deterministic build/test lane that starts `tests/fixtures/http_fixture.py`, waits for readiness without fixed sleeps, and always terminates/reaps the fixture.
- Exercise request bodies, chunked responses, ordered duplicate response headers, redirects, response limits, timeout, cancellation, and client teardown with an in-flight request.
- Run HTTPS twice with the checked-in localhost certificate: once with `localhost-ca.pem` configured and once without it. The first must succeed and the second must fail certificate validation. Do not add an insecure TLS switch.
- Run the fixture plugin lifecycle test on both Windows and Linux, including feature negotiation, host context, live-lease unload rejection, stop, repeated operations, and post-unload rejection.
- Add a Linux helper-process runtime test for `.new_group` cancellation/timeout and verify that the child and its descendant are terminated and reaped with no orphan process.
- Keep Python 3 test-only. Do not add Python, TLS, HTTP, process, or scheduling libraries to production artifacts.
- Update CI and the acceptance report with exact platform coverage. A skipped or unavailable platform is reported as not run, never as passed.

## Dependencies

- Tasks 09, 11, 15, and 17.
- Review-fix commit following Task 18.

## Completion checks

- `python --version` (or the platform-equivalent Python 3 launcher) identifies Python 3 on the Windows curl runner.
- The HTTP and trusted/untrusted TLS fixture tests pass on Windows and leave no fixture process behind.
- `zig build -Dprofile=core cabi-test` runs the fixture plugin lifecycle on both Windows and Ubuntu CI hosts.
- The Linux process-group helper test proves descendant termination and reap after cancellation and timeout.
- `zig fmt --check build.zig src adapters tests examples tools benchmarks` passes.
- `zig build check` passes.
- All five profile test/example lanes and the C/C++ ABI lanes remain green on their supported platforms.
- Documentation distinguishes direct runtime results, cross-compilation results, skipped lanes, and remaining platform risk.
