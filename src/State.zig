const std = @import("std");
const Allocator = std.mem.Allocator;

hw_bkpt: HwBkpt = .{},
sw_bkpt: SwBkpt = .{},

pub fn deinit(self: *@This(), allocator: Allocator) void {
    self.sw_bkpt.deinit(allocator);
    self.* = undefined;
}

const SwBkpt = struct {
    const log = std.log.scoped(.SwBkpt);

    list: std.ArrayList(Bkpt) = .empty,

    pub fn deinit(self: *@This(), allocator: Allocator) void {
        self.list.deinit(allocator);
        self.* = undefined;
    }

    pub fn isHit(self: *const @This(), addr: u32) bool {
        for (self.list.items) |bkpt| {
            if (bkpt.addr == addr) return true;
        }

        return false;
    }

    pub fn add(self: *@This(), allocator: Allocator, addr: u32, kind: u32) !void {
        for (self.list.items) |bkpt| {
            if (bkpt.addr == addr) return; // indempotent
        }

        try self.list.append(allocator, .{ .addr = addr, .kind = try Bkpt.Kind.from(u32, kind) });
        log.warn("Added Breakpoint at 0x{X:0>8}", .{addr});
    }

    pub fn remove(self: *@This(), addr: u32) void {
        for (self.list.items, 0..) |bkpt, i| {
            if (bkpt.addr == addr) {
                _ = self.list.orderedRemove(i);
                log.debug("Removed Breakpoint at 0x{X:0>8}", .{addr});

                return;
            }
        }
    }
};

const HwBkpt = struct {
    const log = std.log.scoped(.HwBkpt);

    list: [2]?Bkpt = .{ null, null },

    pub fn isHit(self: *const @This(), addr: u32) bool {
        for (self.list) |bkpt_opt| {
            const bkpt = bkpt_opt orelse continue;
            if (bkpt.addr == addr) return true;
        }

        return false;
    }

    pub fn add(self: *@This(), addr: u32, kind: u32) !void {
        for (&self.list) |*bkpt_opt| {
            if (bkpt_opt.*) |bkpt| {
                if (bkpt.addr == addr) return; // idempotent
            } else {
                bkpt_opt.* = .{ .addr = addr, .kind = try Bkpt.Kind.from(u32, kind) };
                log.debug("Added Breakpoint at 0x{X:0>8}", .{addr});

                return;
            }
        }

        return error.OutOfSpace;
    }

    pub fn remove(self: *@This(), addr: u32) void {
        for (&self.list) |*bkpt_opt| {
            const bkpt = bkpt_opt.* orelse continue;

            if (bkpt.addr == addr) {
                bkpt_opt.* = null;
                log.debug("Removed Breakpoint at 0x{X:0>8}", .{addr});

                break;
            }
        }
    }
};

const Bkpt = struct {
    addr: u32,
    kind: Kind,

    const Kind = enum(u3) {
        Arm = 2,
        Thumb = 4,

        pub fn from(comptime T: type, num: T) !@This() {
            comptime std.debug.assert(@typeInfo(T) == .int);

            return switch (num) {
                2 => .Arm,
                4 => .Thumb,
                else => error.UnknownBkptKind,
            };
        }
    };
};
