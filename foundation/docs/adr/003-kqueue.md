# ADR 003: kqueue adapter

Status: deferred, 2026-07-15.

BSD/macOS kqueue is not a current supported adapter target; the repository's
libuv integration is Windows-only. No owned target budget, calibrated
supported-platform result, or backend-attributed bottleneck exists. Do not add a
speculative native loop.

Any future adapter needs a supported-platform CI lane, host-pumped executor
semantics, a documented fallback, feature pruning, and the shared conformance,
fault, cancellation, and shutdown tests. Removal remains feature disablement;
the cost includes platform API compatibility and security maintenance.
