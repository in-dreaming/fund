# Task 01: Base types, errors, and clocks

## Objective

Implement the small, dependency-free base layer: common scalar types, stable error metadata/mapping hooks, and semantically distinct time/clock APIs.

## Rationale

Every facade needs consistent errors and timeouts. Establishing these types before adapters prevents native codes, wall time, and monotonic deadlines from being represented differently in each module.

## Design

Define `ErrorCategory` exactly as listed in `setup.md`. `ErrorInfo` contains category, signed native code, safe message, and source location/context without relying on global state. Keep mapping functions local to adapters but provide helpers for context chaining and stable C-code conversion.

Define `Duration`, `MonotonicInstant`, and a wall timestamp type with checked/saturating arithmetic where appropriate. A `Clock` facade exposes monotonic and wall readings; game time is a separately supplied clock. Timeouts/deadlines use monotonic values. Provide a std/OS clock and a manually advanced test clock without starting a thread.

## Implementation scope

- Add public base/error/time module roots and export them from the package root.
- Implement error categories, owned/borrowed message handling rules, source context, native-code preservation, and redaction helpers.
- Define a stable mapping between `ErrorCategory` and numeric C error codes, reserving room for expansion.
- Implement duration construction/conversion, overflow behavior, comparisons, deadlines, and remaining-time calculation.
- Implement the clock vtable/facade, system clock, game/manual clock, and deterministic test clock.
- Document that wall-clock jumps never affect timeout decisions.

Do not add cancellation, timers that create threads, a scheduler, or third-party error mappings.

## Dependencies

- Task 00.

## Completion checks

- Unit tests cover every error category's C-code round trip, native-code preservation, context attachment, and sensitive-message redaction.
- Duration tests cover negative/zero values, conversion boundaries, overflow policy, expired deadlines, and wall-clock discontinuity isolation.
- Test clock advancement is deterministic and system clock monotonic readings do not decrease in a smoke test.
- Core builds without optional features or vendor imports.

