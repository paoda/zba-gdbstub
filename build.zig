const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const net_dep = b.dependency("zig-network", .{}); // https://github.com/MasterQ32/zig-network

    _ = b.addModule("gdbstub", .{
        .source_file = .{ .path = "src/lib.zig" },
        .dependencies = &.{.{ .name = "network", .module = net_dep.module("network") }},
    });

    const lib_test = b.addTest(.{ .root_source_file = .{ .path = "src/lib.zig" }, .target = target });

    const test_step = b.step("test", "Run Library Tests");
    test_step.dependOn(&lib_test.step);
}
