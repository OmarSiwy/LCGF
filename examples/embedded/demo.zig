//! The embedded profile's demo: a label and a button on a 320 x 240 panel, the smallest UI the
//! footprint gate measures (docs/GATES.md, "Embedded footprint": within LVGL's documented minimum
//! flash class, 64 kB; LVGL 9.5 "Requirements").
//!
//! Built freestanding for a Cortex-M7 and an RV32IMAC (`zig build embedded`) without the
//! standard library's I/O: the root `panic` traps instead of printing (std's default panic
//! writes to stderr through `std.Io`), and nothing else reaches std beyond what tier 0 uses.
//! `_start` runs the scripted taps and then idles. Its own module root over `lcgr`, so it is not
//! exported from src/lcgr.zig.
//!
//! It runs on the bare-metal shell with the software back end compiled for the one feature kind
//! its UI uses (`kinds`, `sw.SoftwareOf`): the other shading loops, and the gradients' `sin` and
//! `cos`, are left out of the image.

const std = @import("std");
const builtin = @import("builtin");
const lcgr = @import("lcgr");
const w = lcgr.widgets_base;
const context = lcgr.context;
const Frame = lcgr.frame.Frame;
const Quad = lcgr.draw_list.Quad;
const Id = lcgr.types.Id;
const Events = lcgr.shell_iface.Events;
const input = lcgr.shell_baremetal_input;
const tick = lcgr.shell_baremetal_tick;
const flushing = lcgr.shell_baremetal_flush;
/// The feature kinds the UI draws: a label and a button are solid quads.
pub const kinds: []const lcgr.features.Kind = &.{.solid};
const Shell = lcgr.shell_baremetal_shell.BaremetalOf(Board, kinds);

/// No stderr, no stack trace, no `std.Io`: a panic is a trap, which a debugger catches.
pub const panic = std.debug.no_panic;

pub const width = 320;
pub const height = 240;
pub const rows = 8;
pub const limits: context.Limits = .{ .nodes = 8, .texts = 4, .customs = 1, .strings = 64, .anims = 1, .tweens = 1, .flips = 1, .signals = 1, .depth = 4, .timers = 1, .memos = 1 };

pub const id_add = Id.from("add");

pub const App = struct {
    theme: w.Theme = .default,
    count: u32 = 0,

    pub fn build(app: *App, f: *Frame, _: *const Events) void {
        const th = &app.theme;
        _ = f.open(.from("panel"), .{ .size = .{ .fill, .fill }, .pad = @splat(8), .gap = 8, .fill = th.panel });
        var buf: [16]u8 = undefined;
        _ = w.label(f, th, decimal(&buf, "Count ", app.count));
        if (w.button(f, th, id_add, "Add").clicked) app.count += 1;
        f.close();
    }
};

/// `prefix` followed by `n` in decimal, in `buf`.
fn decimal(buf: []u8, comptime prefix: []const u8, n: u32) []const u8 {
    @memcpy(buf[0..prefix.len], prefix);
    var digits: [10]u8 = undefined;
    var k: usize = digits.len;
    var v = n;
    while (true) {
        k -= 1;
        digits[k] = '0' + @as(u8, @intCast(v % 10));
        v /= 10;
        if (v == 0) break;
    }
    const len = digits.len - k;
    @memcpy(buf[prefix.len..][0..len], digits[k..]);
    return buf[0 .. prefix.len + len];
}

/// Three taps on the button (at its place in the layout at 320 x 240), each a press and a release.
const tap: input.Touch = .{ .pos = .{ 20, 40 }, .down = true };
const script = [_]input.Sample{ .{}, .{}, .{ .touch = tap }, .{ .touch = .{ .pos = tap.pos } }, .{ .touch = tap }, .{ .touch = .{ .pos = tap.pos } }, .{ .touch = tap }, .{ .touch = .{ .pos = tap.pos } }, .{} };

/// The board: scripted touches, 16 ms apart; `flush` folds every pixel into `sum` where a real
/// board would send it to the panel.
pub const Board = struct {
    clock: tick.Tick = .{},
    at: usize = 0,
    sum: u32 = 0,
    sent: u32 = 0,

    pub fn read(b: *Board) ?input.Sample {
        if (b.at == script.len) return null;
        b.clock.inc(16);
        b.at += 1;
        return script[b.at - 1];
    }
    pub fn flush(b: *Board, a: flushing.Area, pixels: []const u32, stride: u32) void {
        for (0..a.h()) |y| for (pixels[y * stride ..][0..a.w()]) |p| {
            b.sum = (b.sum *% 31) +% p;
        };
        b.sent += a.w() * a.h();
    }
    pub fn idle(_: *Board) bool {
        return true;
    }
};

// Static RAM, all of it.
var ctx_buffer: [context.Context.requiredBytes(limits)]u8 align(lcgr.mem.column_align) = undefined;
var lines: [flushing.Display.len(width, rows)]u32 = undefined;
var glyphs: [32]Quad = undefined;
var first: [limits.texts]u32 = undefined;
var count: [limits.texts]u32 = undefined;

pub var board: Board = .{};
pub var state: App = .{};

/// Runs the script to its end. False when the context does not fit its buffer.
pub fn run() bool {
    var ctx = context.Context.init(&ctx_buffer, limits) catch return false;
    state = .{};
    board = .{};
    var shell: Shell = .init(&board, &board.clock, width, height, rows, .rgba8, 1, .{ .pixels = &lines, .glyphs = &glyphs, .first = &first, .count = &count });
    lcgr.shell_iface.run(&shell, &ctx, &state);
    return true;
}

fn start() callconv(.c) noreturn {
    _ = run();
    while (true) {}
}

comptime {
    if (builtin.os.tag == .freestanding) @export(&start, .{ .name = "_start" });
}

test "demo: three taps count to three" {
    try std.testing.expect(run());
    try std.testing.expectEqual(@as(u32, 3), state.count);
    try std.testing.expect(board.sent >= width * height);
}
