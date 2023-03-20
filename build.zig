const std = @import("std");
const CompileStep = std.Build.CompileStep;

fn path(comptime suffix: []const u8) []const u8 {
    if (suffix[0] == '/') @compileError("expected a relative path");
    return comptime (std.fs.path.dirname(@src().file) orelse ".") ++ std.fs.path.sep_str ++ suffix;
}

pub fn getModule(b: *std.Build) *std.build.Module {
    // https://github.com/MasterQ32/zig-network
    const network = b.createModule(.{ .source_file = .{ .path = path("lib/zig-network/network.zig") } });

    return b.createModule(.{
        .source_file = .{ .path = path("src/lib.zig") },
        .dependencies = &.{.{ .name = "network", .module = network }},
    });
}

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    // const optimize = b.standardOptimizeOption(.{});

    // -- Library --

    const lib_test = b.addTest(.{
        .root_source_file = .{ .path = "src/lib.zig" },
        .target = target,
    });

    const test_step = b.step("test", "Run Library Tests");
    test_step.dependOn(&lib_test.step);

    // -- Executable --

    // const exe = b.addExecutable(.{
    //     .name = "gdbserver",
    //     .root_source_file = .{ .path = "src/main.zig" },
    //     .target = target,
    //     .optimize = optimize,
    // });
    // link(exe);
    // exe.install();

    // const run_cmd = exe.run();
    // run_cmd.step.dependOn(b.getInstallStep());
    // if (b.args) |args| run_cmd.addArgs(args);

    // const run_step = b.step("run", "Run the app");
    // run_step.dependOn(&run_cmd.step);
}
