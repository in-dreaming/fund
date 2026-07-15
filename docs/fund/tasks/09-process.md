# Task 09: Process facade and native backend

## Objective

Provide a safe process facade and Zig std/OS backend with explicit argv execution, stream capture, timeout, cancellation, groups, and termination.

## Rationale

Tools and farm clients need consistent process behavior, but default shell invocation creates quoting and injection hazards. Process lifecycle must integrate with Foundation errors, buffers, executors, cancellation, and shutdown.

## Design

The default API is `spawn(executable, argv)` with structured environment and working directory. Shell execution, if present at all, is a separately named high-risk feature disabled by default. stdout/stderr are bounded streams with configurable overflow or spill behavior; captured results use `SharedBuffer`.

Process operations expose started/exited/failed/cancelled state and platform-normalized exit information while retaining native codes. Timeout/cancel requests graceful termination when supported, then escalates after a caller-specified deadline. Process groups prevent orphaned descendants where supported.

## Implementation scope

- Define process request/options, stdio modes, environment policy, exit status, termination policy, and process operation facade.
- Implement the native backend using Zig std and minimal OS calls needed for groups/kill.
- Integrate executor-bound stream/completion callbacks, cancellation, monotonic timeout, and shutdown registration.
- Implement a mock backend contract for Task 16.
- Document unsupported platform features and map them to `unsupported` rather than emulating unsafely.

Do not add a business RPC protocol, terminal emulator, or enable shell parsing by default.

## Dependencies

- Task 01.
- Tasks 03 through 05.

## Completion checks

- Loopback helper-process tests cover argv with spaces/metacharacters without shell interpretation, environment/working directory, stdin/out/err, exit codes, spawn failure, output limits, timeout, cancellation, and group termination.
- Completion/stream callbacks run only on the selected executor and do not fire after teardown.
- Shutdown with a running helper terminates/reaps it within deadline and leaves no orphan.
- Feature-disabled/core builds do not compile process code.

