# Foundation

Foundation is the reusable Zig/C runtime layer described by this repository.

## Toolchain

This project is pinned to Zig `0.16.0`. Install that exact release before building.

## Commands

Run these commands from this directory:

```powershell
zig fmt --check build.zig src adapters tests examples tools benchmarks
zig build
zig build test
zig build dependency-check
zig build boundary-check
zig build check
zig build release-check
zig build benchmark -Dprofile=<profile>
zig build benchmark-smoke
```

The default profile is `core`. Profiles are selected with `-Dprofile=core|game|agent|tooling|server`; each resolves its documented capability set and optional capabilities may be explicitly overridden with `-D<capability>=true|false`. `core` rejects all optional capability flags. On non-Windows platforms, use `-Dhttp=false -Dlibuv=false` for the Windows-only curl/libuv integrations.

`zig build examples-test -Dprofile=<profile>` builds and runs the small consumer fixture for that profile. These fixtures construct only host-pumped Foundation components; linking or constructing the game fixture creates no thread pool or event loop.

Release inputs are checked by `zig build release-check`. The generated-release notice input is `third_party/THIRD_PARTY_NOTICES.txt`; every entry is cross-checked with the pinned manifests and retained license texts. The CI acceptance contract is recorded in `docs/acceptance.md`.

`benchmark` emits one JSON result for the selected profile's representative workload. It is an evidence collection tool, not a universal pass/fail gate: follow `docs/platform-optimization.md` to collect calibrated results and evaluate an adapter.
