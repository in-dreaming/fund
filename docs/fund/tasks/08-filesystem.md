# Task 08: Filesystem facade and standard backends

## Objective

Implement a replaceable filesystem facade with safe paths, synchronous/native access, memory/mock backends, and executor-bound async reads.

## Rationale

Tests, overlays, agent sandboxes, virtual paths, and future remote/platform storage need one filesystem contract. The facade should add lifecycle, safety, error, cancellation, and testing semantics while delegating local file operations to Zig std/OS.

## Design

Use an opaque `FileSystem` plus vtable. Define normalized Foundation paths independently of host separators and reject traversal outside a configured root. Operations distinguish partial read/write from complete helpers. Atomic write uses same-filesystem temporary creation, flush policy, and rename with documented durability limits.

Implement `NativeFileSystem`, `MemoryFileSystem`, read-only wrapper, overlay composition, sandbox wrapper, and mock/fault hooks. Async read returns an operation/future of `SharedBuffer` and posts completion to the requested executor. It may use host scheduling or a supplied executor; construction never creates a hidden pool.

## Implementation scope

- Define path validation/normalization, file metadata, open/read/write/seek/close, directory operations, atomic write, and mmap capability/error contract.
- Implement native and memory backends plus read-only, overlay, and sandbox wrappers.
- Implement async read with cancellation, limits, partial-I/O handling, ownership, and selected executor.
- Define file-watch event types for Task 15 without implementing native watching here.
- Add mock hooks for partial reads/writes, disk-full, permission, and disappearance races.

Do not build a complete VFS, remote filesystem, or native async I/O backend.

## Dependencies

- Tasks 01 through 05.

## Completion checks

- A shared conformance suite passes for native temp-directory and memory backends.
- Tests cover traversal/absolute-path rejection, normalization, symlink escape policy, atomic replacement, partial I/O, disk-full injection, read-only enforcement, overlay precedence, cancellation, body/size limits, and callback executor affinity.
- Async and sync paths return equivalent bytes/errors and release all buffers on cancel/rejection.
- Core-only builds remain free of filesystem if the feature is disabled.

