# Task 13: SQLite adapter

## Objective

Integrate SQLite as an optional adapter with safe connection/statement/transaction lifetimes, consistent errors, executor delivery, best-effort cancellation, and test database support.

## Rationale

Agent sessions, trace indexes, cache metadata, editor data, and tool state need an embedded database. Foundation should standardize integration and compilation without becoming an ORM or owning business schemas.

## Design

The database surface exposes SQLite-oriented connection, statement, bind, step/row view, transaction, and close semantics behind Foundation types; it may preserve SQLite-specific capability where useful but cannot expose raw `sqlite3*` publicly. Statements borrow their connection and rows borrow the current step. Transactions use explicit commit/rollback and roll back on teardown.

Async execution runs on a caller-supplied suitable executor and posts completion to the requested completion executor. Cancellation uses SQLite interruption/progress facilities as best effort and resolves races through Foundation operation state. Define serialized/thread-affinity policy and busy timeout/handler behavior.

## Implementation scope

- Add pinned SQLite amalgamation/package, exact compile options, manifest, license, and sole adapter integration.
- Implement connection open/close, prepare/finalize, typed binding, stepping/row reads, transactions, error mapping, busy policy, and in-memory/temp test databases.
- Integrate operations, cancellation, deadlines, executor affinity, and shutdown; retain native result/extended codes.
- Add compile-option introspection/test so shipped options cannot drift silently.

Do not add an ORM, migrations framework, repository abstraction, pooling service, or business schema.

## Dependencies

- Task 01.
- Tasks 03 through 05.

## Completion checks

- Tests cover CRUD primitives, all bind/value types, null/text/blob ownership, constraint errors, syntax errors, transaction commit/rollback/automatic rollback, busy/locked behavior, and close with live statements.
- A deterministic long query is interrupted; cancel/complete races have one terminal result on the selected executor.
- Compile options, thread mode, native error codes, and dependency pin/license are asserted.
- SQLite is absent from compilation/linking when disabled and no public type/vendor import leaks outside the adapter.

