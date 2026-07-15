//! Evidence collection benchmark. It intentionally has no pass/fail threshold.
const std = @import("std");
const foundation = @import("foundation");

const warmup_samples = 3;
const measured_samples = 15;
const iterations_per_sample = 1_000;

const Workload = enum { game, agent, tooling, server, core };

pub fn main() !void {
    const workload = selectedWorkload();
    var samples: [measured_samples]u64 = undefined;
    var allocation_events: u64 = 0;
    var high_water_bytes: usize = 0;
    var cancellation_total_ns: u64 = 0;
    var shutdown_total_ns: u64 = 0;

    for (0..warmup_samples) |_| {
        _ = try runWorkload(workload, &allocation_events, &high_water_bytes, &cancellation_total_ns, &shutdown_total_ns);
    }
    allocation_events = 0;
    high_water_bytes = 0;
    cancellation_total_ns = 0;
    shutdown_total_ns = 0;
    for (&samples) |*sample| {
        sample.* = try runWorkload(workload, &allocation_events, &high_water_bytes, &cancellation_total_ns, &shutdown_total_ns);
    }

    var sorted = samples;
    insertionSort(&sorted);
    var total_ns: u64 = 0;
    for (samples) |sample| total_ns += sample;
    const operations = measured_samples * iterations_per_sample;
    const p50 = sorted[measured_samples / 2];
    const p95 = sorted[(measured_samples * 95 + 99) / 100 - 1];
    const mean_ns = total_ns / measured_samples;
    const throughput = @as(f64, @floatFromInt(operations)) * @as(f64, std.time.ns_per_s) / @as(f64, @floatFromInt(total_ns));

    // stderr is used so result capture remains available to build runners.
    std.debug.print(
        "{{\"schema_version\":1,\"profile\":\"{s}\",\"workload\":\"{s}\",\"warmup_samples\":{d},\"measured_samples\":{d},\"iterations_per_sample\":{d},\"toolchain\":\"Zig {s}\",\"machine\":\"runner metadata required; see docs/platform-optimization.md\",\"latency_ns\":{{\"mean\":{d},\"p50\":{d},\"p95\":{d},\"min\":{d},\"max\":{d}}},\"throughput_ops_per_second\":{d:.3},\"allocation_events\":{d},\"allocation_high_water_bytes\":{d},\"cpu_time_ns\":null,\"binary_size_bytes\":null,\"cancellation_latency_ns\":{d},\"shutdown_time_ns\":{d},\"sample_latency_ns\":[",
        .{ foundation.build_options.profile, @tagName(workload), warmup_samples, measured_samples, iterations_per_sample, builtinZigVersion(), mean_ns, p50, p95, sorted[0], sorted[measured_samples - 1], throughput, allocation_events, high_water_bytes, cancellation_total_ns / operations, shutdown_total_ns / measured_samples },
    );
    for (samples, 0..) |sample, index| std.debug.print("{s}{d}", .{ if (index == 0) "" else ",", sample });
    std.debug.print("]}}\n", .{});
}

fn builtinZigVersion() []const u8 {
    const version = @import("builtin").zig_version;
    return std.fmt.comptimePrint("{d}.{d}.{d}", .{ version.major, version.minor, version.patch });
}

fn selectedWorkload() Workload {
    if (std.mem.eql(u8, foundation.build_options.profile, "game")) return .game;
    if (std.mem.eql(u8, foundation.build_options.profile, "agent")) return .agent;
    if (std.mem.eql(u8, foundation.build_options.profile, "tooling")) return .tooling;
    if (std.mem.eql(u8, foundation.build_options.profile, "server")) return .server;
    return .core;
}

fn runWorkload(workload: Workload, allocation_events: *u64, high_water_bytes: *usize, cancellation_total_ns: *u64, shutdown_total_ns: *u64) !u64 {
    const start = monotonicNow();
    switch (workload) {
        .game, .tooling, .core => try bufferWorkload(allocation_events, high_water_bytes),
        .agent => try agentWorkload(allocation_events, high_water_bytes),
        .server => try serverWorkload(allocation_events, high_water_bytes, cancellation_total_ns, shutdown_total_ns),
    }
    return elapsedSince(start);
}

fn bufferWorkload(allocation_events: *u64, high_water_bytes: *usize) !void {
    const payload = "foundation benchmark payload: ownership, allocation, and executor paths";
    var budget = foundation.memory.AllocationBudget.init(payload.len);
    for (0..iterations_per_sample) |_| {
        var buffer = try foundation.memory.SharedBuffer.initCopyWithBudget(std.heap.page_allocator, payload, .general, &budget, .{});
        var clone = try buffer.clone();
        clone.release();
        buffer.release();
        allocation_events.* += 2; // Storage and payload allocations made by SharedBuffer.
        high_water_bytes.* = @max(high_water_bytes.*, payload.len);
    }
}

fn agentWorkload(allocation_events: *u64, high_water_bytes: *usize) !void {
    if (comptime !foundation.build_options.json) return bufferWorkload(allocation_events, high_water_bytes);
    const source = "{\"request\":\"benchmark\",\"attempt\":1,\"items\":[1,2,3,4]}";
    for (0..iterations_per_sample) |_| {
        var document = try foundation.json.stdCodec().parse(std.heap.page_allocator, source, .{});
        document.deinit();
        allocation_events.* += 1; // std.json allocations are intentionally reported as a lower bound.
        high_water_bytes.* = @max(high_water_bytes.*, source.len);
    }
}

fn serverWorkload(allocation_events: *u64, high_water_bytes: *usize, cancellation_total_ns: *u64, shutdown_total_ns: *u64) !void {
    for (0..iterations_per_sample) |_| {
        var source = try foundation.cancellation.CancellationSource.init(std.heap.page_allocator);
        var token = source.token();
        const cancel_start = monotonicNow();
        _ = source.cancel(.requested);
        cancellation_total_ns.* += elapsedSince(cancel_start);
        token.deinit();
        source.deinit();
        allocation_events.* += 1;
        high_water_bytes.* = @max(high_water_bytes.*, @sizeOf(usize) * 8);
    }
    var queue = foundation.executor.MainThreadQueue.init(std.heap.page_allocator);
    const shutdown_start = monotonicNow();
    queue.close();
    queue.deinit();
    shutdown_total_ns.* += elapsedSince(shutdown_start);
}

fn insertionSort(values: *[measured_samples]u64) void {
    for (1..values.len) |index| {
        const item = values[index];
        var cursor = index;
        while (cursor > 0 and values[cursor - 1] > item) : (cursor -= 1) values[cursor] = values[cursor - 1];
        values[cursor] = item;
    }
}

fn monotonicNow() i64 {
    var clock = foundation.time.SystemClock{};
    return clock.clock().monotonicNow().nanoseconds;
}

fn elapsedSince(start: i64) u64 {
    return @intCast(@max(0, monotonicNow() -| start));
}
