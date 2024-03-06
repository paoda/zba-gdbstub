const std = @import("std");
const Packet = @import("Packet.zig");
const Emulator = @import("lib.zig").Emulator;

const Allocator = std.mem.Allocator;
const Server = std.net.StreamServer;
const Connection = Server.Connection;

const Self = @This();
const log = std.log.scoped(.Server);
const port: u16 = 2424;

// FIXME: Shouldn't this be a Packet Struct?
pkt_cache: ?[]const u8 = null,

socket: Server,
state: State,

emu: Emulator,

pub const State = struct {
    should_quit: bool = false,
    target_xml: []const u8,
    memmap_xml: []const u8,
};

const Xml = struct { target: []const u8, memory_map: []const u8 };

pub fn init(emulator: Emulator, xml: Xml) !Self {
    var server = std.net.StreamServer.init(.{});
    try server.listen(std.net.Address.initIp4(.{ 127, 0, 0, 1 }, port));

    return .{
        .emu = emulator,
        .socket = server,
        .state = .{ .target_xml = xml.target, .memmap_xml = xml.memory_map },
    };
}

pub fn deinit(self: *Self, allocator: Allocator) void {
    self.reset(allocator);
    self.socket.deinit();

    self.* = undefined;
}

const Action = union(enum) {
    nothing,
    send: []const u8,
    retry,
    ack,
    nack,
};

pub fn run(self: *Self, allocator: Allocator, should_quit: *std.atomic.Value(bool)) !void {
    var buf: [Packet.max_len]u8 = undefined;

    var client = try self.socket.accept();
    log.info("client connected from {}", .{client.address});

    while (!should_quit.load(.Monotonic)) {
        if (self.state.should_quit) {
            // Just in case its the gdbstub that exited first,
            // attempt to signal to the GUI that it should also exit
            should_quit.store(true, .Monotonic);
            break;
        }

        const len = try client.stream.read(&buf);
        if (len == 0) break;

        const action = try self.parse(allocator, buf[0..len]);
        try self.send(allocator, client, action);
    }
}

fn parse(self: *Self, allocator: Allocator, input: []const u8) !Action {
    log.debug("-> {s}", .{input});

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

    var string = packet.parse(allocator, &self.state, &self.emu) catch return .nack;
    defer string.deinit(allocator);

    const reply = string.inner();

    // deallocated by the caller
    const response = try std.fmt.allocPrint(allocator, "+${s}#{x:0>2}", .{ reply, Packet.checksum(reply) });

    return .{ .send = response };
}

fn send(self: *Self, allocator: Allocator, client: Server.Connection, action: Action) !void {
    switch (action) {
        .send => |pkt| {
            _ = try client.stream.writeAll(pkt);
            log.debug("<- {s}", .{pkt});

            self.reset(allocator);
            self.pkt_cache = pkt;
        },
        .retry => {
            log.warn("received nack, resending: \"{?s}\"", .{self.pkt_cache});

            if (self.pkt_cache) |pkt| {
                _ = try client.stream.writeAll(pkt);
                log.debug("<- {s}", .{pkt});
            }
        },
        .ack => {
            _ = try client.stream.writeAll("+");
            log.debug("<- +", .{});

            self.reset(allocator);
        },
        .nack => {
            _ = try client.stream.writeAll("-");
            log.debug("<- -", .{});

            self.reset(allocator);
        },
        .nothing => self.reset(allocator),
    }
}

fn reset(self: *Self, allocator: Allocator) void {
    if (self.pkt_cache) |pkt| allocator.free(pkt);
    self.pkt_cache = null;
}
