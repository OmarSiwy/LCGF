//! Frame benchmark: per-pass timers over a 330-row scene of 3,961 nodes and 1,320 text runs
//! (the scene of docs/CHECKS.md section 3, so the numbers compare). Linux only: it reads the
//! monotonic clock through std.os.linux.
//!
//! Frames are built and painted by the prototype core ("ui", prototype/ui.zig). Text measuring
//! and every layout pass run on the ported core ("lcgr", src/lcgr.zig): each frame the tree and
//! text columns are copied into src/ tables, laid out there and copied back for paint. The
//! copies are not timed. begin+hit, build and paint still time the prototype until those passes
//! are ported; `frame` is the sum of the four timed parts.
//!
//!   zig build bench                    print median and p99 per pass, in microseconds
//!   zig build bench -- --json PATH     also write them as JSON for tools/bench/compare.py
//!   zig build probe                    build one frame, then idle: resident memory and wake-ups
//!                                      (bench --idle under tools/bench/probe.py)
const std = @import("std");
const ui = @import("ui");
const lcgr = @import("lcgr");
const linux = std.os.linux;

const rows = 330;
const frames = 3000;

const limits: ui.Limits = .{ .nodes = 4096, .texts = 2048, .strings = 128 * 1024 };
var buffer: [ui.Context.requiredBytes(limits)]u8 align(ui.mem.column_align) = undefined;

/// Frame passes first, then the layout passes that make up `layout`.
const pass_names = [_][]const u8{
    "begin+hit", "build",     "layout", "paint",     "frame",
    "measure",   "prepare",   "fit.x",  "resolve.x", "wrap",
    "fit.y",     "resolve.y", "place",  "finalize",
};
comptime {
    // The copies below move whole vectors of rows, so both cores must pad alike.
    std.debug.assert(ui.simd.lanes == lcgr.simd.lanes);
}

const Tree = lcgr.tree.Tree;
const Texts = lcgr.texts.Texts;
const src_bytes = blk: {
    @setEvalBranchQuota(20_000);
    var counter: lcgr.mem.Carver = .{ .buf = null };
    _ = Tree.init(&counter, limits.nodes);
    _ = Texts.init(&counter, limits.texts);
    break :blk counter.off;
};
var src_buffer: [src_bytes]u8 align(lcgr.mem.column_align) = undefined;

/// Copies the first `lcgr.simd.rows(len)` rows of every column of `from` into the column of the
/// same name in `to`. The column sets have the same names and row sizes (Look is the same
/// 36-byte extern row in both); a missing name is a compile error.
fn copyColumns(to: anytype, from: anytype, len: u32) void {
    inline for (@typeInfo(@TypeOf(to.*)).@"struct".field_names) |name| {
        if (@typeInfo(@TypeOf(@field(to, name))) == .array) {
            inline for (&@field(to, name), &@field(from, name)) |d, s| copyRows(d, s, len);
        } else copyRows(@field(to, name), @field(from, name), len);
    }
}
fn copyRows(to: anytype, from: anytype, len: u32) void {
    const n = @min(lcgr.simd.rows(len), to.len);
    @memcpy(std.mem.sliceAsBytes(to[0..n]), std.mem.sliceAsBytes(from[0..n]));
}

var samples: [pass_names.len][frames]u64 = undefined;
var values: [rows]f32 = @splat(0.5);
var checks: [rows]bool = @splat(false);

fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn build(f: *ui.Frame, th: *const ui.Theme) void {
    const base = ui.Id.from("row");
    for (0..rows) |r| {
        const id = base.with(@intCast(r));
        _ = f.open(id, .{ .dir = .x, .size = .{ .fill, .fit }, .gap = 6, .pad = @splat(2), .cross = .center });
        _ = ui.widgets.label(f, th, "Row label");
        _ = ui.widgets.button(f, th, id.with(1), "Apply");
        _ = ui.widgets.button(f, th, id.with(2), "Revert");
        _ = ui.widgets.checkbox(f, th, id.with(3), &checks[r], "Enabled");
        _ = ui.widgets.slider(f, th, id.with(4), &values[r], 0, 1);
        _ = f.leaf(.none, .{ .size = .{ .px(12), .px(12) }, .fill = th.accent });
        f.close();
    }
}

