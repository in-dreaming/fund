# Foundation Architecture Boundaries

## Ownership

Every public API documents each value as exactly one of: borrowed, caller-allocated, allocator-owned, shared, or handle-owned. Borrowed values name their owner and lifetime. Allocator-owned values name the allocator used for release. Shared values define retain/release behavior. Handle-owned values define the release operation and stale-handle behavior.

`memory.SharedBuffer` is shared ownership: every clone and checked sub-slice owns one reference and must be released. Its byte views are borrowed and become invalid when that owner is released. The final release invokes its configured external callback synchronously on the final releaser's thread, or returns allocator-owned storage to the documented allocator. It deliberately has no public borrowed-data constructor.

`json.JsonDocument` owns parsed JSON storage and must be deinitialized exactly once. `json.JsonValueView`, object keys, and strings are borrowed from that document and cannot outlive it; strings and keys are decoded UTF-8, not source escape spelling. `json.serialize` returns an allocator-owned byte slice released by its caller with the supplied allocator. Compiled schemas own their compilation allocations until `Schema.deinit`; validation does not retain or modify its borrowed input and returns an allocator-owned path only on failure.

## Errors

Public errors use stable `ErrorCategory` values: `invalid_argument`, `invalid_state`, `not_found`, `permission_denied`, `cancelled`, `timeout`, `unavailable`, `resource_exhausted`, `io`, `network`, `protocol`, `corrupted_data`, `unsupported`, and `internal`. Adapters preserve native numeric codes as diagnostic data while mapping to one category. Error messages exclude secrets. No API uses global last-error state.

## C ABI

Exported symbols begin with `fd_`. C ABI structs contain only C-compatible Foundation types; extensible structs begin with `struct_size` and `struct_version`. No Zig standard-library or vendor type crosses the ABI. Handle values round-trip through `uint64_t` and encode a 32-bit slot plus a 32-bit generation.

## Callback Contract Template

Each callback API documents: its executor or invocation thread; maximum invocation count; reentrancy; argument ownership and lifetime; whether callback work may block; deregistration behavior; and behavior during shutdown. Backend threads never invoke business callbacks incidentally.

## Dependency Directions

`core` depends only on Zig std and minimal OS primitives. Product modules depend on Foundation facades. Only `adapters/<vendor>` may include or import that vendor API. Optional adapters may depend on core facades, but core never depends on adapters or optional vendors. Tests may use test backends but may not bypass public ownership, cancellation, or ABI contracts.
