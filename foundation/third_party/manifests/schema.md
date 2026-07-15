# Dependency Manifest Schema

Each JSON manifest in `entries/` must contain non-empty `name`, `version`, `source`, `license`, `purpose`, `platforms`, `linkage`, `source_modifications`, `patches`, `security_update_policy`, `replacement_removal_path`, `replacement_cost`, and `owner` fields. `template.json` is an intake template, not a dependency declaration.

`source.ref` is an immutable commit or content hash, never a branch, tag, or `HEAD`. `license.file` is a path relative to `third_party/` and must exist. Every patch path is relative to `third_party/patches/`, must exist, and is listed only by the manifest that owns it. `linkage` is `static`, `dynamic`, or `none`.
