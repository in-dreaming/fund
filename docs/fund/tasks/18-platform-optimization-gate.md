# Task 18: Evidence-gated platform optimization

## Objective

Measure integrated Foundation workloads and decide, with reproducible evidence, whether any native platform backend or optional allocator/TLS adapter should be implemented.

## Rationale

IOCP, io_uring, kqueue, console APIs, platform HTTP/TLS, mimalloc, and Mbed TLS add substantial maintenance and platform risk. Architecture requires measured need before replacing or supplementing mature defaults.

## Design

Treat this as a decision gate, not a mandate to add code. Define representative game, agent, tooling, and server benchmarks; record latency distributions, throughput, allocations, memory high-water mark, CPU, binary size, cancellation latency, and shutdown time. Compare against explicit product budgets on named hardware/OS/toolchain revisions.

A new backend is justified only when a measured default misses an agreed budget and profiling attributes the miss to the replaceable backend. Record an ADR covering alternatives, platform coverage, maintenance/security cost, fallback, removal path, and conformance plan. If evidence does not justify a backend, complete the task with a reproducible report and a decision to retain defaults.

## Implementation scope

- Add reproducible benchmark harnesses/fixtures and baseline result schema; do not commit misleading cross-machine thresholds without calibration.
- Establish product budgets with owners or clearly mark unavailable budgets as a decision blocker in the report.
- Measure default profiles and identify statistically meaningful bottlenecks.
- Produce one ADR per evaluated candidate: IOCP, io_uring, kqueue, console adapter, platform HTTP/TLS, mimalloc, or Mbed TLS as relevant to supported targets.
- Only for an approved candidate, implement it as an optional adapter using existing facades, dependency governance, shared conformance suites, feature pruning, and fallback behavior.

Do not replace libcurl/TLS/compression/hash/profiler algorithms, add a general thread pool, or ship a backend solely because a platform API exists.

## Dependencies

- Task 17.

## Completion checks

- Benchmarks state workload, warmup/sample method, hardware, OS, pinned Zig/dependency versions, build mode, raw results, and variance.
- Each investigated candidate has an ADR with a clear implement/defer/reject decision tied to budgets and profiles.
- If all candidates are deferred/rejected, the baseline and ADRs reproduce and the task is complete without production code changes.
- Any implemented adapter passes the existing capability conformance/fault/shutdown suites on its platform, falls back cleanly, is fully feature-gated, and has measured before/after results.
- CI runs benchmark compilation/smoke checks; performance regression automation uses calibrated runners or reports data without flaky universal thresholds.
