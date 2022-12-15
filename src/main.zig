const std = @import("std");
const network = @import("network");
const Server = @import("Server.zig");

const Allocator = std.mem.Allocator;
const Socket = network.Socket;

pub const target: []const u8 =
    \\<target version="1.0">
    \\    <architecture>armv4t</architecture>
    \\    <feature name="org.gnu.gdb.arm.core">
    \\        <reg name="r0" bitsize="32" type="uint32"/>
    \\        <reg name="r1" bitsize="32" type="uint32"/>
    \\        <reg name="r2" bitsize="32" type="uint32"/>
    \\        <reg name="r3" bitsize="32" type="uint32"/>
    \\        <reg name="r4" bitsize="32" type="uint32"/>
    \\        <reg name="r5" bitsize="32" type="uint32"/>
    \\        <reg name="r6" bitsize="32" type="uint32"/>
    \\        <reg name="r7" bitsize="32" type="uint32"/>
    \\        <reg name="r8" bitsize="32" type="uint32"/>
    \\        <reg name="r9" bitsize="32" type="uint32"/>
    \\        <reg name="r10" bitsize="32" type="uint32"/>
    \\        <reg name="r11" bitsize="32" type="uint32"/>
    \\        <reg name="r12" bitsize="32" type="uint32"/>
    \\        <reg name="sp" bitsize="32" type="data_ptr"/>
    \\        <reg name="lr" bitsize="32"/>
    \\        <reg name="pc" bitsize="32" type="code_ptr"/>
    \\
    \\        <reg name="cpsr" bitsize="32" regnum="25"/>
    \\    </feature>
    \\</target>
;

pub fn main() !void {
    const log = std.log.scoped(.Main);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());

    const allocator = gpa.allocator();

    var server = try Server.init();
    defer server.deinit(allocator);

    try server.run(allocator);

    log.info("Client disconnected", .{});
}
