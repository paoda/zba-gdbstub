const std = @import("std");
const network = @import("network");

const Allocator = std.mem.Allocator;
const Socket = network.Socket;

const port: u16 = 2424;

pub fn main() !void {
    const log = std.log.scoped(.Server);

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());

    const allocator = gpa.allocator();

    try network.init();
    defer network.deinit();

    var socket = try Socket.create(.ipv4, .tcp);
    defer socket.close();

    try socket.bindToPort(port);
    try socket.listen();

    var client = try socket.accept();
    defer client.close();

    const endpoint = try client.getLocalEndPoint();
    log.info("client connected from {}", .{endpoint});

    try gdbStubServer(allocator, client);

    log.info("Client disconnected", .{});
}

fn gdbStubServer(allocator: Allocator, client: Socket) !void {
    var buf: [Packet.size]u8 = undefined;
    var previous: ?[]const u8 = null;
    defer if (previous) |packet| allocator.free(packet);

    while (true) {
        const len = try client.receive(&buf);
        if (len == 0) break;

        switch (try parse(allocator, client, previous, buf[0..len])) {
            .send => |response| {
                if (previous) |packet| allocator.free(packet);
                previous = response;
            },
            .recognize_ack => {
                if (previous) |packet| allocator.free(packet);
                previous = null;
            },
            .retry => {},
        }
    }
}

const Action = union(enum) {
    send: []const u8,
    retry,
    recognize_ack,
};

fn parse(allocator: Allocator, client: Socket, previous: ?[]const u8, input: []const u8) !Action {
    const log = std.log.scoped(.GdbStubParser);

    return switch (input[0]) {
        '+' => .recognize_ack,
        '-' => blk: {
            if (previous) |packet| {
                log.warn("Received negative ack, resending: \"{s}\"", .{packet});
                _ = try client.send(packet);
            } else {
                log.err("Server sent negative ack, but gdbstub doesn't recall sending anything", .{});
            }

            break :blk .retry;
        },
        '$' => blk: {
            // Packet
            var packet = try Packet.from(allocator, input);
            defer packet.deinit(allocator);

            var string = try packet.parse(allocator);
            defer string.deinit(allocator);

            const reply = string.inner();

            _ = try client.send("+"); // Acknowledge

            // deallocated by the caller
            const response = try std.fmt.allocPrint(allocator, "${s}#{x:0>2}", .{ reply, Packet.checksum(reply) });
            _ = try client.send(response);

            break :blk .{ .send = response };
        },
        else => std.debug.panic("Unknown: {s}", .{input}),
    };
}

const Packet = struct {
    const Self = @This();
    const log = std.log.scoped(.Packet);
    const size: usize = 0x1000;

    contents: []const u8,

    pub fn from(allocator: Allocator, str: []const u8) !Self {
        var tokens = std.mem.tokenize(u8, str, "$#");
        const contents = tokens.next() orelse return error.InvalidPacket;

        const chksum_str = tokens.next() orelse return error.MissingCheckSum;
        const chksum = std.fmt.parseInt(u8, chksum_str, 16) catch return error.InvalidChecksum;

        // log.info("Contents: {s}", .{contents});

        if (!Self.verify(contents, chksum)) return error.ChecksumMismatch;

        return .{ .contents = try allocator.dupe(u8, contents) };
    }

    const String = union(enum) {
        alloc: []const u8,
        static: []const u8,

        pub fn inner(self: *const @This()) []const u8 {
            return switch (self.*) {
                .static => |str| str,
                .alloc => |str| str,
            };
        }

        pub fn deinit(self: *@This(), allocator: Allocator) void {
            switch (self.*) {
                .alloc => |string| allocator.free(string),
                .static => {},
            }

            self.* = undefined;
        }
    };

    pub fn parse(self: *Self, allocator: Allocator) !String {
        switch (self.contents[0]) {
            // Required
            '?' => {
                const ret: Signal = .Trap;

                // Deallocated by the caller
                return .{ .alloc = try std.fmt.allocPrint(allocator, "S {x:0>2}", .{@enumToInt(ret)}) };
            },
            'g', 'G' => @panic("TODO: Register Access"),
            'm', 'M' => @panic("TODO: Memory Access"),
            'c' => @panic("TODO: Continue"),
            's' => @panic("TODO: Step"),

            // Optional
            'H' => {
                log.warn("{s}", .{self.contents});

                switch (self.contents[1]) {
                    'g', 'c' => return .{ .static = "OK" },
                    else => {
                        log.warn("Unimplemented: {s}", .{self.contents});
                        return .{ .static = "" };
                    },
                }
            },
            'v' => {
                if (substr(self.contents[1..], "MustReplyEmpty")) {
                    return .{ .static = "" };
                }

                log.warn("Unimplemented: {s}", .{self.contents});
                return .{ .static = "" };
            },
            'q' => {
                if (substr(self.contents[1..], "Supported")) {
                    const ret = try std.fmt.allocPrint(allocator, "PacketSize={x:}", .{Packet.size});
                    // TODO: Should we support anything else?

                    return .{ .alloc = ret };
                } else if (substr(self.contents[1..], "Attached")) {
                    return .{ .static = "0" }; // We tell GDB that we've created a new process
                }

                log.warn("Unimplemented: {s}", .{self.contents});
                return .{ .static = "" };
            },
            else => {
                log.warn("Unknown:  {s}", .{self.contents});

                return .{ .static = "" };
            },
        }
    }

    fn substr(haystack: []const u8, needle: []const u8) bool {
        return std.mem.indexOf(u8, haystack, needle) != null;
    }

    fn deinit(self: *Self, allocator: Allocator) void {
        allocator.free(self.contents);
        self.* = undefined;
    }

    pub fn checksum(input: []const u8) u8 {
        var sum: usize = 0;
        for (input) |char| sum += char;

        return @truncate(u8, sum);
    }

    fn verify(input: []const u8, chksum: u8) bool {
        return Self.checksum(input) == chksum;
    }
};

const Signal = enum(u32) {
    Hup, // Hangup
    Int, // Interrupt
    Quit, // Quit
    Ill, // Illegal Instruction
    Trap, // Trace/Breakponit trap
    Abrt, // Aborted
};
