const std = @import("std");

/// Correlation only. It deliberately carries no workflow or replay semantics.
pub const Context = struct {
    trace_id: u128 = 0,
    span_id: u64 = 0,
    flags: u8 = 0,
    pub fn isValid(self: Context) bool {
        return self.trace_id != 0;
    }
};

pub const Zone = struct { active: bool = false };
pub const SinkVTable = struct {
    begin_zone: *const fn (?*anyopaque, []const u8, Context) Zone,
    end_zone: *const fn (?*anyopaque, Zone) void,
    frame: *const fn (?*anyopaque, []const u8) void,
    plot: *const fn (?*anyopaque, []const u8, f64) void,
};

/// Borrowed performance-tracing facade. Calls run on the calling thread; sinks
/// must not retain names or contexts. The no-op sink allocates nothing.
pub const Trace = struct {
    context: ?*anyopaque,
    vtable: *const SinkVTable,
    pub fn beginZone(self: Trace, name: []const u8, context: Context) Zone {
        return self.vtable.begin_zone(self.context, name, context);
    }
    pub fn endZone(self: Trace, zone: Zone) void {
        self.vtable.end_zone(self.context, zone);
    }
    pub fn frame(self: Trace, name: []const u8) void {
        self.vtable.frame(self.context, name);
    }
    pub fn plot(self: Trace, name: []const u8, value: f64) void {
        self.vtable.plot(self.context, name, value);
    }
};

pub const NoopSink = struct {
    pub fn trace(_: *NoopSink) Trace {
        return .{ .context = null, .vtable = &vtable };
    }
    fn begin(_: ?*anyopaque, _: []const u8, _: Context) Zone {
        return .{};
    }
    fn end(_: ?*anyopaque, _: Zone) void {}
    fn frame(_: ?*anyopaque, _: []const u8) void {}
    fn plot(_: ?*anyopaque, _: []const u8, _: f64) void {}
    const vtable = SinkVTable{ .begin_zone = begin, .end_zone = end, .frame = frame, .plot = plot };
};

test "noop trace hot path allocates nothing" {
    var sink = NoopSink{};
    const facade = sink.trace();
    const zone = facade.beginZone("hot", .{});
    facade.plot("load", 1.0);
    facade.frame("frame");
    facade.endZone(zone);
}
