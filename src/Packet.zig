const std = @import("std");

const Allocator = std.mem.Allocator;
const Emulator = @import("lib.zig").Emulator;

const target = @import("Server.zig").target;
const memory_map = @import("Server.zig").memory_map;

const Self = @This();
const log = std.log.scoped(.Packet);
pub const max_len: usize = 0x1000;

contents: []const u8,

pub fn from(allocator: Allocator, str: []const u8) !Self {
    var tokens = std.mem.tokenize(u8, str, "$#");
    const contents = tokens.next() orelse return error.InvalidPacket;

    const chksum_str = tokens.next() orelse return error.MissingCheckSum;
    const chksum = std.fmt.parseInt(u8, chksum_str, 16) catch return error.InvalidChecksum;

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

pub fn parse(self: *Self, allocator: Allocator, emu: Emulator) !String {
    switch (self.contents[0]) {
        // Required
        '?' => {
            const ret = try std.fmt.allocPrint(allocator, "S{x:0>2}", .{@enumToInt(Signal.Int)});
            return .{ .alloc = ret };
        },
        'g' => {
            const r = emu.registers();
            const cpsr = emu.cpsr();

            const reg_len = @sizeOf(u32) * 2; // Every byte is represented by 2 characters
            const ret = try allocator.alloc(u8, r.len * reg_len + reg_len); // r0 -> r15 + CPSR

            {
                var i: u32 = 0;
                while (i < r.len + 1) : (i += 1) {
                    var reg: u32 = if (i < r.len) r[i] else cpsr;
                    if (i == 15) reg -= if (cpsr >> 5 & 1 == 1) 4 else 8; // PC is ahead

                    // writes the formatted integer to the buffer, returns a slice to the buffer but we ignore that
                    // GDB also expects the bytes to be in the opposite order for whatever reason
                    _ = std.fmt.bufPrintIntToSlice(ret[i * 8 ..][0..8], @byteSwap(reg), 16, .lower, .{ .fill = '0', .width = 8 });
                }
            }

            return .{ .alloc = ret };
        },
        'G' => @panic("TODO: Register Write"),
        'm' => {
            var tokens = std.mem.tokenize(u8, self.contents[1..], ",");
            const addr_str = tokens.next() orelse return .{ .static = "E9999" }; // EUNKNOWN
            const length_str = tokens.next() orelse return .{ .static = "E9999" }; // EUNKNOWN

            const addr = try std.fmt.parseInt(u32, addr_str, 16);
            const len = try std.fmt.parseInt(u32, length_str, 16);

            const ret = try allocator.alloc(u8, len * 2);

            {
                var i: u32 = 0;
                while (i < len) : (i += 1) {
                    // writes the formatted integer to the buffer, returns a slice to the buffer but we ignore that
                    _ = std.fmt.bufPrintIntToSlice(ret[i * 2 ..][0..2], emu.read(addr + i), 16, .lower, .{ .fill = '0', .width = 2 });
                }
            }

            return .{ .alloc = ret };
        },
        'M' => @panic("TODO: Memory Write"),
        'c' => @panic("TODO: Continue"),
        's' => {
            // var tokens = std.mem.tokenize(u8, self.contents[1..], " ");
            // const addr = if (tokens.next()) |s| try std.fmt.parseInt(u32, s, 16) else null;

            emu.step();

            const ret = try std.fmt.allocPrint(allocator, "S{x:0>2}", .{@enumToInt(Signal.Trap)});
            return .{ .alloc = ret };
        },

        // Optional
        'D' => {
            log.info("Disconnecting...", .{});
            return .{ .static = "OK" };
        },
        'H' => return .{ .static = "" },
        'v' => {
            if (substr(self.contents[1..], "MustReplyEmpty")) {
                return .{ .static = "" };
            }

            log.warn("Unimplemented: {s}", .{self.contents});
            return .{ .static = "" };
        },
        'q' => {
            if (self.contents[1] == 'C' and self.contents.len == 2) return .{ .static = "QC1" };
            if (substr(self.contents[1..], "fThreadInfo")) return .{ .static = "m1" };
            if (substr(self.contents[1..], "sThreadInfo")) return .{ .static = "l" };
            if (substr(self.contents[1..], "Attached")) return .{ .static = "1" }; // Tell GDB we're attached to a process

            if (substr(self.contents[1..], "Supported")) {
                const format = "PacketSize={x:};qXfer:features:read+;qXfer:memory-map:read+";
                // TODO: Anything else?

                const ret = try std.fmt.allocPrint(allocator, format, .{Self.max_len});
                return .{ .alloc = ret };
            }

            if (substr(self.contents[1..], "Xfer:features:read")) {
                var tokens = std.mem.tokenize(u8, self.contents[1..], ":,");
                _ = tokens.next(); // Xfer
                _ = tokens.next(); // features
                _ = tokens.next(); // read
                const annex = tokens.next() orelse return .{ .static = "E9999" };
                const offset_str = tokens.next() orelse return .{ .static = "E99999" };
                const length_str = tokens.next() orelse return .{ .static = "E9999" };

                if (std.mem.eql(u8, annex, "target.xml")) {
                    const offset = try std.fmt.parseInt(usize, offset_str, 16);
                    const length = try std.fmt.parseInt(usize, length_str, 16);

                    // + 2 to account for the "m " in the response
                    // subtract offset so that the allocated buffer isn't
                    // larger than it needs to be TODO: Test this?
                    const len = @min(length, (target.len + 1) - offset);
                    const ret = try allocator.alloc(u8, len);

                    ret[0] = if (ret.len < length) 'l' else 'm';
                    std.mem.copy(u8, ret[1..], target[offset..]);

                    return .{ .alloc = ret };
                } else {
                    log.err("Unexpected Annex: {s}", .{annex});
                    return .{ .static = "E9999" };
                }

                return .{ .static = "" };
            }

            if (substr(self.contents[1..], "Xfer:memory-map:read")) {
                var tokens = std.mem.tokenize(u8, self.contents[1..], ":,");
                _ = tokens.next(); // Xfer
                _ = tokens.next(); // memory-map
                _ = tokens.next(); // read
                const offset_str = tokens.next() orelse return .{ .static = "E9999" };
                const length_str = tokens.next() orelse return .{ .static = "E9999" };

                const offset = try std.fmt.parseInt(usize, offset_str, 16);
                const length = try std.fmt.parseInt(usize, length_str, 16);

                // see above
                const len = @min(length, (memory_map.len + 1) - offset);
                const ret = try allocator.alloc(u8, len);

                ret[0] = if (ret.len < length) 'l' else 'm';
                std.mem.copy(u8, ret[1..], memory_map[offset..]);

                return .{ .alloc = ret };
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

pub fn deinit(self: *Self, allocator: Allocator) void {
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

const Signal = enum(u32) {
    Hup = 1, // Hangup
    Int, // Interrupt
    Quit, // Quit
    Ill, // Illegal Instruction
    Trap, // Trace/Breakponit trap
    Abrt, // Aborted
};
