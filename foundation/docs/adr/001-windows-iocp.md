# ADR 001: Windows IOCP adapter

Status: deferred, 2026-07-15.

IOCP is relevant to the Windows tooling/server target, but the default libuv
tooling path has not missed an owned budget and no profile attributes a measured
bottleneck to its event-loop backend. Product budgets are unavailable, which is
an explicit decision blocker. Keep the current optional libuv adapter.

Reconsider only with calibrated default-versus-IOCP evidence. An approved adapter
would use the executor/filesystem/process facades, remain feature-gated, fall
back to libuv or host pumping, and pass conformance, fault, cancellation, and
deadline-bounded shutdown suites. Its removal path is disabling its build feature;
maintenance includes Windows API compatibility and cancellation semantics.
