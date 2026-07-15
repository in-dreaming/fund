const std = @import("std");
const foundation = @import("foundation");
const errors = foundation.errors;
const cancellation = foundation.cancellation;
const executor = foundation.executor;

const sqlite = opaque {};
const sqlite_stmt = opaque {};
const SQLITE_OK = 0;
const SQLITE_ERROR = 1;
const SQLITE_BUSY = 5;
const SQLITE_LOCKED = 6;
const SQLITE_INTERRUPT = 9;
const SQLITE_CONSTRAINT = 19;
const SQLITE_MISUSE = 21;
const SQLITE_ROW = 100;
const SQLITE_DONE = 101;
const SQLITE_OPEN_READONLY = 0x00000001;
const SQLITE_OPEN_READWRITE = 0x00000002;
const SQLITE_OPEN_CREATE = 0x00000004;
const SQLITE_OPEN_URI = 0x00000040;

extern fn sqlite3_open_v2([*:0]const u8, *?*sqlite, c_int, ?[*:0]const u8) c_int;
extern fn sqlite3_close_v2(*sqlite) c_int;
extern fn sqlite3_prepare_v3(*sqlite, [*]const u8, c_int, c_uint, *?*sqlite_stmt, ?*?[*]const u8) c_int;
extern fn sqlite3_finalize(*sqlite_stmt) c_int;
extern fn sqlite3_reset(*sqlite_stmt) c_int;
extern fn sqlite3_clear_bindings(*sqlite_stmt) c_int;
extern fn sqlite3_bind_null(*sqlite_stmt, c_int) c_int;
extern fn sqlite3_bind_int64(*sqlite_stmt, c_int, i64) c_int;
extern fn sqlite3_bind_double(*sqlite_stmt, c_int, f64) c_int;
extern fn sqlite3_bind_text(*sqlite_stmt, c_int, [*]const u8, c_int, ?*const anyopaque) c_int;
extern fn sqlite3_bind_blob(*sqlite_stmt, c_int, ?*const anyopaque, c_int, ?*const anyopaque) c_int;
extern fn sqlite3_step(*sqlite_stmt) c_int;
extern fn sqlite3_column_type(*sqlite_stmt, c_int) c_int;
extern fn sqlite3_column_int64(*sqlite_stmt, c_int) i64;
extern fn sqlite3_column_double(*sqlite_stmt, c_int) f64;
extern fn sqlite3_column_text(*sqlite_stmt, c_int) ?[*]const u8;
extern fn sqlite3_column_blob(*sqlite_stmt, c_int) ?*const anyopaque;
extern fn sqlite3_column_bytes(*sqlite_stmt, c_int) c_int;
extern fn sqlite3_errcode(*sqlite) c_int;
extern fn sqlite3_extended_errcode(*sqlite) c_int;
extern fn sqlite3_errmsg(*sqlite) [*:0]const u8;
extern fn sqlite3_extended_result_codes(*sqlite, c_int) c_int;
extern fn sqlite3_busy_timeout(*sqlite, c_int) c_int;
extern fn sqlite3_interrupt(*sqlite) void;
extern fn sqlite3_compileoption_used([*:0]const u8) c_int;
extern fn sqlite3_threadsafe() c_int;

/// SQLite is compiled in serialized mode. A connection may be used from several
/// threads, but calls are serialized by SQLite; values returned by a Row remain
/// borrowed only until the statement is stepped, reset, or finalized.
pub const OpenOptions = struct {
    read_only: bool = false,
    create: bool = true,
    uri: bool = false,
    busy_timeout_ms: u32 = 0,
};

pub const Value = union(enum) { null, integer: i64, real: f64, text: []const u8, blob: []const u8 };
pub const Step = union(enum) { row: Row, done };
pub const DbError = struct {
    category: errors.ErrorCategory,
    native_code: i32,
    extended_code: i32,
    /// Borrowed from the connection and invalidated by close or the next SQLite call.
    message: []const u8,
};
pub fn Result(comptime T: type) type {
    return union(enum) { ok: T, err: DbError };
}
pub const OpenResult = Result(*Connection);
pub const PrepareResult = Result(*Statement);
pub const VoidResult = Result(void);
pub const StepResult = Result(Step);
pub const BoolResult = Result(bool);

const ConnectionImpl = struct {
    allocator: std.mem.Allocator,
    native: *sqlite,
    references: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    closing: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};
