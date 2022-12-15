const std = @import("std");

fn path(comptime suffix: []const u8) []const u8 {
    if (suffix[0] == '/') @compileError("expected a relative path");
    return comptime (std.fs.path.dirname(@src().file) orelse ".") ++ std.fs.path.sep_str ++ suffix;
}

const pkgs = struct {
    const Pkg = std.build.Pkg;

    pub const gdbstub: Pkg = .{
        .name = "gdbstub",
        .source = .{ .path = path("src/lib.zig") },
        .dependencies = &[_]Pkg{network},
    };

    // https://github.com/MasterQ32/zig-network
    pub const network: Pkg = .{
        .name = "network",
        .source = .{ .path = path("lib/zig-network/network.zig") },
    };
};

pub fn link(exe: *std.build.LibExeObjStep) void {
    exe.addPackage(pkgs.gdbstub);
}

pub fn build(b: *std.build.Builder) void {
    const target = b.standardTargetOptions(.{});
    const mode = b.standardReleaseOptions();

    // -- library --
    const lib = b.addStaticLibrary("gdbstub", "src/lib.zig");
    lib.addPackage(pkgs.network);

    lib.setBuildMode(mode);
    lib.install();

    const lib_tests = b.addTest("src/lib.zig");
    lib_tests.setBuildMode(mode);

    const test_step = b.step("lib-test", "Run Library Tests");
    test_step.dependOn(&lib_tests.step);

    // -- Executable --
    const exe = b.addExecutable("gdbserver", "src/main.zig");
    link(exe);

    exe.setTarget(target);
    exe.setBuildMode(mode);
    exe.install();

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
