# Task 03: Memory conventions and SharedBuffer

## Objective

Codify ownership rules and implement a thread-safe, sliceable `SharedBuffer` that can safely cross module and C ABI boundaries.

## Rationale

Backends can return heap, mmap, C-owned, network, or shared-memory storage. A single buffer lifetime model prevents allocator mismatches and dangling slices while allowing zero-copy handoff.

## Design

`SharedBuffer` contains shared `Storage`, offset, and length. Storage owns an atomic reference count, base pointer/length, mutability, memory tag/debug metadata, and a release callback plus userdata. Slices retain the same storage and validate bounds. The last release invokes the callback exactly once on the documented thread; callback execution must not depend on a hidden worker.

Constructors cover allocator-owned copies, adopted external memory, and borrowed data only when the lifetime is statically contained and cannot escape as shared ownership. Mutable access is allowed only when storage policy guarantees it; slicing does not bypass that policy.

## Implementation scope

- Add ownership guidance for borrowed, caller-allocated, allocator-owned, shared, and handle-owned APIs.
- Implement memory tags and optional debug allocation metadata without a custom heap.
- Implement `SharedBuffer` clone/retain, release, read slice, checked sub-slice, mutability policy, and custom release callback.
- Provide allocator-owned and external-adoption constructors with explicit failure cleanup.
- Provide conversion primitives needed by Task 07's `fd_buffer`; do not export C symbols yet.
- Add an optional budget/tracking decorator interface and a failing allocator test helper if not already supplied by the pinned Zig version.

Do not integrate mmap, curl, or mimalloc in this task.

## Dependencies

- Task 00.
- Task 01.

## Completion checks

- Tests prove one and only one release callback after clones and nested slices are released in varied orders.
- Multi-threaded retain/release stress tests pass under the repository's race-detection strategy where supported.
- Tests cover zero-length buffers, out-of-range slicing, allocator failure, external callbacks, read-only enforcement, budget exhaustion, and leak-free teardown.
- Public buffer APIs explicitly state ownership and release-thread behavior.

