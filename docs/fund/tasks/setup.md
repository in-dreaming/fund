# Foundation implementation context

This document is the global context for every task in this directory. Execute a task using only this document and that task document. Task documents must not require `docs/arch.md` or undocumented decisions.

## Product goal

Build a reusable Foundation Layer for Zig/C game runtimes, native agent runtimes, editors, job/task systems, resource tools, profilers, farm clients, CLIs, servers, and tests. It is a governance and adaptation layer: it owns stable cross-system semantics while reusing Zig's standard library, OS facilities, and mature third-party libraries.

The public surfaces are a Zig API and a stable C ABI. The layer must isolate changes in Zig and third-party libraries, make backends replaceable for tests or platforms, and keep dependency versions, licenses, ownership, errors, cancellation, callback threads, and shutdown behavior explicit.

## Non-goals

Do not build an agent loop, workflow engine, production job scheduler, resource task graph, ECS, renderer, gameplay/object system, asset format or packaging strategy, ORM, business RPC protocol, complete VFS, model provider, reflection system, scripting language, TLS/cryptographic algorithm, compression algorithm, general database, or a replacement for Zig's standard containers.

Do not invent a production HTTP stack, JSON parser, profiler, native async I/O backend, general thread pool, or general-purpose allocator without measured evidence and a separate approved decision.

## Architectural invariants

1. Prefer, in order: Zig standard library; mature maintained C/C++ library; existing engine infrastructure; a small adapter; a small missing implementation; custom infrastructure only when necessary.
2. Business modules import Foundation facades, never `curl_*`, `sqlite3_*`, `yyjson_*`, `ZSTD_*`, `uv_*`, or equivalent vendor APIs.
3. Core depends only on Zig std and minimal OS primitives. Network, database, compression, profiler, process, and event-loop code are optional modules/adapters.
4. Linking Foundation must not create threads, event loops, databases, services, or cleanup workers. Construction and teardown are explicit.
5. A replaceable capability has one production default and one test backend. Additional backends require a real platform or product need.
6. Every asynchronous completion names its executor. Never invoke business logic on an incidental backend thread.
7. Cancellation requests stopping work; it does not promise immediate physical cancellation.
8. Graceful shutdown always has a deadline. No unbounded queues or unbounded waits.
9. Public data ownership is one of: borrowed, caller-allocated, allocator-owned, shared, or handle-owned. Document it on every public API.
10. C ABI types contain no Zig-only or third-party types. Extensible structs start with `struct_size` and `struct_version`.
11. Preserve native error codes while mapping them to stable Foundation categories. Do not use global `last_error` state or expose secrets in messages.
12. Optional modules must be completely removable through build features.

## Required repository shape

```text
foundation/
  build.zig
  build.zig.zon
  include/foundation.h
  src/{core,memory,containers,text,ids,error,time,sync,async,executor,channel,io,filesystem,network,serialization,compression,hash,database,logging,metrics,trace,process,plugin,platform,cabi,testing}/
  adapters/{curl,libuv,yyjson,sqlite,zstd,lz4,blake3,mimalloc,tracy,mbedtls,engine}/
  third_party/{manifests,licenses,patches,build}/
  examples/
  tests/
```

Create directories only when a task needs them. Keep public module roots stable and avoid wrappers that merely rename a single std call.

## Naming and API conventions

- Use `foundation` as the Zig package and `fd_` for exported C symbols/types.
- Pass `std.mem.Allocator` explicitly for allocator-owned results.
- Use explicit integer units/types: `Duration`, `MonotonicInstant`, and wall timestamps; timeouts use monotonic time.
- Stable handles encode a 32-bit slot index and 32-bit generation and round-trip through C `uint64_t`.
- Facades use an opaque pointer plus a const vtable unless compile-time polymorphism is materially better and does not leak into the C ABI.
- Every callback contract documents invocation thread/executor, maximum calls, reentrancy, argument lifetime, blocking policy, deregistration, and shutdown behavior.
- Every resource type supports deterministic `deinit`/release. Destruction is idempotent only where explicitly documented and tested.
- Public errors use `ErrorCategory`: `invalid_argument`, `invalid_state`, `not_found`, `permission_denied`, `cancelled`, `timeout`, `unavailable`, `resource_exhausted`, `io`, `network`, `protocol`, `corrupted_data`, `unsupported`, `internal`.
- Keep source comments concise. Put durable public contracts in doc comments and user-facing design notes in `foundation/docs/` when a task asks for them.

