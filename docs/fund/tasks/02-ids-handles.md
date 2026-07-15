# Task 02: Strong IDs and stable handles

## Objective

Provide typed strong IDs, generation-checked 64-bit handles, and a reusable allocator-aware `HandleTable` with safe slot reuse.

## Rationale

Operations, streams, plugins, jobs, and cross-language objects need stable identity without exposing pointers. Generation validation prevents use-after-free when table slots are recycled.

## Design

A handle is a packed 32-bit index plus 32-bit generation and round-trips to `u64`. Invalid/null representation must be explicit. `HandleTable(T, Tag)` owns values using a caller-provided allocator and validates both generation and, in debug builds, a type tag. Removal increments generation before a slot can be reused and must define behavior at generation wraparound.

Strong IDs are zero-cost distinct types with explicit serialization/parsing; unrelated ID types cannot be mixed without an explicit conversion.

## Implementation scope

- Implement a generic strong-ID facility for integer- and fixed-byte-backed IDs.
- Implement handle packing/unpacking, validation, typed handle aliases, and debug type tags.
- Implement `HandleTable`: insert, get/getConst, remove, capacity/reserve, iteration rules, and `deinit`.
- State pointer/reference invalidation rules for table growth and mutation.
- Add a C-compatible `u64` conversion helper but leave exported C functions to Task 07.

Do not implement a general container library, concurrent table, or lock-free reclamation.

## Dependencies

- Task 00.
- Task 01.

## Completion checks

- Compile-fail or equivalent type tests show different strong-ID types cannot be interchanged.
- Tests cover stale handle rejection, double remove, slot reuse with a new generation, invalid indices, empty/full tables, allocation failure, and cleanup without leaks.
- Property-style tests round-trip representative and boundary index/generation values through `u64`.
- Generation wrap behavior is documented and tested.

