const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const profile = b.option([]const u8, "profile", "Build profile: core, game, agent, tooling, or server") orelse "core";
    const enable_http = b.option(bool, "http", "Enable the HTTP capability") orelse false;
    const enable_database = b.option(bool, "database", "Enable the database capability") orelse false;
    const enable_compression = b.option(bool, "compression", "Enable compression capabilities") orelse false;
    const enable_profiler = b.option(bool, "profiler", "Enable profiler capability") orelse false;
    const enable_process = b.option(bool, "process", "Enable process capability") orelse false;

    if (!std.mem.eql(u8, profile, "core") and !std.mem.eql(u8, profile, "game") and !std.mem.eql(u8, profile, "agent") and !std.mem.eql(u8, profile, "tooling") and !std.mem.eql(u8, profile, "server")) {
        @panic("-Dprofile must be core, game, agent, tooling, or server");
    }

    const options = b.addOptions();
    options.addOption([]const u8, "profile", profile);
    options.addOption(bool, "http", enable_http);
    options.addOption(bool, "database", enable_database);
    options.addOption(bool, "compression", enable_compression);
    options.addOption(bool, "profiler", enable_profiler);
    options.addOption(bool, "process", enable_process);

    const foundation = b.addModule("foundation", .{
        .root_source_file = b.path("src/foundation.zig"),
        .target = target,
        .optimize = optimize,
    });
    foundation.addOptions("build_options", options);

    const tests = b.addTest(.{ .root_module = foundation });
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run Foundation tests");
    test_step.dependOn(&run_tests.step);

    const dependency_check = b.addSystemCommand(&.{ "zig", "run", "tools/dependency_check.zig", "--", "third_party/manifests/entries" });
    const dependency_step = b.step("dependency-check", "Validate dependency manifests");
    dependency_step.dependOn(&dependency_check.step);

    const boundary_check = b.addSystemCommand(&.{ "zig", "run", "tools/boundary_check.zig", "--", "src", "include", "examples" });
    const boundary_step = b.step("boundary-check", "Reject vendor imports outside adapters");
    boundary_step.dependOn(&boundary_check.step);

    const check_step = b.step("check", "Run Foundation governance checks");
    check_step.dependOn(&dependency_check.step);
    check_step.dependOn(&boundary_check.step);
}