const StatementImpl = struct { connection: *ConnectionImpl, native: *sqlite_stmt, finalized: bool = false };
const TransactionImpl = struct { connection: *Connection, active: bool = true };

/// Handle-owned connection. Call `close` or `deinit` exactly once. Closing is
/// idempotent and deferred until its borrowed statements have been finalized.
pub const Connection = opaque {
    pub fn open(allocator: std.mem.Allocator, path: [:0]const u8, options: OpenOptions) OpenResult {
        var native: ?*sqlite = null;
        var flags: c_int = if (options.read_only) SQLITE_OPEN_READONLY else SQLITE_OPEN_READWRITE;
        if (options.create and !options.read_only) flags |= SQLITE_OPEN_CREATE;
        if (options.uri) flags |= SQLITE_OPEN_URI;
        const code = sqlite3_open_v2(path.ptr, &native, flags, null);
        if (code != SQLITE_OK) {
            if (native) |db| _ = sqlite3_close_v2(db);
            return .{ .err = failure(null, code) };
        }
        const impl = allocator.create(ConnectionImpl) catch {
            _ = sqlite3_close_v2(native.?);
            return .{ .err = oomFailure() };
        };
        impl.* = .{ .allocator = allocator, .native = native.? };
        _ = sqlite3_extended_result_codes(impl.native, 1);
        if (options.busy_timeout_ms != 0) _ = sqlite3_busy_timeout(impl.native, @intCast(@min(options.busy_timeout_ms, std.math.maxInt(c_int))));
        return .{ .ok = @ptrCast(impl) };
    }
    /// Opens a private in-memory database. The returned connection is handle-owned.
    pub fn openMemory(allocator: std.mem.Allocator) OpenResult {
        return open(allocator, ":memory:", .{});
    }
    /// Opens a temporary database which SQLite removes when the connection closes.
    pub fn openTemporary(allocator: std.mem.Allocator) OpenResult {
        return open(allocator, "", .{});
    }
    pub fn close(self: *Connection) VoidResult {
        const impl = connectionImpl(self);
        if (impl.closing.swap(true, .acq_rel)) return .{ .ok = {} };
        const code = sqlite3_close_v2(impl.native);
        if (code != SQLITE_OK) return .{ .err = failure(impl, code) };
        releaseConnection(impl);
        return .{ .ok = {} };
    }
    pub fn deinit(self: *Connection) void {
        _ = self.close();
    }
    pub fn prepare(self: *Connection, sql: []const u8) PrepareResult {
        const impl = connectionImpl(self);
        if (impl.closing.load(.acquire)) return .{ .err = closedFailure() };
        var native: ?*sqlite_stmt = null;
        const code = sqlite3_prepare_v3(impl.native, sql.ptr, @intCast(sql.len), 0, &native, null);
        if (code != SQLITE_OK) return .{ .err = failure(impl, code) };
        retainConnection(impl);
        const statement = impl.allocator.create(StatementImpl) catch {
            _ = sqlite3_finalize(native.?);
            releaseConnection(impl);
            return .{ .err = oomFailure() };
        };
        statement.* = .{ .connection = impl, .native = native.? };
        return .{ .ok = @ptrCast(statement) };
    }
    pub fn execute(self: *Connection, sql: []const u8) VoidResult {
        const statement = switch (self.prepare(sql)) {
            .ok => |value| value,
            .err => |err| return .{ .err = err },
        };
        defer statement.finalize();
        while (true) switch (statement.step()) {
            .ok => |state| switch (state) {
                .row => {},
                .done => return .{ .ok = {} },
            },
            .err => |err| return .{ .err = err },
        };
    }
    pub fn begin(self: *Connection) Result(*Transaction) {
        switch (self.execute("BEGIN")) {
            .ok => {},
            .err => |err| return .{ .err = err },
        }
        const transaction = connectionImpl(self).allocator.create(TransactionImpl) catch {
            _ = self.execute("ROLLBACK");
            return .{ .err = oomFailure() };
        };
        transaction.* = .{ .connection = self };
        return .{ .ok = @ptrCast(transaction) };
    }
    /// Requests best-effort cancellation of the current SQLite operation.
    pub fn interrupt(self: *Connection) void {
        sqlite3_interrupt(connectionImpl(self).native);
    }
    pub fn setBusyTimeout(self: *Connection, milliseconds: u32) VoidResult {
        const impl = connectionImpl(self);
        const code = sqlite3_busy_timeout(impl.native, @intCast(@min(milliseconds, std.math.maxInt(c_int))));
        return if (code == SQLITE_OK) .{ .ok = {} } else .{ .err = failure(impl, code) };
    }
};

