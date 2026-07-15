# Task 06: Bounded channels and mailboxes

## Objective

Implement the small set of bounded queues needed for cross-thread delivery and host-pumped mailboxes, with explicit backpressure.

## Rationale

Async callbacks, logging, and stream delivery need predictable memory use. Unbounded queues hide overload and make shutdown unreliable, while a single overflow policy is wrong for gameplay commands, profiler samples, state updates, and token streams.

## Design

Provide bounded SPSC ring buffer and bounded MPSC queue/mailbox using a mature, cited algorithm or a simple locked implementation where that is easier to prove correct. Correctness and explicit memory ordering are more important than lock-free branding. Support `reject`, `block`, `drop_newest`, `drop_oldest`, and `coalesce` only where their semantics are well-defined. Blocking methods require cancellation/deadline and are unavailable on executors/threads documented as non-blocking.

Items have deterministic destruction on rejection, dropping, close, and queue teardown. Closing wakes blocked producers/consumers and prohibits new sends.

## Implementation scope

- Implement bounded SPSC and MPSC primitives plus a typed mailbox abstraction.
- Implement supported overflow policies, capacity/query metrics, close, drain, and teardown.
- Define producer/consumer concurrency and memory-ordering guarantees in public docs.
- Add a coalescing hook keyed by caller-defined identity; do not invent business merge semantics.
- Integrate cancellation and monotonic deadlines for blocking operations.

Do not implement an unbounded queue, general actor runtime, or distributed channel.

## Dependencies

- Task 02.
- Task 04.
- Task 05.

## Completion checks

- Tests cover capacity 1 and boundaries, FIFO guarantees, every supported overflow policy, close with waiters, cancellation, deadlines, destructor counts, and allocator failure.
- MPSC stress tests prove no duplicated/lost accepted item and pass the supported race/sanitizer configuration.
- Unsupported policy/queue combinations fail explicitly rather than silently changing semantics.
- No default API allocates beyond configured capacity after initialization.

