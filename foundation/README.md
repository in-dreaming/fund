# Foundation developer guide

Foundation is the reusable Zig/C runtime package in this repository. It provides dependency-light ownership and async primitives, then layers optional native capabilities behind profile-gated adapters.

## Requirements

- Zig `0.16.0` exactly.
- Windows for the vendored curl and libuv adapter lanes.
- Python 3 with the standard-library `ssl` module for loopback HTTP/TLS fixture tests. Python is test-only and is not linked or packaged.
- A C and C++ compiler are supplied through Zig for ABI consumer tests.

## Profiles

| Profile | Default capabilities |
| --- | --- |
| `core` | Base errors, time, IDs, memory, cancellation, executors, channels, C ABI, and plugins |
| `game` | Filesystem, compression, zstd, LZ4, BLAKE3, and Tracy |
| `agent` | HTTP/curl, SQLite, JSON, logging, metrics, and tracing |
| `tooling` | Agent capabilities plus process, filesystem, compression, and libuv |
| `server` | HTTP/curl, SQLite, JSON, libuv, logging, metrics, and tracing |

Select a profile with `-Dprofile=core|game|agent|tooling|server`. Optional capabilities can be overridden with `-D<capability>=true|false` when permitted by that profile. `core` rejects optional capability flags.

The vendored curl and libuv integrations are currently Windows-only. Portable Linux lanes disable them explicitly, for example:

```sh
zig build test -Dprofile=tooling -Dhttp=false -Dlibuv=false
```

## Common commands

Run commands from this directory:

```powershell
zig fmt --check build.zig src adapters tests examples tools benchmarks
zig build test -Dprofile=core
zig build examples-test -Dprofile=core
zig build cabi-test -Dprofile=core
zig build check
zig build dependency-check
zig build boundary-check
zig build release-check
zig build benchmark-smoke -Dprofile=core
```

Run the full local Windows profile matrix with:

```powershell
$profiles = @('core', 'game', 'agent', 'tooling', 'server')
foreach ($profile in $profiles) {
    zig build test "-Dprofile=$profile"
    zig build examples-test "-Dprofile=$profile"
}
```

`check` includes dependency, release-input, and boundary governance. `cabi-test` builds/runs C11 and C++17 consumers and executes the fixture plugin lifecycle. `benchmark-smoke` validates the benchmark harness without imposing uncalibrated cross-machine thresholds.

## Ownership and callbacks

- `SharedBuffer` clones and sub-slices each own one reference and must call `release`.
- HTTP completion transfers `http.Result` ownership to the callback; the callback calls `Result.deinit`. Rejected or discarded delivery is reclaimed by Foundation.
- Process completion transfers a successful `OperationResult`; queued completion and stream callbacks are suppressed after operation teardown.
- Plugin leases must be released before unload. An unloaded plugin cannot be restarted or reacquired.
- libuv stream/listener/watch delivery is executor-bound. Teardown closes native handles and suppresses queued business callbacks.

The public C header is [`include/foundation.h`](include/foundation.h). Its v1 ABI remains stable; Zig APIs may change while the package is pre-stable.

## Native fixtures

The curl fixture is [`tests/fixtures/http_fixture.py`](tests/fixtures/http_fixture.py). Fixed localhost-only CA, certificate, and private key material lives in `tests/fixtures/tls/`; it must never be reused outside tests. Production HTTP always verifies both the certificate chain and host name.

Platform evidence must distinguish compilation from execution. The remaining direct runtime work is tracked in [`../docs/fund/tasks/19-platform-runtime-acceptance.md`](../docs/fund/tasks/19-platform-runtime-acceptance.md).

## Documentation

- [`docs/architecture.md`](docs/architecture.md): ownership, ABI, callback, and dependency boundaries.
- [`docs/acceptance.md`](docs/acceptance.md): current acceptance contract and platform scope.
- [`docs/platform-optimization.md`](docs/platform-optimization.md): benchmark evidence gate.
- [`docs/adr/`](docs/adr/): evaluated platform and dependency decisions.
