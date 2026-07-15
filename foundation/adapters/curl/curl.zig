const std = @import("std");
const builtin = @import("builtin");
const foundation = @import("foundation");
const http = foundation.http;
const errors = foundation.errors;

const CURL = ?*anyopaque;
const CURLcode = c_int;
const CURL_GLOBAL_DEFAULT: c_long = 3;
const CURLE_OK: CURLcode = 0;
const CURLE_OPERATION_TIMEDOUT: CURLcode = 28;
const CURLE_ABORTED_BY_CALLBACK: CURLcode = 42;
const CURLOPT_WRITEDATA: c_uint = 10001;
const CURLOPT_URL: c_uint = 10002;
const CURLOPT_PROXY: c_uint = 10004;
const CURLOPT_WRITEFUNCTION: c_uint = 20011;
const CURLOPT_POSTFIELDS: c_uint = 10015;
const CURLOPT_HTTPHEADER: c_uint = 10023;
const CURLOPT_SSLCERT: c_uint = 10025;
const CURLOPT_HEADERDATA: c_uint = 10029;
const CURLOPT_CUSTOMREQUEST: c_uint = 10036;
const CURLOPT_NOBODY: c_uint = 44;
const CURLOPT_FOLLOWLOCATION: c_uint = 52;
const CURLOPT_SSL_VERIFYPEER: c_uint = 64;
const CURLOPT_CAINFO: c_uint = 10065;
const CURLOPT_MAXREDIRS: c_uint = 68;
const CURLOPT_HEADERFUNCTION: c_uint = 20079;
const CURLOPT_SSL_VERIFYHOST: c_uint = 81;
const CURLOPT_SSLKEY: c_uint = 10087;
const CURLOPT_NOSIGNAL: c_uint = 99;
const CURLOPT_POSTFIELDSIZE_LARGE: c_uint = 30120;
const CURLOPT_TIMEOUT_MS: c_uint = 155;
const CURLINFO_RESPONSE_CODE: c_uint = 0x200002;

const EasyInit = *const fn () callconv(.c) CURL;
const EasyCleanup = *const fn (CURL) callconv(.c) void;
const EasyPerform = *const fn (CURL) callconv(.c) CURLcode;
const EasySetopt = *const fn (CURL, c_uint, ...) callconv(.c) CURLcode;
const EasyGetinfo = *const fn (CURL, c_uint, ...) callconv(.c) CURLcode;
const GlobalInit = *const fn (c_long) callconv(.c) CURLcode;
const GlobalCleanup = *const fn () callconv(.c) void;
const SlistAppend = *const fn (?*anyopaque, [*:0]const u8) callconv(.c) ?*anyopaque;
const SlistFreeAll = *const fn (?*anyopaque) callconv(.c) void;

