const std = @import("std");
const network = @import("network");
const Packet = @import("Packet.zig");

const Socket = network.Socket;
const Allocator = std.mem.Allocator;
const Atomic = std.atomic.Atomic;
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
    \\ <memory-map version="1.0">
    \\     <memory type="rom" start="0x00000000" length="0x00004000"/>
    \\     <memory type="ram" start="0x02000000" length="0x00040000"/>
    \\     <memory type="ram" start="0x03000000" length="0x00008000"/>
    \\     <memory type="ram" start="0x04000000" length="0x00000400"/>
    \\     <memory type="ram" start="0x05000000" length="0x00000400"/>
    \\     <memory type="ram" start="0x06000000" length="0x00018000"/>
    \\     <memory type="ram" start="0x07000000" length="0x00000400"/>
    \\     <memory type="rom" start="0x08000000" length="0x02000000"/>
    \\     <memory type="rom" start="0x0A000000" length="0x02000000"/>
    \\     <memory type="rom" start="0x0C000000" length="0x02000000"/>
    \\ </memory-map>
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

pub fn run(self: *Self, allocator: Allocator, quit: *Atomic(bool)) !void {
    var buf: [Packet.max_len]u8 = undefined;

    while (true) {
        const len = try self.client.receive(&buf);
        if (len == 0) break;

        if (quit.load(.Monotonic)) break;
        const action = try self.parse(allocator, buf[0..len]);
        try self.send(allocator, action);
    }

    // Just in case its the gdbstub that exited first,
    // attempt to signal to the GUI that it should also exit
    quit.store(true, .Monotonic);
}

fn parse(self: *Self, allocator: Allocator, input: []const u8) !Action {
    // log.debug("-> {s}", .{input});

    return switch (input[0]) {
        '+' => blk: {
            if (input.len == 1) break :blk .nothing;

            break :blk switch (input[1]) {
                '$' => self.handlePacket(allocator, input[1..]),
                else => std.debug.panic("Unknown: {s}", .{input}),
            };
        },
        '-' => .retry,
        '$' => try self.handlePacket(allocator, input),
        '\x03' => .nothing,
        else => std.debug.panic("Unknown: {s}", .{input}),
    };
}

fn handlePacket(self: *Self, allocator: Allocator, input: []const u8) !Action {
    var packet = Packet.from(allocator, input) catch return .nack;
    defer packet.deinit(allocator);

    var string = packet.parse(allocator, &self.emu) catch return .nack;
    defer string.deinit(allocator);

    const reply = string.inner();

    // deallocated by the caller
    const response = try std.fmt.allocPrint(allocator, "+${s}#{x:0>2}", .{ reply, Packet.checksum(reply) });

    return .{ .send = response };
}

fn send(self: *Self, allocator: Allocator, action: Action) !void {
    switch (action) {
        .send => |pkt| {
            _ = try self.client.send(pkt);
            // log.debug("<- {s}", .{pkt});

            self.reset(allocator);
            self.pkt_cache = pkt;
        },
        .retry => {
            log.warn("received nack, resending: \"{?s}\"", .{self.pkt_cache});

            if (self.pkt_cache) |pkt| {
                _ = try self.client.send(pkt);
                // log.debug("<- {s}", .{pkt});
            }
        },
        .ack => {
            _ = try self.client.send("+");
            // log.debug("<- +", .{});

            self.reset(allocator);
        },
        .nack => {
            _ = try self.client.send("-");
            // log.debug("<- -", .{});

            self.reset(allocator);
        },
        .nothing => self.reset(allocator),
    }
}

fn reset(self: *Self, allocator: Allocator) void {
    if (self.pkt_cache) |pkt| allocator.free(pkt);
    self.pkt_cache = null;
}
