//! Integer-only firmware for the fixed-geometry counter. The build host paints
//! the widget tree into RGB565 spans. The MCU applies them to one scanline.
const std = @import("std");
const builtin = @import("builtin");
const demo = @import("demo.zig");
const assets = @import("panel_assets");
pub const panic = std.debug.no_panic;
const Area = @import("lcgf").shell_baremetal_flush.Area;
const all: Area = .{ .x0 = 0, .y0 = 0, .x1 = demo.width, .y1 = demo.height };
const button: Area = .{ .x0 = assets.button[0], .y0 = assets.button[1], .x1 = assets.button[0] + assets.button[2], .y1 = assets.button[1] + assets.button[3] };
const label: Area = .{ .x0 = 0, .y0 = 0, .x1 = demo.width, .y1 = button.y0 };
const Touch = struct { x: u16, y: u16, down: bool };

const touches: [demo.script.len]Touch = blk: {
    var samples: [demo.script.len]Touch = undefined;
    for (demo.script, &samples) |s, *t| t.* = .{ .x = @intFromFloat(s.touch.pos[0]), .y = @intFromFloat(s.touch.pos[1]), .down = s.touch.down };
    break :blk samples;
};

const Counter = struct {
    count: u32 = 0,
    face: u2 = 0,
    captured: bool = false,
    was_down: bool = false,
    inside: bool = false,

    fn touch(state: *Counter, sample: Touch) void {
        const inside = sample.x >= button.x0 and sample.x < button.x1 and sample.y >= button.y0 and sample.y < button.y1;
        if (sample.down and !state.was_down) state.captured = inside;
        const release = !sample.down and state.was_down;
        if (release and state.captured and state.inside) state.count +%= 1;
        state.face = if (sample.down and state.captured) 2 else @intFromBool((sample.down and inside) or (release and state.inside));
        state.was_down = sample.down;
        state.inside = inside;
    }

    fn draw(state: Counter, area: Area, board: anytype) void {
        var buf: [10]u8 = undefined;
        const digits = demo.decimal(&buf, "", state.count);
        var layers: [12][]const assets.Span = undefined;
        layers[0] = &assets.base;
        layers[1] = assets.faces[state.face];
        for (digits, 0..) |ch, i| layers[i + 2] = assets.digits[i][ch - '0'];
        const active = layers[0 .. 2 + digits.len];
        const line = &board.pixels;
        for (area.y0..area.y1) |y| {
            @memset(line[area.x0..area.x1], assets.background);
            for (active) |*layer| {
                while (layer.len != 0 and layer.*[0].y < y) layer.* = layer.*[1..];
                while (layer.len != 0 and layer.*[0].y == y) {
                    const s = layer.*[0];
                    @memset(line[s.x..][0..s.len], s.color);
                    layer.* = layer.*[1..];
                }
            }
            board.row(area.x0, @intCast(y), line[area.x0..area.x1]);
        }
    }
};

fn run(samples: []const Touch, board: anytype) Counter {
    var counter: Counter = .{};
    counter.draw(all, board);
    for (samples) |sample| {
        const last = counter;
        counter.touch(sample);
        if (counter.count != last.count) counter.draw(label, board);
        if (counter.face != last.face) counter.draw(button, board);
    }
    return counter;
}

const Bus = struct {
    pixels: [demo.width]u16 = undefined,
    sum: u32 = 0,

    fn row(b: *Bus, _: u32, _: u32, pixels: []const u16) void {
        for (pixels) |p| b.sum = b.sum *% 31 +% p;
    }
};

var result: u32 = 0;
var device: Bus = .{};

fn start() callconv(.c) noreturn {
    const counter = run(&touches, &device);
    const output: *volatile u32 = &result;
    output.* = device.sum ^ counter.count;
    while (true) {}
}

comptime {
    if (builtin.os.tag == .freestanding) @export(&start, .{ .name = "_start" });
}

test "integer demo reproduces host software-rendered pixels at each count and button state" {
    for (assets.checks) |check| {
        var bus: Bus = .{};
        const counter: Counter = .{ .count = check[0], .face = check[1] };
        counter.draw(all, &bus);
        try std.testing.expectEqual(check[2], bus.sum);
    }
    var bus: Bus = .{};
    try std.testing.expectEqual(3, run(&touches, &bus).count);
    const outside: Touch = .{ .x = 0, .y = 0, .down = true };
    try std.testing.expectEqual(0, run(&.{ outside, .{ .x = 20, .y = 40, .down = false } }, &bus).count);
}