fn us(ns: u64) f64 {
    return @as(f64, @floatFromInt(ns)) / 1000.0;
}

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    var json_path: ?[]const u8 = null;
    var idle = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--idle")) {
            idle = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_path = args.next() orelse return error.MissingPath;
        } else return error.UnknownArgument;
    }

    var ctx = try ui.Context.init(&buffer, limits);
    const th: ui.Theme = .{};
    var in: ui.Input = .{ .viewport = .{ 1280, 8000 } };
    const font: lcgr.protocol.Mono = .{};
    var carver: lcgr.mem.Carver = .{ .buf = &src_buffer };
    var st = Tree.init(&carver, limits.nodes);
    var stx = Texts.init(&carver, limits.texts);
    var sink: u64 = 0;
    var nodes: usize = 0;
    var texts: usize = 0;
    for (0..if (idle) 1 else frames) |k| {
        in.pointer = .{ @floatFromInt(100 + (k * 7) % 900), @floatFromInt(50 + (k * 13) % 7000) };
        var m: [16]u64 = undefined;
        m[0] = now();
        var f = ctx.begin(&in); // includes the SIMD hit test and spring step
        m[1] = now();
        build(&f, &th);
        m[2] = now();
        const pt = f.tree();
        const ptx = f.texts();
        pt.seal(0);
        st.len = pt.len;
        stx.len = ptx.len;
        copyColumns(&st.c, &pt.c, pt.len);
        copyColumns(&stx.c, &ptx.c, ptx.len);
        const t = &st;
        const tx = &stx;
        m[3] = now();
        font.measure(tx);
        m[4] = now();
        lcgr.layout.prepare(t);
        m[5] = now();
        lcgr.layout.applyText(t, tx, .x);
        lcgr.layout.fit(t, .x);
        m[6] = now();
        lcgr.layout.resolve(t, .x, in.viewport[0]);
        m[7] = now();
        lcgr.layout.textAvail(t, tx);
        font.wrap(tx);
        m[8] = now();
        lcgr.layout.applyText(t, tx, .y);
        lcgr.layout.fit(t, .y);
        m[9] = now();
        lcgr.layout.resolve(t, .y, in.viewport[1]);
        m[10] = now();
        lcgr.layout.place(t);
        m[11] = now();
        lcgr.layout.finalize(t);
        m[12] = now();
        copyColumns(&pt.c, &st.c, pt.len);
        copyColumns(&ptx.c, &stx.c, ptx.len);
        const paint_start = now();
        const out = f.finish();
        m[13] = now();
        sink +%= out.draw.cmd_len + out.draw.quad_len;
        nodes = t.len;
        texts = tx.len;
        samples[0][k] = m[1] - m[0];
        samples[1][k] = m[2] - m[1];
        samples[2][k] = m[12] - m[3];
        samples[3][k] = m[13] - paint_start;
        samples[4][k] = samples[0][k] + samples[1][k] + samples[2][k] + samples[3][k];
        for (5..pass_names.len, 3..) |p, j| samples[p][k] = m[j + 1] - m[j];
    }

    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const w = &out.interface;
    if (idle) {
        // Stand-in for a shell waiting for events: block on stdin until it closes.
        try w.print("ready nodes={d} sink={d}\n", .{ nodes, sink });
        try w.flush();
        var byte: [1]u8 = undefined;
        while (linux.read(0, &byte, 1) > 0) {}
        return;
    }
    try w.print("nodes={d} texts={d} frames={d} lanes={d} bytes={d} sink={d}\n", .{ nodes, texts, frames, ui.simd.lanes, buffer.len, sink });
    try w.print("{s:<10} {s:>9} {s:>9}\n", .{ "pass", "median us", "p99 us" });
    for (pass_names, &samples) |name, *s| {
        std.mem.sort(u64, s, {}, std.sort.asc(u64));
        try w.print("{s:<10} {d:9.1} {d:9.1}\n", .{ name, us(s[frames / 2]), us(s[frames * 99 / 100]) });
    }
    try w.flush();

    const path = json_path orelse return;
    var json_buf: [4096]u8 = undefined;
    var j = std.Io.Writer.fixed(&json_buf);
    try j.print("{{\"nodes\": {d}, \"texts\": {d}, \"frames\": {d}, \"lanes\": {d}, \"passes\": {{", .{ nodes, texts, frames, ui.simd.lanes });
    for (pass_names, &samples, 0..) |name, *s, p| {
        try j.print("{s}\n  \"{s}\": {{\"median_us\": {d:.1}, \"p99_us\": {d:.1}}}", .{ if (p == 0) "" else ",", name, us(s[frames / 2]), us(s[frames * 99 / 100]) });
    }
    try j.writeAll("\n}}\n");
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = j.buffered() });
}
