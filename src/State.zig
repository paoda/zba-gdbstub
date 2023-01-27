const std = @import("std");

hw_bkpt: HwBkpt = .{},

const HwBkpt = struct {
    const log = std.log.scoped(.HwBkpt);

    list: [2]?Bkpt = .{ null, null },

    pub fn isHit(self: *const @This(), addr: u32) bool {
        for (self.list) |bkpt_opt| {
            if (bkpt_opt == null) continue;
            const bkpt = bkpt_opt.?;

            if (bkpt.addr == addr) return true;
        }

        return false;
    }

    pub fn add(self: *@This(), addr: u32, kind: u32) !void {
        for (self.list) |*bkpt_opt| {
            if (bkpt_opt.* != null) {
                const bkpt = bkpt_opt.*.?;
                if (bkpt.addr == addr) return; // makes this fn indempotent

                continue;
            }

            bkpt_opt.* = .{ .addr = addr, .kind = try Bkpt.Kind.from(u32, kind) };
            log.debug("Added Breakpoint at 0x{X:0>8}", .{addr});

            return;
        }

        return error.OutOfSpace;
    }

    pub fn remove(self: *@This(), addr: u32) void {
        for (self.list) |*bkpt_opt| {
            if (bkpt_opt.* == null) continue;
            const bkpt = bkpt_opt.*.?; // FIXME: bkpt_opt.?.addr works though?

            log.debug("Removed Breakpoint at 0x{X:0>8}", .{addr});
            if (bkpt.addr == addr) bkpt_opt.* = null;
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
            comptime std.debug.assert(@typeInfo(T) == .Int);

            return switch (num) {
                2 => .Arm,
                4 => .Thumb,
                else => error.UnknownBkptKind,
            };
        }
    };
};
