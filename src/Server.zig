const std = @import("std");
const network = @import("network");
const Packet = @import("Packet.zig");

const Socket = network.Socket;
const Allocator = std.mem.Allocator;
const Emulator = @import("lib.zig").Emulator;

const Self = @This();
const log = std.log.scoped(.Server);
const port: u16 = 2424;

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

// Game Pak SRAM isn't included
// TODO: Can i be more specific here?
pub const memory_map: []const u8 =
    \\ <?xml version="1.0"?>
    \\ <!DOCTYPE memory-map
    \\     PUBLIC "+//IDN gnu.org//DTD GDB Memory Map V1.0//EN"
    \\         "http://sourceware.org/gdb/gdb-memory-map.dtd">
    \\
    \\ <memory-map>
    \\     <memory type="rom" start="0" length="4000">
    \\     <memory type="ram" start="2000000" length="40000">
    \\     <memory type="ram" start="3000000" length="8000">
    \\     <memory type="ram" start="4000000" length="400">
    \\     <memory type="ram" start="5000000" length="400">
    \\     <memory type="ram" start="6000000" length="18000">
    \\     <memory type="ram" start="7000000" length="400">
    \\     <memory type="rom" start="8000000" length="20000000">
    \\     <memory type="rom" start="A000000" length="20000000">
    \\     <memory type="rom" start="C000000" length="20000000">
    \\ </memory-map>;
;

// FIXME: Shouldn't this be a Packet Struct?
pkt_cache: ?[]const u8 = null,

client: Socket,
_socket: Socket,

emu: Emulator,

pub fn init(emulator: Emulator) !Self {
    try network.init();

    var socket = try Socket.create(.ipv4, .tcp);
    try socket.bindToPort(port);
    try socket.listen();

    var client = try socket.accept(); // TODO: This blocks, is this OK?

    const endpoint = try client.getLocalEndPoint();
    log.info("client connected from {}", .{endpoint});

    return .{ .emu = emulator, ._socket = socket, .client = client };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.reset(allocator);

    self.client.close();
    self._socket.close();
    network.deinit();

    self.* = undefined;
}

const Action = union(enum) {
    nothing,
    send: []const u8,
    retry,
    ack,
    nack,
};

pub fn run(self: *Self, allocator: Allocator) !void {
    var buf: [Packet.max_len]u8 = undefined;

    while (true) {
        const len = try self.client.receive(&buf);
        if (len == 0) break;

        const action = try self.parse(allocator, buf[0..len]);
        try self.send(allocator, action);
    }
}

fn parse(self: *Self, allocator: Allocator, input: []const u8) !Action {
    return switch (input[0]) {
        '+' => .nothing,
        '-' => .retry,
        '$' => blk: {
            // Packet
            var packet = Packet.from(allocator, input) catch return .nack;
            defer packet.deinit(allocator);

            var string = packet.parse(allocator, self.emu) catch return .nack;
            defer string.deinit(allocator);

            const reply = string.inner();

            // deallocated by the caller
            const response = try std.fmt.allocPrint(allocator, "${s}#{x:0>2}", .{ reply, Packet.checksum(reply) });

            break :blk .{ .send = response };
        },
        else => std.debug.panic("Unknown: {s}", .{input}),
    };
}

fn send(self: *Self, allocator: Allocator, action: Action) !void {
    switch (action) {
        .send => |pkt| {
            _ = try self.client.send("+"); // ACK
            _ = try self.client.send(pkt);

            self.reset(allocator);
            self.pkt_cache = pkt;
        },
        .retry => {
            log.warn("received nack, resending: \"{?s}\"", .{self.pkt_cache});

            if (self.pkt_cache) |pkt| _ = try self.client.send(pkt); // FIXME: is an ack to a nack necessary?
        },
        .ack => {
            _ = try self.client.send("+");
            self.reset(allocator);
        },
        .nack => {
            _ = try self.client.send("-");
            self.reset(allocator);
        },
        .nothing => self.reset(allocator),
    }
}

fn reset(self: *Self, allocator: Allocator) void {
    if (self.pkt_cache) |pkt| allocator.free(pkt);
    self.pkt_cache = null;
}
