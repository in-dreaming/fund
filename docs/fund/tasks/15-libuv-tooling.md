# Task 15: libuv tooling, file watch, and IPC adapters

## Objective

Add the optional libuv backend for tool/server event-loop use, including executor/timer/process adaptation, native file watch, and local IPC transports.

## Rationale

CLIs, farm clients, agent servers, and tool processes benefit from libuv's cross-platform event loop. Game runtimes usually already own a loop/job system, so libuv must remain an optional adapter rather than Foundation's runtime.

## Design

The libuv loop is explicitly constructed, pumped/run by its owner, and stopped/joined through shutdown; importing/linking does not start it. Adapt it to Foundation executor, monotonic timers/deadlines, process backend, filesystem watch events, pipes/named pipes/Unix sockets/local TCP as platform permits. Callbacks always cross to the selected completion executor when the public contract requires it.

IPC supplies byte-stream/listener abstractions and peer/local endpoint metadata, not RPC framing or business protocols. File watch normalizes create/modify/remove/rename/overflow/rescan-required and documents coalescing/platform differences.

## Implementation scope

- Integrate pinned libuv with manifest/license/build logic in its sole adapter.
- Implement explicit loop lifecycle, executor submit/cancel, timer scheduling, wakeup, and shutdown deadline behavior.
- Adapt process operations where libuv improves portability while preserving Task 09 semantics.
- Implement file-watch facade/backend and local IPC stream/listener backends supported by host platforms.
- Add bounded buffering/backpressure, cancellation, error mapping, and executor-affinity rules.

Do not make libuv a core/game dependency, add network business protocols, or hide a global default loop.

## Dependencies

- Task 04.
- Task 05.
- Task 08.
- Task 09.
- Task 11.

## Completion checks

- Explicit lifecycle tests prove construction starts no background thread unless requested, loop pumping controls progress, and shutdown drains/stops within deadline.
- Executor/timer tests cover ordering, cancellation, close races, callback affinity, and native-code mapping.
- Temp-directory watch tests cover normalized events and overflow/rescan behavior without asserting unsupported platform ordering.
- Loopback pipe/socket tests cover connect/listen, partial I/O, backpressure, peer close, cancellation, and teardown; process conformance tests also pass on this backend.
- Core/game profiles omit libuv completely; dependency governance checks pass.

