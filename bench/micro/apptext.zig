//! The window layer's text service (src/app/text.zig) over a frame of 300 text runs: what
//! `Frame.endText` and `Text.glyphs` cost on the first frame, on a frame where nothing changed,
//! and on a frame where one run's text changed; and, for scale, the same frame ended with the
//! bitmap font (`Frame.end` with `Mono`, glyph quads by `Mono.quadsForCommands`).
//! `zig build app-text-bench`, ReleaseFast, Linux.
//!
//! Workload: 300 runs at 13 px in one column (10 wrapping paragraphs of 89 bytes, 290 labels
//! of 7 to 24 bytes), the repository's test faces (Noto Sans subset with a DejaVu Sans
//! fallback for the infinity sign and middle dot), scale 1.25, every run drawn (4,295 glyph
//! quads). Times: median of `frames` frames of each kind (min of the total too), one thread.

const std = @import("std");
const linux = std.os.linux;
const lcgf = @import("lcgf");
const text = @import("app_text");
const Context = lcgf.context.Context;

const limits: lcgf.context.Limits = .{ .nodes = 1024, .texts = 512, .customs = 1, .strings = 32 * 1024 };
const options: text.Options = .{ .texts = 512 };
var ctx_buf: [Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = undefined;
var text_buf: [text.Text.requiredBytes(options)]u8 align(lcgf.mem.column_align) = undefined;
var mono_quads: [8192]lcgf.draw_list.Quad = undefined;
var mono_first: [limits.texts]u32 = undefined;
var mono_count: [limits.texts]u32 = undefined;

const files = [_]text.File{ .{ .bytes = @embedFile("layout.ttf") }, .{ .bytes = @embedFile("symbols.ttf") } };
const words = [_][]const u8{ "Run", "Simulation", "net", "R1", "10k", "value", "\u{221e}", "Open file", "Properties", "x \u{00b7} y" };
const paragraph = "A paragraph of body text that wraps over a few lines in its box, as a property panel has.";
const frames = 200;

const Kind = enum { first, steady, one_run, bitmap };

pub fn main(init: std.process.Init) !void {
    var ctx = try Context.init(&ctx_buf, limits);
    var t = try text.Text.init(&text_buf, options, &files);
    var out_buf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    const o = &w.interface;
    try o.print("{s:<8} {s:>12} {s:>12} {s:>12} {s:>12}\n", .{ "frame", "end us", "glyphs us", "total min", "total med" });
    inline for (comptime std.enums.values(Kind)) |kind| {
        var times: [frames][2]u64 = undefined;
        for (&times, 0..) |*c, i| {
            // The first frame of a new service, each time.
            if (kind == .first) t = try text.Text.init(&text_buf, options, &files);
            c.* = frame(&ctx, &t, kind, @intCast(i));
        }
        try report(o, @tagName(kind), &times);
    }
    try o.flush();
}

/// One frame: build, end, glyphs; returns the ns of the last two. `.one_run`: label 150
/// reads "Changed i".
fn frame(ctx: *Context, t: *text.Text, kind: Kind, i: u32) [2]u64 {
    const in: lcgf.input.Input = .{ .viewport = .{ 1600, 8000 } };
    var f = ctx.begin(&in);
    _ = f.open(.from("page"), .{ .size = .{ .px(1600), .px(8000) } });
    var label: [64]u8 = undefined;
    for (0..300) |k| {
        const s = if (k % 30 == 0)
            paragraph
        else if (k == 150 and kind == .one_run)
            std.fmt.bufPrint(&label, "Changed {d}", .{i}) catch unreachable
        else
            std.fmt.bufPrint(&label, "{s} {d} {s}", .{ words[k % words.len], k, words[(k * 7) % words.len] }) catch unreachable;
        _ = f.text(s, .{ .px = 13, .wrap = k % 30 == 0 });
    }
    f.close();
    const t0 = now();
    if (kind == .bitmap) {
        const out = f.end(.{});
        const t1 = now();
        const n = lcgf.protocol.Mono.quadsForCommands(.{}, Grid, out.draw, &mono_quads, .{ .first = &mono_first, .count = &mono_count }) catch unreachable;
        std.mem.doNotOptimizeAway(&mono_quads);
        std.debug.assert(n > 4000);
        return .{ t1 - t0, now() - t1 };
    }
    const out = f.endText(&t.stack, t.ascent);
    const t1 = now();
    const g = t.glyphs(out.draw, out.texts, 1.25);
    const t2 = now();
    std.debug.assert(g.glyphs.quads.len > 4000);
    std.debug.assert(!t.overflow and !t.stack.overflow);
    return .{ t1 - t0, t2 - t1 };
}

/// The bitmap font's 16 x 16 byte grid (src/render/sw/font.zig).
const Grid = struct {
    pub fn uv(byte: u8) error{}![4]f32 {
        const x: f32 = @floatFromInt(byte % 16);
        const y: f32 = @floatFromInt(byte / 16);
        return .{ x / 16, y / 16, (x + 1) / 16, (y + 1) / 16 };
    }
};

fn report(o: *std.Io.Writer, name: []const u8, times: *[frames][2]u64) !void {
    var e: [frames]u64 = undefined;
    var g: [frames]u64 = undefined;
    var s: [frames]u64 = undefined;
    for (times, &e, &g, &s) |x, *a, *b, *c| {
        a.* = x[0];
        b.* = x[1];
        c.* = x[0] + x[1];
    }
    inline for (.{ &e, &g, &s }) |v| std.mem.sortUnstable(u64, v, {}, std.sort.asc(u64));
    try o.print("{s:<8} {d:>12.1} {d:>12.1} {d:>12.1} {d:>12.1}\n", .{ name, us(e[frames / 2]), us(g[frames / 2]), us(s[0]), us(s[frames / 2]) });
}

fn us(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000;
}

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}
