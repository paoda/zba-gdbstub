/// Re-export of the server interface
pub const Server = @import("Server.zig");
const State = @import("State.zig");

/// Interface for interacting between GDB and a GBA emu
pub const Emulator = struct {
    const Self = @This();

    const Signal = union(enum) {
        const Kind = enum { HwBkpt, SwBkpt };

        Trap: Kind,
        SingleStep: void,
    };

    state: State = .{},

    ptr: *anyopaque,

    readFn: *const fn (*anyopaque, u32) u8,
    writeFn: *const fn (*anyopaque, u32, u8) void,

    registersFn: *const fn (*anyopaque) *[16]u32,
    cpsrFn: *const fn (*anyopaque) u32,

    stepFn: *const fn (*anyopaque) void,

    pub fn init(ptr: anytype) Self {
        const Ptr = @TypeOf(ptr);
        const ptr_info = @typeInfo(Ptr);

        if (ptr_info != .Pointer) @compileError("ptr must be a pointer");
        if (ptr_info.Pointer.size != .One) @compileError("ptr must be a single-item pointer");

        const alignment = ptr_info.Pointer.alignment;

        const gen = struct {
            pub fn readImpl(pointer: *anyopaque, addr: u32) u8 {
                const self = @ptrCast(Ptr, @alignCast(alignment, pointer));

                return @call(.always_inline, ptr_info.Pointer.child.read, .{ self, addr });
            }

            pub fn writeImpl(pointer: *anyopaque, addr: u32, value: u8) void {
                const self = @ptrCast(Ptr, @alignCast(alignment, pointer));

                return @call(.always_inline, ptr_info.Pointer.child.write, .{ self, addr, value });
            }

            pub fn registersImpl(pointer: *anyopaque) *[16]u32 {
                const self = @ptrCast(Ptr, @alignCast(alignment, pointer));

                return @call(.always_inline, ptr_info.Pointer.child.registers, .{self});
            }

            pub fn cpsrImpl(pointer: *anyopaque) u32 {
                const self = @ptrCast(Ptr, @alignCast(alignment, pointer));

                return @call(.always_inline, ptr_info.Pointer.child.cpsr, .{self});
            }

            pub fn stepImpl(pointer: *anyopaque) void {
                const self = @ptrCast(Ptr, @alignCast(alignment, pointer));

                return @call(.always_inline, ptr_info.Pointer.child.step, .{self});
            }
        };

        return .{ .ptr = ptr, .readFn = gen.readImpl, .writeFn = gen.writeImpl, .registersFn = gen.registersImpl, .cpsrFn = gen.cpsrImpl, .stepFn = gen.stepImpl };
    }

    pub inline fn read(self: Self, addr: u32) u8 {
        return self.readFn(self.ptr, addr);
    }

    pub inline fn write(self: Self, addr: u32, value: u8) void {
        self.writeFn(self.ptr, addr, value);
    }

    pub inline fn registers(self: Self) *[16]u32 {
        return self.registersFn(self.ptr);
    }

    pub inline fn cpsr(self: Self) u32 {
        return self.cpsrFn(self.ptr);
    }

    pub inline fn contd(self: *Self) Signal {
        while (true) {
            const signal = self.step();

            switch (signal) {
                .SingleStep => {},
                .Trap => return signal,
            }
        }
    }

    pub inline fn step(self: *Self) Signal {
        self.stepFn(self.ptr);

        const r = self.registersFn(self.ptr);
        const is_thumb = self.cpsrFn(self.ptr) >> 5 & 1 == 1;

        const r15 = r[15] -| if (is_thumb) @as(u32, 4) else 8;

        if (self.state.hw_bkpt.isHit(r15)) return .{ .Trap = .HwBkpt };

        return .SingleStep;
    }
};
