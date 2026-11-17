//! Run with `zig build embedded-sim`. The simulator replays touch input into
//! the real board loop and decodes the SPI bytes into a memory-backed panel.
const std = @import("std");
const lcgf = @import("lcgf");
const demo = @import("demo.zig");
const Sim = lcgf.shell_baremetal_sim.Sim;
const Input = lcgf.input.Input;
const Area = lcgf.shell_baremetal_flush.Area;
const sw = lcgf.render_sw;
const fb = lcgf.embedded_framebuffer;

const Controller = struct {
    panel: sw.Framebuffer,
    active: bool = false,
    data: bool = false,
    command: u8 = 0,
    x0: u32 = 0,
    x1: u32 = 0,
    y0: u32 = 0,
    y1: u32 = 0,
    x: u32 = 0,
    y: u32 = 0,
    sent: u32 = 0,

    pub fn select(c: *Controller, active: bool) void {
        std.debug.assert(active != c.active);
        if (!active) std.debug.assert(c.command == 0x2c and c.y == c.y1);
        c.active = active;
    }
    pub fn dataMode(c: *Controller, data: bool) void {
        c.data = data;
    }
    pub fn write(c: *Controller, bytes: []const u8) !void {
        if (!c.active) return error.ChipNotSelected;
        if (!c.data) {
            if (bytes.len != 1) return error.BadCommand;
            c.command = bytes[0];
            if (c.command == 0x2c) {
                c.x = c.x0;
                c.y = c.y0;
            }
            return;
        }
        switch (c.command) {
            0x2a, 0x2b => {
                if (bytes.len != 4) return error.BadWindow;
                const start = std.mem.readInt(u16, bytes[0..2], .big);
                const end = @as(u32, std.mem.readInt(u16, bytes[2..4], .big)) + 1;
                if (end <= start) return error.BadWindow;
                if (c.command == 0x2a) {
                    if (end > c.panel.width) return error.BadWindow;
                    c.x0 = start;
                    c.x1 = end;
                } else {
                    if (end > c.panel.height) return error.BadWindow;
                    c.y0 = start;
                    c.y1 = end;
                }
            },
            0x2c => {
                if (bytes.len % 2 != 0) return error.BadPixels;
                for (0..bytes.len / 2) |k| {
                    if (c.y >= c.y1) return error.BadPixels;
                    const pixel = std.mem.readInt(u16, bytes[k * 2 ..][0..2], .big);
                    c.panel.pixels[c.y * c.panel.stride + c.x] = fb.unpack565(pixel).bitsOf();
                    c.sent += 1;
                    c.x += 1;
                    if (c.x == c.x1) {
                        c.x = c.x0;
                        c.y += 1;
                    }
                }
            },
            else => return error.BadCommand,
        }
    }
};

const Board = struct {
    pub const Font = demo.Board.Font;
    sim: Sim,
    controller: Controller,
    font_pixels: Font.Pixels = undefined,
    wire: [64]u8 = undefined,

    pub fn read(b: *Board) ?lcgf.shell_baremetal_input.Sample {
        return b.sim.read();
    }
    pub fn idle(b: *Board) bool {
        return b.sim.idle();
    }
    pub fn flush(b: *Board, a: Area, pixels: []const u32, stride: u32) void {
        const display: lcgf.embedded_spi.Display(Controller) = .{ .bus = &b.controller, .scratch = &b.wire };
        display.write(a, pixels, stride, .rgba8) catch unreachable;
    }
};

var panel_pixels: [sw.Framebuffer.len(demo.width, demo.height)]u32 = undefined;

fn replay() !struct { count: u32, sent: u32 } {
    var events: [8]Input.Event = undefined;
    var contacts: [2]Input.Contact = undefined;
    var text: [32]u8 = undefined;
    const panel: sw.Framebuffer = .init(&panel_pixels, demo.width, demo.height, .rgba8);
    var board: Board = .{
        .sim = .init(@embedFile("counter.replay"), .{ .text = &text, .events = &events, .contacts = &contacts }, panel),
        .controller = .{ .panel = panel },
    };
    var app: demo.App = .{};
    if (!demo.runBoard(&board, &board.sim.clock, &app)) return error.NoContext;
    if (board.sim.err) |err| return err;
    return .{ .count = app.count, .sent = board.controller.sent };
}

pub fn main() !void {
    const result = try replay();
    std.debug.print("Count {d}, {d} RGB565 pixels transferred over SPI\n", .{ result.count, result.sent });
}

test "simulated SPI panel receives exactly the reference counter frame after three taps" {
    const result = try replay();
    try std.testing.expectEqual(3, result.count);
    try std.testing.expect(result.sent > demo.width * demo.height and result.sent < 2 * demo.width * demo.height);
    const reference = @import("bake.zig");
    _ = try reference.render("Count 3", 0);
    for (reference.current, panel_pixels) |expected, shown| try std.testing.expectEqual(expected, fb.pack565(@bitCast(shown)));
}