/// Statement borrows its connection and owns its native prepared statement.
pub const Statement = opaque {
    pub fn finalize(self: *Statement) void {
        const impl = statementImpl(self);
        if (impl.finalized) return;
        impl.finalized = true;
        _ = sqlite3_finalize(impl.native);
        const allocator = impl.connection.allocator;
        releaseConnection(impl.connection);
        allocator.destroy(impl);
    }
    pub fn reset(self: *Statement) VoidResult {
        return statementCode(statementImpl(self), sqlite3_reset(statementImpl(self).native));
    }
    pub fn clearBindings(self: *Statement) VoidResult {
        return statementCode(statementImpl(self), sqlite3_clear_bindings(statementImpl(self).native));
    }
    pub fn bind(self: *Statement, index: u32, value: Value) VoidResult {
        const impl = statementImpl(self);
        if (impl.finalized) return .{ .err = closedFailure() };
        const i: c_int = @intCast(index);
        const code = switch (value) {
            .null => sqlite3_bind_null(impl.native, i),
            .integer => |v| sqlite3_bind_int64(impl.native, i, v),
            .real => |v| sqlite3_bind_double(impl.native, i, v),
            .text => |v| sqlite3_bind_text(impl.native, i, v.ptr, @intCast(v.len), transient()),
            .blob => |v| sqlite3_bind_blob(impl.native, i, if (v.len == 0) null else v.ptr, @intCast(v.len), transient()),
        };
        return statementCode(impl, code);
    }
    pub fn step(self: *Statement) StepResult {
        const impl = statementImpl(self);
        if (impl.finalized) return .{ .err = closedFailure() };
        const code = sqlite3_step(impl.native);
        return if (code == SQLITE_ROW) .{ .ok = .{ .row = .{ .statement = self } } } else if (code == SQLITE_DONE) .{ .ok = .done } else .{ .err = failure(impl.connection, code) };
    }
};

/// A row view borrowed from the current successful `Statement.step` result.
pub const Row = struct {
    statement: *Statement,
    pub fn value(self: Row, column: u32) Value {
        const native = statementImpl(self.statement).native;
        const index: c_int = @intCast(column);
        return switch (sqlite3_column_type(native, index)) {
            1 => .{ .integer = sqlite3_column_int64(native, index) },
            2 => .{ .real = sqlite3_column_double(native, index) },
            3 => blk: {
                const bytes: usize = @intCast(sqlite3_column_bytes(native, index));
                break :blk .{ .text = if (sqlite3_column_text(native, index)) |pointer| pointer[0..bytes] else "" };
            },
            4 => blk: {
                const bytes: usize = @intCast(sqlite3_column_bytes(native, index));
                const pointer = sqlite3_column_blob(native, index) orelse break :blk .{ .blob = "" };
                break :blk .{ .blob = @as([*]const u8, @ptrCast(pointer))[0..bytes] };
            },
            else => .null,
        };
    }
};

/// Transaction owns an open BEGIN scope. `deinit` rolls it back unless committed.
pub const Transaction = opaque {
    pub fn commit(self: *Transaction) VoidResult {
        const impl = transactionImpl(self);
        if (!impl.active) return .{ .err = closedFailure() };
        const result = impl.connection.execute("COMMIT");
        if (result == .ok) {
            impl.active = false;
            connectionImpl(impl.connection).allocator.destroy(impl);
        }
        return result;
    }
    pub fn rollback(self: *Transaction) VoidResult {
        const impl = transactionImpl(self);
        if (!impl.active) return .{ .ok = {} };
        const result = impl.connection.execute("ROLLBACK");
        impl.active = false;
        connectionImpl(impl.connection).allocator.destroy(impl);
        return result;
    }
    pub fn deinit(self: *Transaction) void {
        const impl = transactionImpl(self);
        if (impl.active) _ = self.rollback();
    }
};

