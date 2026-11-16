//! The bare-metal flush interface: how a frame reaches a display with no GPU and no OS, after
//! LVGL's flush driver model (docs.lvgl.io 9.5, "Requirements": a draw buffer of the whole screen
//! or of a few lines, and a flush that copies one area of it to the panel).
//!
//! The caller gives a `Display` its pixel buffer. With `rows == height` that is a whole
//! framebuffer; with fewer rows it is a line buffer, and `flush` draws the frame one band of
//! `rows` rows at a time, handing each band to the board before drawing the next. Only the
//! frame's damage rects (`DrawList.damage`) are drawn and flushed; a draw list that does not
//! track damage repaints everything.
//!
//! The board is any type with `fn flush(*Board, Area, pixels: []const u32, stride: u32) void`:
//! static dispatch, as the render back ends are bound (src/render/iface.zig), not a callback the
//! library stores. `pixels[y * stride + x]` is pixel (area.x0 + x, area.y0 + y) in the display's
//! `Format`; the slice is valid until `flush` returns, so a board that starts a DMA transfer
//! waits for it before returning.

const std = @import("std");
const types = @import("../../core/types.zig");
const DrawList = @import("../../draw/draw_list.zig").DrawList;
const damage = @import("../../draw/damage.zig");
const render = @import("../../render/iface.zig");
const sw = @import("../../render/sw/sw.zig");
const Color = types.Color;

/// A rectangle of the display in physical pixels, x0 and y0 inclusive, x1 and y1 exclusive.
pub const Area = struct {
    x0: u32,
    y0: u32,
    x1: u32,
    y1: u32,

    pub fn w(a: Area) u32 {
        return a.x1 - a.x0;
    }
    pub fn h(a: Area) u32 {
        return a.y1 - a.y0;
    }
};

/// The panel and the caller's draw buffer.
pub const Display = struct {
    width: u32,
    height: u32,
    /// Rows the buffer holds: `height` for a framebuffer, fewer for a line buffer.
    rows: u32,
    /// `width` padded to whole vectors, as `sw.Framebuffer` rows are.
    stride: u32,
    pixels: []u32,
    format: sw.Format,

    /// Pixels a buffer of `rows` rows of a `width` wide display needs.
    pub fn len(width: u32, rows: u32) usize {
        return sw.Framebuffer.len(width, rows);
    }

    pub fn init(pixels: []u32, width: u32, height: u32, rows: u32, format: sw.Format) Display {
        std.debug.assert(rows >= 1 and rows <= height and pixels.len >= len(width, rows));
        const fb: sw.Framebuffer = .init(pixels, width, rows, format);
        return .{ .width = width, .height = height, .rows = rows, .stride = fb.stride, .pixels = pixels, .format = format };
    }

    /// A framebuffer of the whole display whose rows [y0, y0 + rows) are this buffer. Only those
    /// rows may be drawn, which the scissor of every draw into it ensures.
    // ponytail: sw.Framebuffer has no origin, so the band is addressed by shifting the base
    // pointer back by y0 rows; never dereferenced outside the band. An origin field in
    // sw.Framebuffer (lane render-sw) would remove this.
    fn band(d: *const Display, y0: u32) sw.Framebuffer {
        const shift = @as(usize, y0) * d.stride * @sizeOf(u32);
        const base: [*]u32 = @ptrFromInt(@intFromPtr(d.pixels.ptr) -% shift);
        return .{ .pixels = base[0 .. @as(usize, d.stride) * d.height], .width = d.width, .height = d.height, .stride = d.stride, .format = d.format };
    }
};

