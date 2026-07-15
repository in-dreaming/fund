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

    const cabi_library = b.addLibrary(.{ .name = "foundation", .root_module = foundation, .linkage = .static });
    const install_cabi = b.addInstallArtifact(cabi_library, .{});
    const install_header = b.addInstallFile(b.path("include/foundation.h"), "include/foundation.h");
    const cabi_step = b.step("cabi", "Build the static C ABI library and public header");
    cabi_step.dependOn(&install_cabi.step);
    cabi_step.dependOn(&install_header.step);

    const cabi_smoke = b.addExecutable(.{
        .name = "cabi_smoke",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }),
    });
    cabi_smoke.root_module.addCSourceFile(.{ .file = b.path("tests/cabi_smoke.c"), .flags = &.{"-std=c11"} });
    cabi_smoke.root_module.addIncludePath(b.path("include"));
    cabi_smoke.root_module.linkLibrary(cabi_library);
    const run_cabi_smoke = b.addRunArtifact(cabi_smoke);
    const cabi_test_step = b.step("cabi-test", "Compile and run a C11 consumer of foundation.h");
    cabi_test_step.dependOn(&run_cabi_smoke.step);

    const cabi_cpp_smoke = b.addExecutable(.{
        .name = "cabi_cpp_smoke",
        .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libcpp = true }),
    });
    cabi_cpp_smoke.root_module.addCSourceFile(.{ .file = b.path("tests/cabi_cpp.cpp"), .flags = &.{"-std=c++17"} });
    cabi_cpp_smoke.root_module.addIncludePath(b.path("include"));
    cabi_cpp_smoke.root_module.linkLibrary(cabi_library);
    const run_cabi_cpp_smoke = b.addRunArtifact(cabi_cpp_smoke);
    cabi_test_step.dependOn(&run_cabi_cpp_smoke.step);

    const fixture_plugin_module = b.createModule(.{
        .root_source_file = b.path("tests/fixture_plugin.zig"),
        .target = target,
        .optimize = optimize,
    });
    fixture_plugin_module.addImport("foundation", foundation);
    const fixture_plugin = b.addLibrary(.{ .name = "foundation_fixture_plugin", .root_module = fixture_plugin_module, .linkage = .dynamic });
    cabi_test_step.dependOn(&fixture_plugin.step);

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