const Hmodule = ?*anyopaque;
extern "kernel32" fn LoadLibraryA(path: [*:0]const u8) callconv(.winapi) Hmodule;
extern "kernel32" fn GetProcAddress(module: Hmodule, name: [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn FreeLibrary(module: Hmodule) callconv(.winapi) i32;

const Api = struct {
    library: Hmodule,
    global_init: GlobalInit,
    global_cleanup: GlobalCleanup,
    easy_init: EasyInit,
    easy_cleanup: EasyCleanup,
    easy_perform: EasyPerform,
    easy_setopt: EasySetopt,
    easy_getinfo: EasyGetinfo,
    slist_append: SlistAppend,
    slist_free_all: SlistFreeAll,

    fn open(path: []const u8) !Api {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        const path_z = try std.heap.page_allocator.dupeZ(u8, path);
        defer std.heap.page_allocator.free(path_z);
        const library = LoadLibraryA(path_z.ptr) orelse return error.LibraryNotFound;
        errdefer _ = FreeLibrary(library);
        const api = Api{
            .library = library,
            .global_init = symbol(GlobalInit, library, "curl_global_init") orelse return error.MissingSymbol,
            .global_cleanup = symbol(GlobalCleanup, library, "curl_global_cleanup") orelse return error.MissingSymbol,
            .easy_init = symbol(EasyInit, library, "curl_easy_init") orelse return error.MissingSymbol,
            .easy_cleanup = symbol(EasyCleanup, library, "curl_easy_cleanup") orelse return error.MissingSymbol,
            .easy_perform = symbol(EasyPerform, library, "curl_easy_perform") orelse return error.MissingSymbol,
            .easy_setopt = symbol(EasySetopt, library, "curl_easy_setopt") orelse return error.MissingSymbol,
            .easy_getinfo = symbol(EasyGetinfo, library, "curl_easy_getinfo") orelse return error.MissingSymbol,
            .slist_append = symbol(SlistAppend, library, "curl_slist_append") orelse return error.MissingSymbol,
            .slist_free_all = symbol(SlistFreeAll, library, "curl_slist_free_all") orelse return error.MissingSymbol,
        };
        if (api.global_init(CURL_GLOBAL_DEFAULT) != CURLE_OK) return error.GlobalInitFailed;
        return api;
    }
    fn close(self: *Api) void {
        self.global_cleanup();
        _ = FreeLibrary(self.library);
    }
};
fn symbol(comptime T: type, library: Hmodule, name: [:0]const u8) ?T {
    return @ptrCast(GetProcAddress(library, name) orelse return null);
}

const Pending = struct {
    operation: *http.HttpOperation,
    url: [:0]u8,
    method: [:0]u8,
    body: []u8,
    headers: [][:0]u8,
    options: http.Options,
    ca_bundle_path: ?[:0]u8 = null,
    client_certificate_path: ?[:0]u8 = null,
    client_key_path: ?[:0]u8 = null,
    proxy_url: ?[:0]u8 = null,
    fn deinit(self: *Pending, allocator: std.mem.Allocator) void {
        allocator.free(self.url);
        allocator.free(self.method);
        allocator.free(self.body);
        for (self.headers) |header| allocator.free(header);
        allocator.free(self.headers);
        if (self.ca_bundle_path) |value| allocator.free(value);
        if (self.client_certificate_path) |value| allocator.free(value);
        if (self.client_key_path) |value| allocator.free(value);
        if (self.proxy_url) |value| allocator.free(value);
    }
};

/// Host-pumped libcurl HTTP adapter. `pump` runs libcurl on its caller thread;
/// completion is still posted only to the executor selected in `HttpClient.start`.
/// `init`/`deinit` explicitly own libcurl global state and create no worker thread.
pub const CurlClient = struct {
    allocator: std.mem.Allocator,
    api: Api,
    pending: std.ArrayListUnmanaged(Pending) = .empty,

    pub fn init(allocator: std.mem.Allocator, library_path: []const u8) !CurlClient {
        return .{ .allocator = allocator, .api = try Api.open(library_path) };
    }
    pub fn initBundled(allocator: std.mem.Allocator) !CurlClient {
        return init(allocator, "third_party/curl/windows-x64/bin/libcurl-x64.dll");
    }
    pub fn deinit(self: *CurlClient) void {
        for (self.pending.items) |*pending| {
            pending.operation.cancel();
            pending.operation.deinit();
            pending.deinit(self.allocator);
        }
        self.pending.deinit(self.allocator);
        self.api.close();
        self.* = undefined;
    }
    pub fn client(self: *CurlClient) http.HttpClient {
        return .{ .context = self, .vtable = &vtable };
    }
    /// Performs at most one pending transfer. It may block the calling host
    /// thread up to the request timeout; applications drive it from their I/O loop.
    pub fn pump(self: *CurlClient) void {
        if (self.pending.items.len == 0) return;
        var pending = self.pending.orderedRemove(0);
        defer pending.deinit(self.allocator);
        var token = pending.operation.token();
        defer token.deinit();
        if (token.isCancelled()) {
            http.finish(pending.operation, .cancelled);
            return;
        }
        const easy = self.api.easy_init() orelse {
            http.finish(pending.operation, .{ .failure = .{ .category = .unavailable, .message = "curl easy handle unavailable" } });
            return;
        };
        defer self.api.easy_cleanup(easy);
        var slist: ?*anyopaque = null;
        defer if (slist) |list| self.api.slist_free_all(list);
        for (pending.headers) |header| slist = self.api.slist_append(slist, header.ptr) orelse {
            http.finish(pending.operation, .{ .failure = .{ .category = .resource_exhausted, .message = "curl header allocation failed" } });
            return;
        };
        var response = std.ArrayListUnmanaged(u8){};
        defer response.deinit(self.allocator);
        const context = CallbackContext{ .allocator = self.allocator, .response = &response, .limit = pending.options.response_body_limit, .cancelled = &token };
        if (!set(self.api.easy_setopt(easy, CURLOPT_URL, pending.url.ptr)) or !set(self.api.easy_setopt(easy, CURLOPT_CUSTOMREQUEST, pending.method.ptr)) or !set(self.api.easy_setopt(easy, CURLOPT_NOSIGNAL, @as(c_long, 1))) or !set(self.api.easy_setopt(easy, CURLOPT_TIMEOUT_MS, @as(c_long, @intCast(@min(pending.options.timeout_ms, std.math.maxInt(c_long)))))) or !set(self.api.easy_setopt(easy, CURLOPT_WRITEFUNCTION, writeCallback)) or !set(self.api.easy_setopt(easy, CURLOPT_WRITEDATA, &context))) {
            http.finish(pending.operation, .{ .failure = .{ .category = .internal, .message = "curl option setup failed" } });
            return;
        }
        if (pending.body.len != 0) {
            _ = self.api.easy_setopt(easy, CURLOPT_POSTFIELDS, pending.body.ptr);
            _ = self.api.easy_setopt(easy, CURLOPT_POSTFIELDSIZE_LARGE, @as(i64, @intCast(pending.body.len)));
        }
        if (slist != null) _ = self.api.easy_setopt(easy, CURLOPT_HTTPHEADER, slist);
        applyOptions(&self.api, easy, &pending);
        const code = self.api.easy_perform(easy);
        if (code != CURLE_OK) {
            http.finish(pending.operation, resultForCode(code, token.isCancelled()));
            return;
        }
        var status: c_long = 0;
        _ = self.api.easy_getinfo(easy, CURLINFO_RESPONSE_CODE, &status);
        const body = foundation.memory.SharedBuffer.initCopy(self.allocator, response.items, .network) catch {
            http.finish(pending.operation, .{ .failure = .{ .category = .resource_exhausted, .message = "response allocation failed" } });
            return;
        };
        http.finish(pending.operation, .{ .response = .{ .status = @intCast(@max(status, 0)), .body = body, .allocator = self.allocator } });
    }
    fn start(raw: ?*anyopaque, allocator: std.mem.Allocator, request: http.Request, options: http.Options, completion: http.Completion, userdata: ?*anyopaque) http.StartError!*http.HttpOperation {
        const self: *CurlClient = @ptrCast(@alignCast(raw.?));
        const header_lines = try copyHeaders(allocator, request.headers);
        errdefer freeHeaders(allocator, header_lines);
        var pending = Pending{ .operation = try http.createOperation(allocator, options, completion, userdata), .url = try allocator.dupeZ(u8, request.url), .method = try allocator.dupeZ(u8, @tagName(request.method)), .body = try allocator.dupe(u8, request.body), .headers = header_lines, .options = options };
        errdefer {
            pending.operation.deinit();
            pending.deinit(allocator);
        }
        if (options.tls.ca_bundle_path) |value| pending.ca_bundle_path = try allocator.dupeZ(u8, value);
        if (options.tls.client_certificate_path) |value| pending.client_certificate_path = try allocator.dupeZ(u8, value);
        if (options.tls.client_key_path) |value| pending.client_key_path = try allocator.dupeZ(u8, value);
        if (options.proxy == .url) pending.proxy_url = try allocator.dupeZ(u8, options.proxy.url);
        try self.pending.append(self.allocator, pending);
        return pending.operation;
    }
    const vtable = http.VTable{ .start = start };
};
fn copyHeaders(allocator: std.mem.Allocator, headers: []const http.Header) ![][:0]u8 {
    const output = try allocator.alloc([:0]u8, headers.len);
    errdefer allocator.free(output);
    var initialized: usize = 0;
    errdefer for (output[0..initialized]) |header| allocator.free(header);
    for (headers) |header| {
        output[initialized] = try std.fmt.allocPrintZ(allocator, "{s}: {s}", .{ header.name, header.value });
        initialized += 1;
    }
    return output;
}
fn freeHeaders(allocator: std.mem.Allocator, headers: []const [:0]u8) void {
    for (headers) |header| allocator.free(header);
    allocator.free(headers);
}

const CallbackContext = struct { allocator: std.mem.Allocator, response: *std.ArrayListUnmanaged(u8), limit: usize, cancelled: *foundation.cancellation.Token };
fn writeCallback(bytes: [*]u8, size: usize, count: usize, raw: ?*anyopaque) callconv(.c) usize {
    const context: *const CallbackContext = @ptrCast(@alignCast(raw.?));
    const len = size *| count;
    if (context.cancelled.isCancelled() or len > context.limit -| context.response.items.len) return 0;
    context.response.appendSlice(context.allocator, bytes[0..len]) catch return 0;
    return len;
}
fn set(code: CURLcode) bool {
    return code == CURLE_OK;
}
fn applyOptions(api: *const Api, easy: CURL, pending: *const Pending) void {
    const options = pending.options;
    _ = api.easy_setopt(easy, CURLOPT_SSL_VERIFYPEER, @as(c_long, if (options.tls.verify_peer) 1 else 0));
    _ = api.easy_setopt(easy, CURLOPT_SSL_VERIFYHOST, @as(c_long, if (options.tls.verify_host) 2 else 0));
    switch (options.redirects) {
        .deny => _ = api.easy_setopt(easy, CURLOPT_FOLLOWLOCATION, @as(c_long, 0)),
        .follow => |limit| {
            _ = api.easy_setopt(easy, CURLOPT_FOLLOWLOCATION, @as(c_long, 1));
            _ = api.easy_setopt(easy, CURLOPT_MAXREDIRS, @as(c_long, limit));
        },
    }
    switch (options.proxy) {
        .disabled => _ = api.easy_setopt(easy, CURLOPT_PROXY, ""),
        .url => _ = api.easy_setopt(easy, CURLOPT_PROXY, pending.proxy_url.?.ptr),
        .system => {},
    }
    if (pending.ca_bundle_path) |path| _ = api.easy_setopt(easy, CURLOPT_CAINFO, path.ptr);
    if (pending.client_certificate_path) |path| _ = api.easy_setopt(easy, CURLOPT_SSLCERT, path.ptr);
    if (pending.client_key_path) |path| _ = api.easy_setopt(easy, CURLOPT_SSLKEY, path.ptr);
}
fn resultForCode(code: CURLcode, cancelled: bool) http.Result {
    if (cancelled or code == CURLE_ABORTED_BY_CALLBACK) return .cancelled;
    return .{ .failure = .{ .category = if (code == CURLE_OPERATION_TIMEDOUT) .timeout else .network, .native_code = code, .message = "curl transfer failed" } };
}

test "curl adapter preserves native error classification" {
    const result = resultForCode(CURLE_OPERATION_TIMEDOUT, false);
    switch (result) {
        .failure => |failure| {
            try std.testing.expectEqual(errors.ErrorCategory.timeout, failure.category);
            try std.testing.expectEqual(@as(i64, CURLE_OPERATION_TIMEDOUT), failure.native_code);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "bundled curl library loads without creating a client worker" {
    var client = try CurlClient.initBundled(std.testing.allocator);
    defer client.deinit();
    try std.testing.expectEqual(@as(usize, 0), client.pending.items.len);
}