/// Draws `draw` with `gfx` (already `prepare`d for this frame) and flushes it to `board`, band by
/// band and damage rect by damage rect: each area is cleared to `background`, drawn with every
/// command but the custom ones (the host draws those), and flushed. `scale` is physical pixels
/// per logical pixel. Returns the number of areas flushed.
pub fn flush(d: *const Display, gfx: *const sw.Software, draw: *const DrawList, background: Color, board: anytype) u32 {
    var areas: u32 = 0;
    var y0: u32 = 0;
    while (y0 < d.height) : (y0 += d.rows) {
        const y1 = @min(y0 + d.rows, d.height);
        var fb = d.band(y0);
        for (0..damage.max_rects) |k| {
            const r = damage.Region.scissor(draw.damage.rect(@intCast(k)), .{ d.width, d.height }, gfx.scale);
            const a: Area = .{ .x0 = r[0], .y0 = @max(r[1], y0), .x1 = r[0] + r[2], .y1 = @min(r[1] + r[3], y1) };
            if (a.x0 >= a.x1 or a.y0 >= a.y1) continue;
            const box: [4]u32 = .{ a.x0, a.y0, a.x1, a.y1 };
            fb.fill(box, background);
            render.render(gfx, .{ .fb = &fb, .scissor = box }, draw);
            const at = @as(usize, a.y0 - y0) * d.stride + a.x0;
            board.flush(a, d.pixels[at .. at + @as(usize, a.h() - 1) * d.stride + a.w()], d.stride);
            areas += 1;
        }
    }
    return areas;
}

const testing = std.testing;
const mem = @import("../../core/mem.zig");
const Quad = @import("../../draw/draw_list.zig").Quad;
const Mono = @import("../../text/protocol.zig").Mono;
const context = @import("../../runtime/context.zig");
const Events = @import("../iface.zig").Events;
const example = @import("../example.zig");

const limits: context.Limits = .{ .nodes = 1024, .texts = 256 };
const fb_w = 320;
const fb_h = 240;

/// A board whose panel is memory: each flush copies its area into `panel`.
const Panel = struct {
    panel: sw.Framebuffer,
    areas: [64]Area = undefined,
    n: u32 = 0,

    pub fn flush(p: *Panel, a: Area, pixels: []const u32, stride: u32) void {
        for (0..a.h()) |y| {
            const src = pixels[y * stride ..][0..a.w()];
            @memcpy(p.panel.pixels[(a.y0 + y) * p.panel.stride + a.x0 ..][0..a.w()], src);
        }
        p.areas[p.n] = a;
        p.n += 1;
    }
};

const Fixture = struct {
    var ctx_buffer: [context.Context.requiredBytes(limits)]u8 align(mem.column_align) = undefined;
    var full: [sw.Framebuffer.len(fb_w, fb_h)]u32 = undefined;
    var panel: [sw.Framebuffer.len(fb_w, fb_h)]u32 = undefined;
    var lines: [Display.len(fb_w, 16)]u32 = undefined;
    var glyphs: [512]Quad = undefined;
    var first: [limits.texts]u32 = undefined;
    var count: [limits.texts]u32 = undefined;
};

