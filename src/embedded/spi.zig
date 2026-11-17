//! Synchronous 4-wire SPI for panels using the MIPI DCS column/page/memory
//! write commands. The board owns chip select, the D/C pin and the transport.
const std = @import("std");
const fb = @import("framebuffer.zig");
const sw = @import("../render/sw/sw.zig");
const Area = @import("../shell/baremetal/flush.zig").Area;

/// Bus.select(active), Bus.dataMode(is_data) and fallible Bus.write(bytes).
/// One transaction covers the window and all of its pixel chunks. A transfer
/// failure releases chip select; retrying starts with a fresh address window.
pub fn Display(comptime Bus: type) type {
    return struct {
        bus: *Bus,
        scratch: []u8,

        fn command(d: @This(), value: u8) !void {
            d.bus.dataMode(false);
            try d.bus.write(&.{value});
            d.bus.dataMode(true);
        }

        fn window(d: @This(), cmd: u8, start: u32, end: u32) !void {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u16, bytes[0..2], @intCast(start), .big);
            std.mem.writeInt(u16, bytes[2..4], @intCast(end - 1), .big);
            try d.command(cmd);
            try d.bus.write(&bytes);
        }

        pub fn write(d: @This(), a: Area, pixels: []const u32, stride: u32, order: sw.Format) !void {
            if (a.x0 > a.x1 or a.y0 > a.y1 or a.x1 > 65536 or a.y1 > 65536) return error.InvalidArea;
            if (a.w() == 0 or a.h() == 0) return;
            if (stride < a.w() or @as(u64, a.h() - 1) * stride + a.w() > pixels.len) return error.InvalidSource;
            const capacity = d.scratch.len / 2;
            if (capacity == 0) return error.NoScratch;
            d.bus.select(true);
            defer d.bus.select(false);
            try d.window(0x2a, a.x0, a.x1);
            try d.window(0x2b, a.y0, a.y1);
            try d.command(0x2c);
            for (0..a.h()) |y| {
                var row = pixels[y * stride ..][0..a.w()];
                while (row.len != 0) {
                    const n = @min(row.len, capacity);
                    for (row[0..n], 0..) |raw, i| {
                        const pixel = fb.pack565(fb.color(raw, order));
                        std.mem.writeInt(u16, d.scratch[i * 2 ..][0..2], pixel, .big);
                    }
                    try d.bus.write(d.scratch[0 .. n * 2]);
                    row = row[n..];
                }
            }
        }
    };
}

test "embedded SPI windows, RGB565 chunks, stride, and release after failure" {
    const Bus = struct {
        selected: bool = false,
        data: bool = true,
        fail: bool = false,
        bytes: [32]u8 = undefined,
        len: usize = 0,

        pub fn select(b: *@This(), active: bool) void {
            std.debug.assert(b.selected != active);
            b.selected = active;
        }
        pub fn dataMode(b: *@This(), data: bool) void {
            b.data = data;
        }
        pub fn write(b: *@This(), bytes: []const u8) !void {
            try std.testing.expect(b.selected);
            if (b.fail) return error.TransferFailed;
            if (!b.data) try std.testing.expect(bytes.len == 1 and (bytes[0] == 0x2a or bytes[0] == 0x2b or bytes[0] == 0x2c));
            @memcpy(b.bytes[b.len..][0..bytes.len], bytes);
            b.len += bytes.len;
        }
    };
    var bus: Bus = .{};
    var scratch: [3]u8 = undefined; // one pixel in each data write
    const display: Display(Bus) = .{ .bus = &bus, .scratch = &scratch };
    const area: Area = .{ .x0 = 255, .y0 = 511, .x1 = 257, .y1 = 513 };
    const src = [_]u32{ 0xff0000ff, 0xff00ff00, 0, 0xffff0000, 0xffffffff };
    try display.write(area, &src, 3, .rgba8);
    try std.testing.expectEqualSlices(u8, &.{ 0x2a, 0, 255, 1, 0, 0x2b, 1, 255, 2, 0, 0x2c, 0xf8, 0, 7, 0xe0, 0, 0x1f, 255, 255 }, bus.bytes[0..bus.len]);
    try std.testing.expect(!bus.selected);
    bus.fail = true;
    try std.testing.expectError(error.TransferFailed, display.write(area, &src, 3, .rgba8));
    try std.testing.expect(!bus.selected);
    try std.testing.expectError(error.InvalidSource, display.write(area, &src, 1, .rgba8));
    try display.write(.{ .x0 = 1, .y0 = 1, .x1 = 1, .y1 = 2 }, &.{}, 0, .rgba8);
}
