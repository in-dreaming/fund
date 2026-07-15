# Task 16: Deterministic testing and fault injection

## Objective

Deliver reusable deterministic test infrastructure, shared backend conformance suites, and fault injection for the failure/race modes Foundation promises to handle.

## Rationale

Replaceable mocks and reproducible races provide more value than additional production backends. They are also required to prove cancellation, ownership, callback thread, partial-I/O, overload, and shutdown contracts across modules.

## Design

Consolidate `TestClock`, `TestExecutor`, deterministic scheduler, fail allocator, fault injector, trace recorder, and mocks for filesystem, HTTP, process, and database behavior. Fault points are typed/stable test identifiers rather than stringly global switches. A scenario controls occurrence count, delay, error, partial result, or race barrier and is scoped to a test context.

The deterministic scheduler advances virtual time only when instructed, has a reproducible seed/order, detects non-progress, and records an event trace suitable for assertion. It does not pretend to model all weak-memory behaviors; real threaded stress/race tests remain separate.

## Implementation scope

- Unify existing test helpers behind `foundation.testing` without breaking production module boundaries.
- Implement typed fault plans and scoped injection for nth allocation failure, partial file I/O, disk full, HTTP timeout/chunking, process hang, SQLite busy, delayed callback, executor rejection, and cancel/complete barriers.
- Implement deterministic scheduler/virtual time integration and trace recorder.
- Extract conformance suites for filesystem, HTTP, process, compressor/hasher, JSON view, database, executors, and queues so future backends reuse them.
- Add leak/resource accounting and test helpers that assert no pending operation/callback at teardown.

Do not place production behavior behind global test flags or make release binaries depend on heavyweight test code.

## Dependencies

- Tasks 01 through 15.

## Completion checks

- Every listed fault mode has a deterministic test that fails if injection is disabled/broken.
- Cancel/complete and callback-delay scenarios replay identically from the same seed/event order and reach both race outcomes through explicit schedules.
- Each production and mock backend runs its relevant shared conformance suite.
- Test infrastructure catches an intentional leak/pending-operation fixture and releases all state afterward.
- Non-test/release build inspection proves testing-only implementations are omitted unless explicitly enabled.

