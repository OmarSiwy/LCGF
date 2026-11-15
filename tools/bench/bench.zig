//! Frame benchmark: per-pass timers over a 330-row scene of 3,961 nodes and 1,320 text runs
//! (the scene of docs/CHECKS.md section 3, so the numbers compare). Linux only: it reads the
//! monotonic clock through std.os.linux.
//!
//! The core under test is the module imported as "ui". Today root build.zig points it at
//! prototype/ui.zig; once the ported core exports the same names, point it at src/lcgr.zig.
//!
//!   zig build bench                    print median and p99 per pass, in microseconds
//!   zig build bench -- --json PATH     also write them as JSON for tools/bench/compare.py
//!   zig build probe                    build one frame, then idle: resident memory and wake-ups
//!                                      (bench --idle under tools/bench/probe.py)
const std = @import("std");
const ui = @import("ui");
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
    const font: ui.fonts.Mono = .{};
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
        const t = f.tree();
        const tx = f.texts();
        t.seal(0);
        m[3] = now();
        font.measure(tx);
        m[4] = now();
        ui.layout.prepare(t);
        m[5] = now();
        ui.layout.applyText(t, tx, .x);
        ui.layout.fit(t, .x);
        m[6] = now();
        ui.layout.resolve(t, .x, in.viewport[0]);
        m[7] = now();
        ui.layout.textAvail(t, tx);
        font.wrap(tx);
        m[8] = now();
        ui.layout.applyText(t, tx, .y);
        ui.layout.fit(t, .y);
        m[9] = now();
        ui.layout.resolve(t, .y, in.viewport[1]);
        m[10] = now();
        ui.layout.place(t);
        m[11] = now();
        ui.layout.finalize(t);
        m[12] = now();
        const out = f.finish();
        m[13] = now();
        sink +%= out.draw.cmd_len + out.draw.quad_len;
        nodes = t.len;
        texts = tx.len;
        samples[0][k] = m[1] - m[0];
        samples[1][k] = m[2] - m[1];
        samples[2][k] = m[12] - m[2];
        samples[3][k] = m[13] - m[12];
        samples[4][k] = m[13] - m[0];
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
