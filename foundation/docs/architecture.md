# Foundation Architecture Boundaries

## Ownership

Every public API documents each value as exactly one of: borrowed, caller-allocated, allocator-owned, shared, or handle-owned. Borrowed values name their owner and lifetime. Allocator-owned values name the allocator used for release. Shared values define retain/release behavior. Handle-owned values define the release operation and stale-handle behavior.

## Errors

Public errors use stable `ErrorCategory` values: `invalid_argument`, `invalid_state`, `not_found`, `permission_denied`, `cancelled`, `timeout`, `unavailable`, `resource_exhausted`, `io`, `network`, `protocol`, `corrupted_data`, `unsupported`, and `internal`. Adapters preserve native numeric codes as diagnostic data while mapping to one category. Error messages exclude secrets. No API uses global last-error state.

## C ABI

Exported symbols begin with `fd_`. C ABI structs contain only C-compatible Foundation types; extensible structs begin with `struct_size` and `struct_version`. No Zig standard-library or vendor type crosses the ABI. Handle values round-trip through `uint64_t` and encode a 32-bit slot plus a 32-bit generation.

## Callback Contract Template

Each callback API documents: its executor or invocation thread; maximum invocation count; reentrancy; argument ownership and lifetime; whether callback work may block; deregistration behavior; and behavior during shutdown. Backend threads never invoke business callbacks incidentally.

## Dependency Directions

`core` depends only on Zig std and minimal OS primitives. Product modules depend on Foundation facades. Only `adapters/<vendor>` may include or import that vendor API. Optional adapters may depend on core facades, but core never depends on adapters or optional vendors. Tests may use test backends but may not bypass public ownership, cancellation, or ABI contracts.
