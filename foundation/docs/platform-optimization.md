# Platform Optimization Evidence Gate

Task 18 is a decision gate. A platform backend or optional allocator/TLS adapter
is implemented only after a default profile misses an owned product budget and a
profile attributes that miss to the replaceable component.

## Workloads and collection

`benchmarks/foundation_benchmark.zig` emits schema version 1 to stderr. It uses
three warmup samples followed by 15 measured samples of 1,000 operations. The
reported latency distribution is over sample duration, and throughput covers all
measured operations. The fixed method is intentionally stable while the project
has no calibrated performance runner. Run all profiles in `ReleaseFast` mode:

```powershell
zig build -Doptimize=ReleaseFast -Dprofile=core benchmark 2> docs/benchmarks/<run>/core.json
zig build -Doptimize=ReleaseFast -Dprofile=game benchmark 2> docs/benchmarks/<run>/game.json
zig build -Doptimize=ReleaseFast -Dprofile=agent benchmark 2> docs/benchmarks/<run>/agent.json
zig build -Doptimize=ReleaseFast -Dprofile=tooling benchmark 2> docs/benchmarks/<run>/tooling.json
zig build -Doptimize=ReleaseFast -Dprofile=server benchmark 2> docs/benchmarks/<run>/server.json
```

The game/core workload measures shared-buffer ownership churn. Agent measures
the standard JSON facade. Tooling currently measures the allocation-heavy shared
buffer path because its filesystem/process fixtures are not a stable timing
target across Windows hosts. Server measures cancellation request latency and
owner-pumped queue shutdown. Each result includes allocation-event accounting,
allocation high-water bytes, cancellation latency, and shutdown time. JSON parse
allocation events are a documented lower bound; they must not be compared with
allocator candidates until an allocator event collector is added.

The runner must append CPU model, logical-core count, RAM, OS revision, power
plan, Zig version, Foundation commit, enabled dependency manifest versions, and
the executable byte count to the result directory's `README.md`. CPU process
time and binary size are nullable in the schema until collected by a calibrated
platform runner. Null means unavailable evidence, never zero.

`zig build benchmark-smoke` compiles and runs the harness with no threshold.
CI uses this only to catch harness/schema drift. Performance comparisons run on
reserved, calibrated hardware and retain raw JSON, profiler captures, and the
runner metadata with the decision.

## Product budgets and decision state

No product budget owner or agreed budget exists in this repository as of
2026-07-15. The following required budget fields are therefore **unavailable**:
per-profile p95 latency, throughput, allocation/high-water cap, cancellation
latency, shutdown deadline, CPU ceiling, and binary-size ceiling. This is a
decision blocker for every new backend. The Foundation maintainer must record an
owner, target hardware/OS/toolchain revision, and each numeric budget before
reopening an ADR below.

The baseline in `docs/benchmarks/windows-server-2025-2026-07-15/` is evidence
about this host only. It is not a cross-machine threshold and does not justify
an optimization. Candidate ADRs are in `docs/adr/`.

## Admission rule

1. Collect default and candidate results on the same calibrated runner, with
   identical profile, fixture, build mode, and pinned dependencies.
2. Show that the default violates an owned budget with variance that does not
   overlap the budget boundary.
3. Attach a profiler capture that attributes the dominant cost to the proposed
   replaceable backend rather than application work, a fixture, or another
   Foundation capability.
4. Amend the candidate ADR with platform coverage, maintenance/security cost,
   fallback/removal path, feature pruning, and conformance/fault/shutdown plan.
5. Only then add an optional adapter behind the existing facade and run its
   conformance suites and before/after benchmark comparison.