## Dependency governance

Every third-party dependency needs a machine-readable manifest containing name, pinned version and commit/hash, license, purpose, target platforms, static/dynamic linkage, source modifications, patch references, security update policy, replacement/removal path, replacement cost, and owner. Do not use floating branches. Store license texts in release inputs and retain patches for modified sources.

Permissive, officially maintained libraries are preferred. BSL, GPL, AGPL, SSPL, and similar licenses require explicit approval recorded in the manifest. Each adapter has integration tests and is the only place that includes its vendor API.

Default choices are libcurl for HTTP/TLS transport, yyjson for high-frequency JSON, `std.json` for configuration/simple Zig values, zstd for general compression, LZ4 for fast decompression, BLAKE3 for content hashes, SQLite as an optional database, and Tracy for performance timelines. libuv is for tools/servers, not a game-runtime requirement. mimalloc and Mbed TLS are optional and evidence-driven.

## Testing rules

Use `zig test`, `std.testing`, and the standard testing allocator. Unit tests live beside implementation where useful; cross-module and ABI tests live under `foundation/tests/`. Tests must be deterministic and must not require public internet access. Adapter integration tests may launch loopback fixtures or use checked-in fixtures.

Test ownership/release, allocation failure, stale handles, integer boundaries, cancel/complete races, callback executor affinity, deadline behavior, partial I/O, backend error mapping, and shutdown with work in flight. C ABI tests compile at least one C translation unit against `foundation.h` and link/run it.

Unless the task adds a narrower command, completion requires:

```powershell
cd foundation
zig fmt --check build.zig src adapters tests examples
zig build test
```

If the pinned Zig version does not support `zig fmt --check`, use the equivalent non-mutating formatter check established by Task 00. Optional adapter tasks also run their feature-specific build/test step. Record skipped platform checks with a reason; do not report them as passed.

## Build profiles

- `core`: base, memory conventions, handles, error, time, cancellation, future/operation, executor interface, buffer, shutdown, C ABI base; no network/database/compression/profiler/process.
- `game`: core, engine executor adapter, filesystem, compression, hash, logging, Tracy, optional HTTP.
- `agent`: core, curl HTTP/SSE, yyjson, SQLite, logging, metrics, trace, optional process.
- `tooling`: core, libuv, curl, yyjson, SQLite, process, file watch, compression, optional Tracy.
- `server`: core, libuv or host event loop, curl, SQLite, metrics, trace, optional mimalloc.

Feature defaults must be minimal. A disabled feature must neither compile nor link its dependency.

## Delivery workflow

1. Read this file and the assigned task completely.
2. Inspect the current worktree and completed dependency tasks. Preserve unrelated changes.
3. Confirm each declared dependency by checking its completion checks or artifacts. Stop and report a real missing prerequisite rather than silently duplicating it.
4. Implement only the task scope. Small supporting fixes in dependency code are allowed when required; document them.
5. Format and run the task checks plus relevant regression tests.
6. Summarize changed files, behavior, tests, platform gaps, and any decision that future tasks must know.

## Dependency graph

```text
00 bootstrap/governance
  -> 01 base types/error/time
  -> 02 ids/handles
  -> 03 shared buffer/memory
  -> 04 cancellation/shutdown
  -> 05 future/operation/executor
       -> 06 channels/mailboxes
       -> 08 filesystem
       -> 09 process
       -> 11 HTTP/SSE/curl
  01..05 -> 07 C ABI/plugin boundary
  01,03 -> 10 JSON/schema
  01,03,08 -> 12 compression/hash
  01,04,05 -> 13 SQLite
  01,03,04,05,06,08 -> 14 logging/metrics/trace
  04,05,08,09,11 -> 15 libuv/tooling adapters
  01..15 -> 16 deterministic testing/fault injection
  07,08,10..16 -> 17 profiles/CI/integration acceptance
  17 -> 18 evidence-gated platform optimization
```

Tasks with multiple prerequisites may be worked concurrently once all listed dependencies are complete.
