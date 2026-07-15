# Task 05: Future, operation, and executor contracts

## Objective

Define allocator-aware futures, long-lived operation state, and an executor facade that makes completion context predictable without implementing a production scheduler.

## Rationale

Consumers need one model for pending/completed/failed/cancelled results across files, HTTP, processes, and tools. Explicit executors prevent backend threads, accidental synchronous callbacks, and main-thread reentrancy from becoming observable API quirks.

## Design

A future has exactly one terminal state: completed, failed, or cancelled. The producer resolves it once; consumers can poll, register continuation(s) according to a documented cardinality, or wait only through an explicit blocking helper. Stored values/errors own their memory and release it deterministically.

An `Operation` is handle-owned asynchronous work with state, cancellation linkage, progress/stream hooks where relevant, and a future result. Operation storage uses `HandleTable`. Completion is posted to the caller-selected executor even if the backend finishes inline. Define an explicit policy for submit failure.

The executor is an opaque pointer/vtable supporting submit and cancel. Supply `ImmediateExecutor`, `MainThreadQueue` (host-pumped), and deterministic `TestExecutor`; no production thread pool.

## Implementation scope

- Implement generic future/promise state and terminal transition rules.
- Implement operation handles/registry, state query, cancel request bridge, completion, and cleanup.
- Implement executor task types/options/results, facade validation, immediate executor, host-pumped main-thread queue, and test executor.
- Make callback executor, reentrancy, cardinality, argument lifetime, blocking, deregistration, and shutdown behavior part of every public callback contract.
- Define how executor rejection maps to `ErrorInfo` and how owned completion payloads are reclaimed.

Do not add coroutines, a general event loop, work stealing, or a production job system.

## Dependencies

- Tasks 01 through 04.

## Completion checks

- Tests cover every state transition, double resolution, producer/consumer teardown order, allocation failure, executor rejection, callback deregistration, and cancellation races.
- A backend-completes-inline test proves the completion runs only when the selected queued executor is pumped.
- Operation stale handles are rejected and all payload/error memory is reclaimed after success, failure, cancellation, and abandoned consumer paths.
- Immediate and test executors obey the same callback contract, with reentrancy differences explicit and tested.
