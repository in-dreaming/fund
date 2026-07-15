# Task 14: Logging, metrics, and performance trace

## Objective

Implement lightweight logging, metrics, and performance-trace facades with no-op/test sinks, bounded async logging, and an optional Tracy adapter.

## Rationale

All systems need correlated diagnostics, but Foundation must not force a monitoring server, database, OpenTelemetry SDK, or profiler into every binary. A stable facade lets engines, CLIs, and servers provide their own sinks.

## Design

`LogRecord` contains wall timestamp, level, category/symbol ID, message, typed fields, and optional trace context. Sinks include no-op, console, file/rotating file where portable, memory ring, and adapter hooks. Async logging uses the bounded channel facilities, selectable overflow, dropped-record counters, explicit worker/executor supplied by the host, and deadline-bounded flush. It never blocks a game main thread by default.

Metrics provide counter, gauge, histogram, and timer instruments with stable names/labels and no-op/log/test sinks. Cardinality limits are explicit. Trace facade covers performance zones/frames/threads/locks/memory/plots; semantic agent/workflow replay remains outside Foundation. Tracy is the optional production performance backend.

## Implementation scope

- Implement logging records/fields/categories, sink facade, no-op, console, memory ring, and bounded async dispatcher with redaction hooks.
- Implement metrics facade/instruments, registration/conflict rules, label/cardinality limits, and no-op/test snapshot sink.
- Implement trace context propagation and performance trace facade/no-op sink.
- Integrate pinned Tracy in its sole adapter with feature gating and manifest/license.
- Register flush/teardown in shutdown phases and expose dropped/failed export counts.

Do not implement an observability server, time-series database, OTel SDK, semantic replay, or profiler engine.

## Dependencies

- Task 01.
- Tasks 03 through 06.
- Task 08.

## Completion checks

- Logging tests cover structured fields, redaction, every overflow behavior used, dropped counts, rotation policy where supported, sink failure, reentrancy policy, and flush deadline.
- Metrics tests cover atomic updates, histogram boundaries, duplicate/conflicting registration, label cardinality rejection, timer clock selection, and deterministic snapshots.
- Trace tests prove no-op calls are cheap/nonallocating in the defined hot path and context correlates logs without conflating semantic traces.
- Tracy integration smoke test passes when enabled; disabled builds contain no Tracy symbol/dependency.