test "flush: a line buffer, band by band, shows the same pixels as a whole framebuffer" {
    var ctx = try context.Context.init(&Fixture.ctx_buffer, limits);
    var app: example.App = .{};
    const in: @import("../../core/input.zig").Input = .{ .viewport = .{ fb_w, fb_h } };
    var f = ctx.begin(&in);
    app.build(&f, &Events{});
    const out = f.end(.{});

    var gfx: sw.Software = .{};
    const n = (Mono{}).quads(out.draw, &Fixture.glyphs, .{ .first = &Fixture.first, .count = &Fixture.count });
    gfx.prepare({}, out.draw, .{ .quads = Fixture.glyphs[0..n], .first = &Fixture.first, .count = &Fixture.count }, .{ 0, 0 }, 1);
    const bg: Color = .rgb(0, 0, 0);

    // Reference: the whole frame into one framebuffer, as the headless shell draws it.
    var ref: sw.Framebuffer = .init(&Fixture.full, fb_w, fb_h, .rgba8);
    ref.clear(bg);
    render.render(&gfx, .{ .fb = &ref, .scissor = ref.all() }, out.draw);

    // 240 rows through a 16-row line buffer: 15 bands, one area each (no damage tracking).
    @memset(&Fixture.panel, 0xdead_beef);
    var board: Panel = .{ .panel = .init(&Fixture.panel, fb_w, fb_h, .rgba8) };
    const lines: Display = .init(&Fixture.lines, fb_w, fb_h, 16, .rgba8);
    try testing.expectEqual(@as(u32, 15), flush(&lines, &gfx, out.draw, bg, &board));
    for (board.areas[0..board.n], 0..) |a, k| try testing.expectEqual(Area{ .x0 = 0, .y0 = @intCast(16 * k), .x1 = fb_w, .y1 = @intCast(16 * k + 16) }, a);
    for (0..fb_h) |y| for (0..fb_w) |x| {
        try testing.expectEqual(ref.at(@intCast(x), @intCast(y)), board.panel.at(@intCast(x), @intCast(y)));
    };
    // The frame is not blank: the sidebar's panel and a button face are there.
    try testing.expectEqual(app.theme.panel, board.panel.at(80, 230));
    try testing.expectEqual(app.theme.control, board.panel.at(12, 74));

    // A band that does not divide the height: the last band is short.
    board.n = 0;
    const odd: Display = .init(&Fixture.lines, fb_w, fb_h, 7, .rgba8);
    try testing.expectEqual(@as(u32, 35), flush(&odd, &gfx, out.draw, bg, &board));
    try testing.expectEqual(Area{ .x0 = 0, .y0 = 238, .x1 = fb_w, .y1 = fb_h }, board.areas[34]);
    for (0..fb_h) |y| for (0..fb_w) |x| {
        try testing.expectEqual(ref.at(@intCast(x), @intCast(y)), board.panel.at(@intCast(x), @intCast(y)));
    };
}

test "flush: a framebuffer flushes only the damage rects" {
    var ctx = try context.Context.init(&Fixture.ctx_buffer, limits);
    var app: example.App = .{};
    const in: @import("../../core/input.zig").Input = .{ .viewport = .{ fb_w, fb_h } };
    var f = ctx.begin(&in);
    app.build(&f, &Events{});
    const out = f.end(.{});
    var draw = out.draw.*;
    var gfx: sw.Software = .{};
    const n = (Mono{}).quads(&draw, &Fixture.glyphs, .{ .first = &Fixture.first, .count = &Fixture.count });
    gfx.prepare({}, &draw, .{ .quads = Fixture.glyphs[0..n], .first = &Fixture.first, .count = &Fixture.count }, .{ 0, 0 }, 1);

    var board: Panel = .{ .panel = .init(&Fixture.panel, fb_w, fb_h, .rgba8) };
    const whole: Display = .init(&Fixture.full, fb_w, fb_h, fb_h, .rgba8);
    try testing.expectEqual(@as(u32, 1), flush(&whole, &gfx, &draw, .rgb(0, 0, 0), &board));
    try testing.expectEqual(Area{ .x0 = 0, .y0 = 0, .x1 = fb_w, .y1 = fb_h }, board.areas[0]);

    // Two damage rects, one of them half off the display: two areas, clamped, in damage order.
    board.n = 0;
    draw.damage = .empty;
    draw.damage.add(.{ 10, 20, 30, 40 });
    draw.damage.add(.{ 300, 200, 400, 300 });
    try testing.expectEqual(@as(u32, 2), flush(&whole, &gfx, &draw, .rgb(0, 0, 0), &board));
    try testing.expectEqual(Area{ .x0 = 10, .y0 = 20, .x1 = 30, .y1 = 40 }, board.areas[0]);
    try testing.expectEqual(Area{ .x0 = 300, .y0 = 200, .x1 = fb_w, .y1 = fb_h }, board.areas[1]);
    // Nothing changed: nothing is flushed.
    draw.damage = .empty;
    try testing.expectEqual(@as(u32, 0), flush(&whole, &gfx, &draw, .rgb(0, 0, 0), &board));
}
