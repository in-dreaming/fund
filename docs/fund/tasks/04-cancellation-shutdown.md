# Task 04: Cancellation and shutdown

## Objective

Implement unified cancellation with parent/child propagation and a deadline-bounded shutdown coordinator.

## Rationale

HTTP, files, processes, jobs, and event loops expose different stop mechanisms. Foundation needs one race-safe request-to-stop model and a deterministic teardown order without promising that every backend halts immediately.

## Design

`CancellationSource` owns shared state and produces copyable tokens. Cancellation is monotonic and records the first reason. Callback registration handles the register-versus-cancel race and returns a deregistration handle. Parent cancellation propagates to children without a global registry. Owner destruction has explicit semantics and cannot leave callbacks touching freed state.

The shutdown coordinator executes: stop accepting work, cancel owned operations, drain critical completions, flush logs/trace, stop loops, join threads, destroy adapters, report leaks. It supports graceful and immediate modes; graceful mode requires a monotonic deadline. Participants declare phase/order and are invoked at most once.

## Implementation scope

- Define cancel reasons including explicit request, timeout, owner destruction, and shutdown.
- Implement sources, tokens, parent/child linkage, callback register/deregister, reason query, and wait-free or bounded query behavior.
- Integrate timeout cancellation with the `Clock` abstraction without spawning a hidden timer thread; the host/executor drives deadline polling or scheduling.
- Implement shutdown mode, phases, participant registration, deadline enforcement, failure aggregation, and idempotent coordinator state transitions.
- Provide backend adaptation hooks but no curl/libuv/process implementation.

## Dependencies

- Task 01.
- Task 02.
- Task 03.

## Completion checks

- Deterministic race tests cover cancel-before-register, cancel-during-register, deregister-versus-cancel, complete-versus-cancel hook usage, parent/child propagation, and owner destruction.
- Exactly one cancel reason wins and each retained callback runs at most once.
- Graceful shutdown stops at its deadline, immediate shutdown skips draining as documented, phases execute in order, and repeated shutdown calls are safe per the documented contract.
- No cancellation or shutdown construction creates threads or global runtime state.

