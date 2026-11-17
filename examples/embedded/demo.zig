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

/// No stderr, no stack trace, no `std.Io`: a panic is a trap, which a debugger catches.
pub const panic = std.debug.no_panic;

pub const width = 320;
pub const height = 240;
pub const rows = 1;
pub const limits: context.Limits = .{ .nodes = 8, .texts = 4, .customs = 1, .strings = 64, .anims = 1, .tweens = 1, .flips = 1, .signals = 1, .depth = 4, .timers = 1, .memos = 1 };

pub const id_add = Id.from("add");

pub const App = struct {
    theme: w.Theme = .default,
    count: u32 = 0,

    pub fn build(app: *App, f: *Frame, _: *const Events) void {
        var buf: [16]u8 = undefined;
        if (counter(f, &app.theme, decimal(&buf, "Count ", app.count))) app.count += 1;
    }
};

/// Both builds use this widget tree. The fixed panel bakes its paint on the host.
pub fn counter(f: *Frame, th: *const w.Theme, caption: []const u8) bool {
    _ = f.open(.from("panel"), .{ .size = .{ .fill, .fill }, .pad = @splat(8), .gap = 8, .fill = th.panel });
    _ = w.label(f, th, caption);
    const clicked = w.button(f, th, id_add, "Add").clicked;
    f.close();
    return clicked;
}

/// `prefix` followed by `n` in decimal, in `buf`.
pub fn decimal(buf: []u8, comptime prefix: []const u8, n: u32) []const u8 {
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
pub const script = [_]input.Sample{ .{}, .{}, .{ .touch = tap }, .{ .touch = .{ .pos = tap.pos } }, .{ .touch = tap }, .{ .touch = .{ .pos = tap.pos } }, .{ .touch = tap }, .{ .touch = .{ .pos = tap.pos } }, .{} };

/// A stand-in for the SPI peripheral. A board supplies its own three pin/write operations.
const Transport = struct {
    sum: u32 = 0,
    pub fn select(_: *Transport, _: bool) void {}
    pub fn dataMode(_: *Transport, _: bool) void {}
    pub fn write(bus: *Transport, bytes: []const u8) error{}!void {
        for (bytes) |byte| bus.sum = bus.sum *% 31 +% byte;
    }
};

pub const Board = struct {
    pub const Font = @import("font.zig").Counter;
    font_pixels: Font.Pixels = undefined,
    clock: tick.Tick = .{},
    at: usize = 0,
    bus: Transport = .{},
    sent: u32 = 0,
    row: [width * 2]u8 = undefined,

    pub fn read(b: *Board) ?input.Sample {
        if (b.at == script.len) return null;
        b.clock.inc(16);
        b.at += 1;
        return script[b.at - 1];
    }
    pub fn flush(b: *Board, a: flushing.Area, pixels: []const u32, stride: u32) void {
        const display: lcgr.embedded_spi.Display(Transport) = .{ .bus = &b.bus, .scratch = &b.row };
        display.write(a, pixels, stride, .rgba8) catch unreachable;
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
    state = .{};
    board = .{};
    return runBoard(&board, &board.clock, &state);
}

pub fn runBoard(device: anytype, clock: *const tick.Tick, app: *App) bool {
    var ctx = context.Context.init(&ctx_buffer, limits) catch return false;
    const Shell = lcgr.shell_baremetal_shell.BaremetalOf(@TypeOf(device.*), kinds);
    var shell: Shell = .init(device, clock, width, height, rows, .rgba8, 1, .{ .pixels = &lines, .glyphs = &glyphs, .first = &first, .count = &count });
    var ev: Events = .{};
    var previous: ?struct { count: u32, fill: u32 } = null;
    while (shell.poll(&ev)) {
        if (ctx.needsFrame(&ev.in)) {
            const count_shown = app.count;
            var frame = ctx.begin(&ev.in);
            app.build(&frame, &ev);
            const out = frame.end(.{});
            const button = out.tree.find(id_add);
            const fill = out.tree.c.look[button].fill;
            if (previous) |last| {
                // The fixed panel has two changing areas. The label can grow a digit but
                // never shrinks, and the button occupies the same box on every frame.
                ctx.draw.damage = .empty;
                const counter_changed = last.count != count_shown;
                const button_changed = last.fill != fill;
                const button_box = out.tree.rect(button).array();
                if (counter_changed or button_changed)
                    setRect(&ctx.draw.damage, 0, if (counter_changed) out.draw.runs[0].rect else button_box);
                if (counter_changed and button_changed) setRect(&ctx.draw.damage, 1, button_box);
            }
            previous = .{ .count = count_shown, .fill = fill };
            shell.apply(&out.platform);
            shell.present(&out);
        }
        shell.wait(lcgr.scheduler.wake(&ctx, &ev.in), lcgr.scheduler.pace(&ctx));
    }
    return true;
}

fn setRect(region: *lcgr.damage.Region, comptime slot: usize, box: [4]f32) void {
    region.x0[slot] = box[0];
    region.y0[slot] = box[1];
    region.x1[slot] = box[2];
    region.y1[slot] = box[3];
}

fn start() callconv(.c) noreturn {
    _ = run();
    while (true) {}
}

comptime {
    if (builtin.os.tag == .freestanding and @import("root") == @This()) @export(&start, .{ .name = "_start" });
}

test "demo: three taps count to three" {
    try std.testing.expect(run());
    try std.testing.expectEqual(@as(u32, 3), state.count);
    try std.testing.expect(board.sent > width * height);
    try std.testing.expect(board.sent < 2 * width * height);
}