/// The work function runs on `work_executor`; completion runs exactly once on
/// `completion_executor`. Cancellation interrupts SQLite best-effort and wins
/// the terminal result if it is observed before completion is posted.
pub const AsyncCompletion = *const fn (?*anyopaque, Result(void)) void;
pub fn executeAsync(connection: *Connection, sql: []const u8, work_executor: executor.Executor, completion_executor: executor.Executor, token: ?cancellation.Token, callback: AsyncCompletion, userdata: ?*anyopaque) error{ OutOfMemory, Rejected, Shutdown }!void {
    const impl = connectionImpl(connection);
    retainConnection(impl);
    var retain_owned = true;
    errdefer if (retain_owned) releaseConnection(impl);
    const copied_sql = try impl.allocator.dupe(u8, sql);
    var sql_owned = true;
    errdefer if (sql_owned) impl.allocator.free(copied_sql);
    const state = try impl.allocator.create(AsyncState);
    var state_owned = true;
    errdefer if (state_owned) impl.allocator.destroy(state);
    state.* = .{ .connection = connection, .sql = copied_sql, .work_executor = work_executor, .completion_executor = completion_executor, .callback = callback, .userdata = userdata, .allocator = impl.allocator };
    if (token) |value| state.registration = value.register(AsyncState.cancel, state) catch return error.OutOfMemory;
    work_executor.submit(.{ .run = AsyncState.run, .discard = AsyncState.discard, .context = state }) catch |err| {
        if (state.registration) |*registration| registration.deinit();
        return err;
    };
    state_owned = false;
    sql_owned = false;
    retain_owned = false;
}
const AsyncState = struct {
    allocator: std.mem.Allocator,
    connection: *Connection,
    sql: []u8,
    work_executor: executor.Executor,
    completion_executor: executor.Executor,
    registration: ?cancellation.Registration = null,
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    callback: AsyncCompletion,
    userdata: ?*anyopaque,
    result: Result(void) = .{ .ok = {} },
    fn run(context: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.cancelled.load(.acquire)) self.result = .{ .err = .{ .category = .cancelled, .native_code = SQLITE_INTERRUPT, .extended_code = SQLITE_INTERRUPT, .message = "cancelled" } } else self.result = self.connection.execute(self.sql);
        self.completion_executor.submit(.{ .run = complete, .discard = discard, .context = self }) catch AsyncState.discard(self);
    }
    fn complete(context: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.callback(self.userdata, self.result);
        AsyncState.discard(context);
    }
    fn cancel(context: ?*anyopaque, _: cancellation.CancelReason) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        self.cancelled.store(true, .release);
        self.connection.interrupt();
    }
    fn discard(context: ?*anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(context.?));
        if (self.registration) |*registration| registration.deinit();
        self.allocator.free(self.sql);
        releaseConnection(connectionImpl(self.connection));
        self.allocator.destroy(self);
    }
};

pub fn compiledWith(option: [:0]const u8) bool {
    return sqlite3_compileoption_used(option.ptr) != 0;
}
pub fn serializedThreadMode() bool {
    return sqlite3_threadsafe() == 1;
}
fn transient() ?*const anyopaque {
    return @ptrFromInt(@as(usize, std.math.maxInt(usize)));
}
fn connectionImpl(value: *Connection) *ConnectionImpl {
    return @ptrCast(@alignCast(value));
}
fn statementImpl(value: *Statement) *StatementImpl {
    return @ptrCast(@alignCast(value));
}
fn transactionImpl(value: *Transaction) *TransactionImpl {
    return @ptrCast(@alignCast(value));
}
fn retainConnection(value: *ConnectionImpl) void {
    _ = value.references.fetchAdd(1, .acq_rel);
}
fn releaseConnection(value: *ConnectionImpl) void {
    if (value.references.fetchSub(1, .acq_rel) == 1) value.allocator.destroy(value);
}
fn statementCode(statement: *StatementImpl, code: c_int) VoidResult {
    return if (code == SQLITE_OK) .{ .ok = {} } else .{ .err = failure(statement.connection, code) };
}
fn closedFailure() DbError {
    return .{ .category = .invalid_state, .native_code = SQLITE_MISUSE, .extended_code = SQLITE_MISUSE, .message = "connection or statement is closed" };
}
fn oomFailure() DbError {
    return .{ .category = .resource_exhausted, .native_code = 7, .extended_code = 7, .message = "out of memory" };
}
fn failure(connection: ?*ConnectionImpl, code: c_int) DbError {
    const extended = if (connection) |value| sqlite3_extended_errcode(value.native) else code;
    const message: []const u8 = if (connection) |value| std.mem.span(sqlite3_errmsg(value.native)) else "sqlite open failed";
    return .{ .category = switch (code & 0xff) {
        SQLITE_BUSY, SQLITE_LOCKED => .unavailable,
        SQLITE_INTERRUPT => .cancelled,
        SQLITE_CONSTRAINT => .invalid_argument,
        else => .protocol,
    }, .native_code = code, .extended_code = extended, .message = message };
}

