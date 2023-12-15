const std = @import("std");
const builtin = @import("builtin");

const Emulator = @import("lib.zig").Emulator;
const Server = @import("Server.zig");

const Allocator = std.mem.Allocator;

const BarebonesEmulator = struct {
    r: [16]u32 = [_]u32{0} ** 16,

    pub fn interface(self: *@This(), allocator: Allocator) Emulator {
        return Emulator.init(allocator, self);
    }

    pub fn read(_: *const @This(), _: u32) u8 {
        return 0;
    }

    pub fn write(_: *@This(), _: u32, _: u8) void {}

    pub fn registers(self: *@This()) *[16]u32 {
        return &self.r;
    }

    pub fn cpsr(_: *const @This()) u32 {
        return 0;
    }

    pub fn step(_: *@This()) void {
        // execute 1 instruction
    }
};

test Server {
    // https://github.com/ziglang/zig/blob/225fe6ddbfae016395762850e0cd5c51f9e7751c/lib/std/net/test.zig#L146C1-L156
    if (builtin.single_threaded) return error.SkipZigTest;
    if (builtin.os.tag == .wasi) return error.SkipZigTest;

    if (builtin.os.tag == .windows)
        _ = try std.os.windows.WSAStartup(2, 2);

    defer if (builtin.os.tag == .windows) std.os.windows.WSACleanup() catch unreachable;

    const allocator = std.testing.allocator;

    var impl = BarebonesEmulator{};
    var iface = impl.interface(allocator);
    defer iface.deinit();

    const clientFn = struct {
        fn inner(address: std.net.Address) !void {
            const socket = try std.net.tcpConnectToAddress(address);
            defer socket.close();

            _ = try socket.writer().writeAll("+");
        }
    }.inner;

    var server = try Server.init(iface);
    defer server.deinit(allocator);

    const t = try std.Thread.spawn(.{}, clientFn, .{server.server.listen_address});
    defer t.join();

    var should_quit = std.atomic.Atomic(bool).init(false);

    try server.run(std.testing.allocator, &should_quit);
}

test Emulator {
    const ExampleImpl = struct {
        r: [16]u32 = [_]u32{0} ** 16,

        pub fn interface(self: *@This(), allocator: std.mem.Allocator) Emulator {
            return Emulator.init(allocator, self);
        }

        pub fn read(_: *const @This(), _: u32) u8 {
            return 0;
        }

        pub fn write(_: *@This(), _: u32, _: u8) void {}

        pub fn registers(self: *@This()) *[16]u32 {
            return &self.r;
        }

        pub fn cpsr(_: *const @This()) u32 {
            return 0;
        }

        pub fn step(_: *@This()) void {
            // execute 1 instruction
        }
    };

    var impl = ExampleImpl{};
    var emu = Emulator.init(std.testing.allocator, &impl);

    _ = emu.read(0x0000_0000);
    emu.write(0x0000_0000, 0x00);

    _ = emu.registers();
    _ = emu.cpsr();

    _ = emu.step();
}
