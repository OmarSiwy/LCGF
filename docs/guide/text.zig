//! The examples of docs/guide/text.md, compiled and run by `zig build docs`. Every ```zig
//! block of the guide is a verbatim piece of this file (docs/guide/snippets.py checks that).

const std = @import("std");
const testing = std.testing;
const lcgf = @import("lcgf");
const Context = lcgf.context.Context;
const types = lcgf.types;
const layout = lcgf.layout;
const Mono = lcgf.protocol.Mono;

const limits: lcgf.context.Limits = .{ .nodes = 16, .texts = 4, .customs = 1, .strings = 256 };
var buffer: [Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = undefined;

// -- font
/// A display face whose every byte is a square: 1 em wide, 1 em tall. It serves only the runs
/// whose `font` column names it and leaves every other row as it found it.
const Squares = struct {
    id: types.Font,

    fn measure(font: Squares, tx: *lcgf.texts.Texts) void {
        const c = &tx.c;
        for (0..tx.len) |k| {
            const mine = c.font[k] == @backingInt(font.id);
            const w: f32 = @as(f32, @floatFromInt(c.bytes[k])) * c.px[k];
            c.w[k] = lcgf.simd.selF(mine, w, c.w[k]);
            c.h[k] = lcgf.simd.selF(mine, c.px[k], c.h[k]);
        }
    }
};
// -- end

test "two fonts on the measure protocol, then glyph quads" {
    var ctx = try Context.init(&buffer, limits);
    const in: lcgf.input.Input = .{ .viewport = .{ 400, 300 } };
    // -- build
    const squares: Squares = .{ .id = @fromBackingInt(1) };
    const mono: Mono = .{ .advance = 0.5, .line = 1.2 };

    var f = ctx.begin(&in);
    _ = f.open(.from("page"), .{ .size = .{ .px(100), .fit } });
    const title = f.text("LCGF", .{ .px = 20, .font = squares.id });
    const body = f.text("twenty-four characters!!", .{ .px = 10, .wrap = true });
    f.close();
    // -- end

    // -- passes
    const t = f.tree();
    const tx = f.texts();
    t.seal(0);
    mono.measure(tx); // every run, as if all were mono
    squares.measure(tx); // then the runs in its font, over what mono wrote
    layout.prepare(t);
    layout.applyText(t, tx, .x);
    layout.fit(t, .x);
    layout.resolve(t, .x, in.viewport[0]);
    layout.textAvail(t, tx); // the width each run was given
    mono.wrap(tx); // re-flow the wrapping runs into it
    layout.applyText(t, tx, .y);
    layout.fit(t, .y);
    layout.resolve(t, .y, in.viewport[1]);
    layout.place(t);
    layout.finalize(t);
    const out = f.finish(); // paint and bookkeeping
    // -- end

    // 4 squares of 20 px; 24 bytes of 5 px wrapped into 100 px: two lines of 12 px.
    try testing.expectEqual(types.Rect{ .x0 = 0, .y0 = 0, .x1 = 80, .y1 = 20 }, out.tree.rect(title.ix()));
    try testing.expectEqual(types.Rect{ .x0 = 0, .y0 = 20, .x1 = 100, .y1 = 44 }, out.tree.rect(body.ix()));

    // -- quads
    var quads: [64]lcgf.draw_list.Quad = undefined;
    var first: [limits.texts]u32 = undefined;
    var count: [limits.texts]u32 = undefined;
    const n = mono.quads(out.draw, &quads, .{ .first = &first, .count = &count });
    const glyphs: lcgf.render_iface.Glyphs = .{
        .quads = quads[0..n],
        .first = &first,
        .count = &count,
        .texture = @fromBackingInt(2), // the atlas, as the back end registered it
    };
    // gfx.prepare(queue, out.draw, glyphs, viewport, scale); then each `text` command draws run k
    // -- end
    try testing.expectEqual(28, n);
    try testing.expectEqual(4, glyphs.count[0]);
    try testing.expectEqual(24, glyphs.count[1]);
}

/// Stands for a real shaper: fills one run's extent.
fn shape(tx: *lcgf.texts.Texts, k: u32) void {
    tx.c.w[k] = @as(f32, @floatFromInt(tx.c.bytes[k])) * tx.c.px[k] * 0.6;
    tx.c.h[k] = tx.c.px[k] * 1.25;
}

test "the extents cache: measure only what was not seen" {
    var ctx = try Context.init(&buffer, limits);
    const in: lcgf.input.Input = .{ .viewport = .{ 400, 300 } };
    const S = struct {
        var cache_buf: [4096]u8 align(lcgf.mem.column_align) = undefined;
    };
    var carver: lcgf.mem.Carver = .{ .buf = &S.cache_buf };
    var cache = lcgf.protocol.Cache.init(&carver, 16);
    cache.clear();
    var measured: u32 = 0;
    for (0..2) |_| {
        var f = ctx.begin(&in);
        _ = f.text("hello", .{});
        _ = f.text("world", .{});
        const tx = f.texts();
        const strings = &ctx.strings[ctx.cur];
        // -- cache
        var misses: [limits.texts]u32 = undefined;
        const m = cache.lookup(tx, strings, &misses); // hits get w, h; misses are listed
        for (misses[0..m]) |k| shape(tx, k); // the expensive part, for unseen runs only
        cache.store(tx, strings, misses[0..m]);
        // -- end
        measured += m;
        _ = f.end(.{}); // Mono measures again here; a real host runs its own passes
    }
    try testing.expectEqual(2, measured); // both runs on the first frame, none on the second
}
