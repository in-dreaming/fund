# Task 07: C ABI and plugin boundary

## Objective

Publish a versioned C ABI for core strings, buffers, errors, handles, cancellation/operations, and define a safe dynamic-plugin lifecycle.

## Rationale

The C boundary is the stable interoperability contract for engines, plugins, and non-Zig consumers. It must preserve ownership and errors without exposing Zig layouts or third-party ABI details.

## Design

`foundation/include/foundation.h` is valid C11 and C++. It defines `fd_string_view`, `fd_buffer` with release callback/userdata, `fd_handle`, stable error codes/details, and opaque contexts. Extensible input/output structs begin with size/version. Exported functions validate nulls, sizes, versions, handles, and ownership.

Plugins export one C entry point returning a descriptor with ABI version, feature bits, build ID, lifecycle callbacks, and explicit host services. An unload guard prevents unloading while plugin-owned handles/callbacks are live. No plugin relies on Zig's internal ABI.

## Implementation scope

- Complete the public header, visibility/calling-convention macros, ABI version constants, and Zig export layer.
- Bridge `SharedBuffer` to/from `fd_buffer`, invoking release exactly once and documenting release thread.
- Bridge stable handles, errors, cancellation, operation status, and executor callback scheduling needed by C consumers.
- Apply size/version validation and forward-compatible tail ignoring to all extensible structs.
- Implement dynamic-library loading through Zig std/OS, descriptor validation, load/start/stop/unload lifecycle, feature negotiation, and unload guards.
- Add ABI symbol/export control and a compatibility fixture representing the previous supported struct size/version.

Do not expose HTTP/SQLite/vendor structs or define a business plugin API.

## Dependencies

- Tasks 01 through 05.

## Completion checks

- C11 and C++ compile/link/run tests consume only `foundation.h` and exercise strings, buffers, errors, handles, and an async callback.
- ABI tests cover older struct sizes, unknown newer tail fields, wrong versions, nulls, invalid handles, and callback executor affinity.
- A fixture plugin loads, negotiates features, refuses premature unload, shuts down, and unloads without leaks.
- Header review/test confirms no Zig or third-party types and exported symbol inspection matches the allowlist.

