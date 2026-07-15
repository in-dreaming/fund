# Foundation

Foundation is a reusable Zig and C runtime layer for applications that need explicit ownership, executor affinity, bounded shutdown, and optional native adapters without pulling every dependency into every build.

The implementation lives in [`foundation/`](foundation/). The public C ABI is versioned independently and currently remains at `FD_ABI_VERSION == 1`.

## Repository layout

- `foundation/src/`: dependency-light facades and runtime primitives.
- `foundation/adapters/`: optional curl, libuv, SQLite, compression, JSON, hashing, and tracing integrations.
- `foundation/include/foundation.h`: stable C ABI header.
- `foundation/tests/`: ABI consumers, native fixtures, fault injection, and loopback fixtures.
- `foundation/docs/`: architecture, acceptance contracts, ADRs, and benchmark evidence.
- `docs/fund/tasks/`: stable, dependency-ordered implementation and follow-up tasks.
- `scripts/run-codex-tasks.ps1`: resumable task runner; generated state is kept out of Git.

## Quick start

Install Zig `0.16.0`, then run from the implementation directory:

```powershell
cd foundation
zig build test -Dprofile=core
zig build examples-test -Dprofile=core
zig build check
```

Profiles are `core`, `game`, `agent`, `tooling`, and `server`. See [`foundation/README.md`](foundation/README.md) for feature composition, platform prerequisites, ABI checks, and the full acceptance matrix.

## Design constraints

- Borrowed, allocator-owned, shared, callback-owned, and handle-owned values have distinct documented lifetimes.
- Business callbacks run only through the executor selected by the caller.
- Optional vendor code stays behind adapters and is removed from profiles that do not enable it.
- Production TLS verification cannot be disabled through the HTTP API.
- C ABI v1 symbols and layouts remain compatible while the pre-stable Zig API may evolve.

Architecture details are in [`foundation/docs/architecture.md`](foundation/docs/architecture.md), and current acceptance requirements are in [`foundation/docs/acceptance.md`](foundation/docs/acceptance.md).
