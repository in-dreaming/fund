# Task 10: JSON codecs, views, and schema subset

## Objective

Provide a standard-library JSON codec, high-frequency yyjson adapter, a lifetime-safe read-only value view, and a compiled lightweight schema validator.

## Rationale

Configuration and typed Zig data benefit from `std.json`, while provider/tool payloads need yyjson throughput. A narrow common view enables tool and C-facing consumers without erasing backend-specific capabilities or creating a new DOM.

## Design

`JsonCodec` is an opaque facade for parse/serialize entry points common to both backends. Backend-native advanced APIs stay in adapter-specific modules, never business modules. `JsonValueView` supports null, bool, signed/unsigned integer, float, string, array, and object. Views borrow document storage and cannot outlive it; keys/strings state encoding and escape behavior.

Compile a schema subset supporting type, required, properties, arrays/items, enum, numeric range, string length, and `additionalProperties`. Compilation allocates once; validation returns stable error paths/categories without modifying input.

## Implementation scope

- Implement `std.json` codec and shared value-view traversal API.
- Integrate pinned yyjson through its sole adapter with manifest/license/integration tests.
- Implement schema representation, compilation, validation, path reporting, and limits for depth/nodes/string sizes.
- Add serialization/parsing ownership and allocator rules plus primitives suitable for later optional C ABI exposure.
- Preserve meaningful backend capabilities through explicit optional/query interfaces rather than lowest-common-denominator flags.

Do not implement a general JSON parser, mutable universal DOM, or full JSON Schema standard.

## Dependencies

- Task 00.
- Task 01.
- Task 03.

## Completion checks

- A shared fixture suite yields equivalent value views for both codecs, including numeric boundaries, Unicode/escapes, duplicate-key policy, invalid JSON, and depth/size limits.
- Schema tests cover every supported keyword, nested error paths, enum equality, unknown properties, compile failure, allocation failure, and adversarial depth.
- yyjson is absent when its feature is disabled; vendor imports exist only in its adapter.
- Manifest, license, pin, and adapter integration checks pass.