test "SQLite CRUD, binding, rows, and compile options" {
    const connection = switch (Connection.openMemory(std.testing.allocator)) {
        .ok => |value| value,
        .err => return error.TestUnexpectedResult,
    };
    defer connection.deinit();
    switch (connection.execute("CREATE TABLE sample (i INTEGER, r REAL, t TEXT, b BLOB, n TEXT)")) {
        .ok => {},
        .err => return error.TestUnexpectedResult,
    }
    const insert = switch (connection.prepare("INSERT INTO sample VALUES (?1, ?2, ?3, ?4, ?5)")) {
        .ok => |value| value,
        .err => return error.TestUnexpectedResult,
    };
    defer insert.finalize();
    inline for ([_]Value{ .{ .integer = 9 }, .{ .real = 1.5 }, .{ .text = "text" }, .{ .blob = "blob" }, .null }, 1..) |value, index| switch (insert.bind(index, value)) {
        .ok => {},
        .err => return error.TestUnexpectedResult,
    };
    switch (insert.step()) {
        .ok => |value| try std.testing.expect(value == .done),
        .err => return error.TestUnexpectedResult,
    }
    const select = switch (connection.prepare("SELECT i,r,t,b,n FROM sample")) {
        .ok => |value| value,
        .err => return error.TestUnexpectedResult,
    };
    defer select.finalize();
    const row = switch (select.step()) {
        .ok => |value| switch (value) {
            .row => |row| row,
            .done => return error.TestUnexpectedResult,
        },
        .err => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(i64, 9), row.value(0).integer);
    try std.testing.expectEqual(@as(f64, 1.5), row.value(1).real);
    try std.testing.expectEqualStrings("text", row.value(2).text);
    try std.testing.expectEqualStrings("blob", row.value(3).blob);
    try std.testing.expect(row.value(4) == .null);
    try std.testing.expect(serializedThreadMode());
    try std.testing.expect(compiledWith("THREADSAFE"));
    try std.testing.expect(compiledWith("DQS=0"));
}

test "errors, rollback, close with live statements, and selected completion executor" {
    const connection = switch (Connection.openMemory(std.testing.allocator)) {
        .ok => |value| value,
        .err => return error.TestUnexpectedResult,
    };
    switch (connection.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")) {
        .ok => {},
        .err => return error.TestUnexpectedResult,
    }
    const bad = connection.execute("SELEC broken");
    try std.testing.expect(bad == .err);
    try std.testing.expectEqual(@as(i32, SQLITE_ERROR), bad.err.native_code);
    const tx = switch (connection.begin()) {
        .ok => |value| value,
        .err => return error.TestUnexpectedResult,
    };
    switch (connection.execute("INSERT INTO t VALUES (1)")) {
        .ok => {},
        .err => return error.TestUnexpectedResult,
    }
    tx.deinit();
    const check = switch (connection.prepare("SELECT count(*) FROM t")) {
        .ok => |value| value,
        .err => return error.TestUnexpectedResult,
    };
    defer check.finalize();
    const row = switch (check.step()) {
        .ok => |value| value.row,
        .err => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(i64, 0), row.value(0).integer);
    const live = switch (connection.prepare("SELECT 1")) {
        .ok => |value| value,
        .err => return error.TestUnexpectedResult,
    };
    switch (connection.close()) {
        .ok => {},
        .err => return error.TestUnexpectedResult,
    }
    live.finalize();
    var work = executor.TestExecutor.init(std.testing.allocator);
    defer work.deinit();
    var completion = executor.TestExecutor.init(std.testing.allocator);
    defer completion.deinit();
    const second = switch (Connection.openMemory(std.testing.allocator)) {
        .ok => |value| value,
        .err => return error.TestUnexpectedResult,
    };
    defer second.deinit();
    const Probe = struct {
        calls: usize = 0,
        fn done(context: ?*anyopaque, result: Result(void)) void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            std.debug.assert(result == .ok);
            self.calls += 1;
        }
    };
    var probe = Probe{};
    try executeAsync(second, "CREATE TABLE async_t (v INTEGER)", work.executor(), completion.executor(), null, Probe.done, &probe);
    _ = work.pump();
    try std.testing.expectEqual(@as(usize, 0), probe.calls);
    _ = completion.pump();
    try std.testing.expectEqual(@as(usize, 1), probe.calls);
}

