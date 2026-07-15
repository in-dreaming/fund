# Task 17: Build profiles, CI, and acceptance integration

## Objective

Assemble the five build profiles, enforce dependency pruning and API boundaries, run cross-language/integration coverage in CI, and prove the first Foundation release meets its system acceptance contract.

## Rationale

Individual modules are not sufficient if feature flags still link unwanted libraries, callback behavior differs when composed, or consumers bypass facades. This task turns completed capabilities into shippable, audited profiles.

## Design

Profiles select modules exactly as defined in `setup.md`; consumers can override documented optional capabilities without creating invalid combinations. Build logic rejects contradictions with actionable messages. CI has a fast core lane, profile matrix, C/C++ ABI lane, adapter integration lanes, supported OS matrix, and dependency/license audit. Network tests remain loopback-only.

Add small consumer examples for game, agent, and tooling/server shapes. They demonstrate explicit construction, selected executors/backends, operations, cancellation, and deadline-bounded shutdown. They are functional integration fixtures, not product frameworks.

## Implementation scope

- Finalize build feature/profile graph and validate allowed combinations.
- Add link/import inspection proving disabled dependencies are absent and core remains minimal.
- Add CI matrix for formatting, unit/conformance/integration tests, C/C++ ABI, profiles, supported platforms, dependency audit, and release build.
- Add examples and an end-to-end fixture using shared semantics across at least agent-style HTTP/JSON/SQLite and tooling-style filesystem/process/observability flows.
- Generate/assemble third-party notices/licenses for release artifacts and validate completeness.
- Add an acceptance checklist/report generated or checked by CI.

Do not implement missing product runtimes, enable optional features universally, or weaken tests to accommodate platform differences without documenting the contract.

## Dependencies

- Task 07.
- Task 08.
- Tasks 10 through 16.
- Task 09 is transitively required by Tasks 15 and 16.

## Completion checks

- `core`, `game`, `agent`, `tooling`, and `server` build/test successfully in all supported CI environments, with expected optional variations.
- Core contains no network/database/compression/profiler/process symbols; HTTP, SQLite, libuv, yyjson, zstd, LZ4, BLAKE3, and Tracy are absent whenever disabled.
- Boundary scan finds no vendor API outside adapters and public C/Zig APIs expose no vendor type.
- All third-party dependencies have pins, manifests, licenses, integration tests, and removal/replacement paths; release notices are complete.
- End-to-end tests prove unified cancellation/error mapping, clear buffer ownership, predictable callback executors, mock substitution, and graceful shutdown deadline.
- Linking/constructing the game profile creates no implicit thread pool/event loop.
- CI passes format, tests, ABI compatibility, dependency audit, profile pruning, examples, and release packaging.

