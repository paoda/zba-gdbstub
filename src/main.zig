const std = @import("std");
const Server = @import("gdbstub").Server;

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
