# Foundation Acceptance Checklist

CI verifies this report through the `check`, `release-check`, profile, ABI, and example lanes.

- Core builds with all optional modules gated out and has no implicit executor, event loop, database, or network construction.
- Profile tests exercise cancellation, error categories, shared-buffer ownership, executor affinity, mock backends, and deadline-bounded shutdown.
- Boundary scanning rejects vendor API use outside `adapters`; public C ABI compilation is checked from C and C++.
- Every manifest has an immutable source pin, a release-input license text, and a corresponding entry in `THIRD_PARTY_NOTICES.txt`.
- Network integration tests use loopback fixtures only; Windows-only curl and libuv lanes are explicitly scoped in CI.
