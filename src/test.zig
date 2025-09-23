const std = @import("std");
const builtin = @import("builtin");

const Emulator = @import("lib.zig").Emulator;
const Server = @import("Server.zig");

const Allocator = std.mem.Allocator;

const BarebonesEmulator = struct {

    // I have this ARMv4T and GBA memory map xml lying around so we'll reuse it here
    const target: []const u8 =
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

    const memory_map: []const u8 =
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

    r: [16]u32 = [_]u32{0} ** 16,

    pub fn interface(self: *@This()) Emulator {
        return Emulator.init(self);
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
    var iface = impl.interface();
    defer iface.deinit(allocator);

    const clientFn = struct {
        fn inner(address: std.net.Address) !void {
            const socket = try std.net.tcpConnectToAddress(address);
            defer socket.close();

            var buf: [1024]u8 = undefined;

            var writer = socket.writer(&buf).interface;

            _ = try writer.writeAll("+");
        }
    }.inner;

    var server = try Server.init(
        iface,
        .{ .target = BarebonesEmulator.target, .memory_map = BarebonesEmulator.memory_map },
    );
    defer server.deinit(allocator);

    const t = try std.Thread.spawn(.{}, clientFn, .{server.socket.listen_address});
    defer t.join();

    var should_quit = std.atomic.Value(bool).init(false);

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
    var emu = Emulator.init(&impl);

    _ = emu.read(0x0000_0000);
    emu.write(0x0000_0000, 0x00);

    _ = emu.registers();
    _ = emu.cpsr();

    _ = emu.step();
}