test "constraints, commit, shared-cache lock, and interruption retain native codes" {
    const connection = switch (Connection.openMemory(std.testing.allocator)) {
        .ok => |value| value,
        .err => return error.TestUnexpectedResult,
    };
    defer connection.deinit();
    switch (connection.execute("CREATE TABLE t (id INTEGER PRIMARY KEY)")) {
        .ok => {},
        .err => return error.TestUnexpectedResult,
    }
    switch (connection.execute("INSERT INTO t VALUES (1)")) {
        .ok => {},
        .err => return error.TestUnexpectedResult,
    }
    const duplicate = connection.execute("INSERT INTO t VALUES (1)");
    try std.testing.expect(duplicate == .err);
    try std.testing.expectEqual(@as(i32, SQLITE_CONSTRAINT), duplicate.err.native_code & 0xff);
    const syntax = connection.execute("INSER broken");
    try std.testing.expect(syntax == .err);
    try std.testing.expectEqual(@as(i32, SQLITE_ERROR), syntax.err.native_code & 0xff);
    const transaction = switch (connection.begin()) {
        .ok => |value| value,
        .err => return error.TestUnexpectedResult,
    };
    switch (connection.execute("INSERT INTO t VALUES (2)")) {
        .ok => {},
        .err => return error.TestUnexpectedResult,
    }
    switch (transaction.commit()) {
        .ok => {},
        .err => return error.TestUnexpectedResult,
    }

    const uri: [:0]const u8 = "file:foundation_sqlite_lock?mode=memory&cache=shared";
    const first = switch (Connection.open(std.testing.allocator, uri, .{ .uri = true, .busy_timeout_ms = 1 })) {
        .ok => |value| value,
        .err => return error.TestUnexpectedResult,
    };
    defer first.deinit();
    const second = switch (Connection.open(std.testing.allocator, uri, .{ .uri = true, .busy_timeout_ms = 1 })) {
        .ok => |value| value,
        .err => return error.TestUnexpectedResult,
    };
    defer second.deinit();
    switch (first.execute("CREATE TABLE locked (v INTEGER)")) {
        .ok => {},
        .err => return error.TestUnexpectedResult,
    }
    switch (first.execute("BEGIN IMMEDIATE")) {
        .ok => {},
        .err => return error.TestUnexpectedResult,
    }
    switch (first.execute("INSERT INTO locked VALUES (1)")) {
        .ok => {},
        .err => return error.TestUnexpectedResult,
    }
    const locked = second.execute("INSERT INTO locked VALUES (2)");
    try std.testing.expect(locked == .err);
    try std.testing.expect(locked.err.native_code & 0xff == SQLITE_BUSY or locked.err.native_code & 0xff == SQLITE_LOCKED);
    switch (first.execute("ROLLBACK")) {
        .ok => {},
        .err => return error.TestUnexpectedResult,
    }

    const interrupted = switch (Connection.openMemory(std.testing.allocator)) {
        .ok => |value| value,
        .err => return error.TestUnexpectedResult,
    };
    defer interrupted.deinit();
    const Probe = struct {
        done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        code: std.atomic.Value(i32) = std.atomic.Value(i32).init(SQLITE_OK),
        fn run(db: *Connection, probe: *@This()) void {
            const result = db.execute("WITH RECURSIVE count(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM count WHERE x<1000000000) SELECT sum(x) FROM count");
            probe.code.store(switch (result) {
                .ok => SQLITE_OK,
                .err => |err| err.native_code & 0xff,
            }, .release);
            probe.done.store(true, .release);
        }
    };
    var probe = Probe{};
    const worker = try std.Thread.spawn(.{}, Probe.run, .{ interrupted, &probe });
    while (!probe.done.load(.acquire)) {
        interrupted.interrupt();
        std.Thread.yield() catch {};
    }
    worker.join();
    try std.testing.expectEqual(@as(i32, SQLITE_INTERRUPT), probe.code.load(.acquire));
}
