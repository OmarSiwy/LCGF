//! Frame benchmark: per-pass timers over a 330-row scene of 3,961 nodes and 1,320 text runs
//! (the scene of docs/CHECKS.md section 3, so the numbers compare). Linux only: it reads the
//! monotonic clock through std.os.linux.
//!
//! Frames are built and painted by the prototype core ("ui", prototype/ui.zig). Text measuring
//! and every layout pass run on the ported core ("lcgr", src/lcgr.zig): each frame the tree and
//! text columns are copied into src/ tables, laid out there and copied back for paint. The
//! copies are not timed. Paint also runs on the ported core (src/draw/paint.zig) over those
//! laid-out tables; the prototype's own paint in `Frame.finish` then runs untimed for its
//! bookkeeping. begin+hit and build still time the prototype until those passes are ported;
//! `frame` is the sum of the four timed parts.
//!
//! A second scene times the grid passes (src/layout/grid.zig): one grid of 16 columns and 250
//! rows holding 4,000 auto-placed items, laid out `grid_frames` times.
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
const Customs = lcgr.customs.Customs;
const DrawList = lcgr.draw_list.DrawList;
const src_bytes = blk: {
    @setEvalBranchQuota(20_000);
    var counter: lcgr.mem.Carver = .{ .buf = null };
    _ = Tree.init(&counter, limits.nodes);
    _ = Texts.init(&counter, limits.texts);
    _ = lcgr.coefs.Coefs.init(&counter, limits.nodes);
    _ = lcgr.levels.Levels.init(&counter, limits.nodes);
    _ = lcgr.incremental.Dirty.init(&counter, limits.nodes);
    _ = lcgr.flex.Flex.init(&counter, limits.nodes);
    _ = Customs.init(&counter, limits.customs);
    _ = DrawList.init(&counter, limits.nodes, limits.texts, limits.customs);
    break :blk counter.off;
};
var src_buffer: [src_bytes]u8 align(lcgr.mem.column_align) = undefined;

/// Copies the first `lcgr.simd.rows(len)` rows of every column of `from` into the column of the
/// same name in `to`. The column sets have the same names and row sizes (Look is the same
/// 36-byte extern row in both). Columns only src/ has (paint inputs added after the port, such
/// as `uv`) are left as they are; the caller gives them the values the prototype implies.
fn copyColumns(to: anytype, from: anytype, len: u32) void {
    inline for (@typeInfo(@TypeOf(to.*)).@"struct".field_names) |name| {
        if (comptime !@hasField(@TypeOf(from.*), name)) continue;
        if (@typeInfo(@TypeOf(@field(to, name))) == .array) {
            inline for (&@field(to, name), &@field(from, name)) |d, s| copyRows(d, s, len);
        } else copyRows(@field(to, name), @field(from, name), len);
    }
}
fn copyRows(to: anytype, from: anytype, len: u32) void {
    const n = @min(lcgr.simd.rows(len), to.len);
    @memcpy(std.mem.sliceAsBytes(to[0..n]), std.mem.sliceAsBytes(from[0..n]));
}

const grid_frames = 1000;
const grid_items = 4000;
const grid_cols = 16;
const grid_rows = grid_items / grid_cols;
const grid_pass_names = [_][]const u8{ "grid.place", "grid.fit.x", "grid.resolve.x", "grid.fit.y", "grid.resolve.y" };
var grid_samples: [grid_pass_names.len][grid_frames]u64 = undefined;
const grid_cap: lcgr.grid.Grids.Capacity = .{ .grids = 1, .tracks = grid_cols + grid_rows, .items = grid_items, .cells = grid_items };
const grid_bytes = blk: {
    @setEvalBranchQuota(20_000);
    var counter: lcgr.mem.Carver = .{ .buf = null };
    _ = Tree.init(&counter, grid_items + 2);
    _ = Texts.init(&counter, 1);
    _ = lcgr.grid.Grids.init(&counter, grid_cap);
    break :blk counter.off;
};
var grid_buffer: [grid_bytes]u8 align(lcgr.mem.column_align) = undefined;

/// Times the grid passes on a 4,000-item grid: columns cycle through fixed, fit and fraction
/// tracks, rows are fit tracks, items differ in natural width so the fit tracks have work.
fn gridBench() void {
    var carver: lcgr.mem.Carver = .{ .buf = &grid_buffer };
    var t = Tree.init(&carver, grid_items + 2);
    var tx = Texts.init(&carver, 1);
    var gs = lcgr.grid.Grids.init(&carver, grid_cap);
    const root = t.push(0, .none, &.{ .size = .{ .px(1280), .fit } });
    const g = t.push(root, .none, &.{ .size = .{ .fill, .fit } });
    var cols: [grid_cols]lcgr.grid.Track = undefined;
    const kinds = [4]lcgr.grid.Track{ .px(40), .fit, .fr(1), .fr(2) };
    for (&cols, 0..) |*c, i| c.* = kinds[i % 4];
    const rows_: [grid_rows]lcgr.grid.Track = @splat(.fit);
    const k = gs.grid(g, &cols, &rows_);
    gs.gaps(k, .{ 4, 2 });
    for (0..grid_items) |i| {
        const w: f32 = @floatFromInt(10 + i % 7);
        const n = t.push(g, .none, &.{ .float = true, .min = .{ w, 12 } });
        t.seal(n);
        _ = gs.autoItem(k, n);
    }
    t.seal(g);
    t.seal(root);
    for (0..grid_frames) |f| {
        var m: [grid_pass_names.len + 1]u64 = undefined;
        m[0] = now();
        lcgr.grid.autoPlace(&gs);
        m[1] = now();
        lcgr.layout.prepare(&t);
        lcgr.layout.applyText(&t, &tx, .x);
        lcgr.grid.fit(&t, &gs, .x);
        m[2] = now();
        lcgr.grid.resolve(&t, &gs, .x, 1280);
        m[3] = now();
        lcgr.layout.applyText(&t, &tx, .y);
        lcgr.grid.fit(&t, &gs, .y);
        m[4] = now();
        lcgr.grid.resolve(&t, &gs, .y, 8000);
        m[5] = now();
        lcgr.layout.place(&t);
        for (0..grid_pass_names.len) |p| grid_samples[p][f] = m[p + 1] - m[p];
    }
}

fn sameDrawList(want: *const ui.DrawList, got: *const DrawList) !void {
    const eql = std.mem.eql;
    const bytes = std.mem.sliceAsBytes;
    if (want.quad_len != got.quad_len or want.run_len != got.run_len or
        want.custom_len != got.custom_len or want.cmd_len != got.cmd_len) return error.PaintDiffers;
    // Quads field by field: src's row has per-corner radii where the prototype has one radius.
    for (want.quads[0..want.quad_len], got.quads[0..got.quad_len]) |w, g| {
        if (!eql(u8, bytes(&[4][4]f32{ w.rect, w.clip, w.params, w.uv }), bytes(&[4][4]f32{ g.rect, g.clip, g.params, g.uv })) or
            w.fill != g.fill or w.border_color != g.border_color or w.border != g.border or
            !eql(f32, &@as([4]f32, @splat(w.radius)), &g.radii)) return error.PaintDiffers;
    }
    if (!eql(u8, bytes(want.runs[0..want.run_len]), bytes(got.runs[0..got.run_len])) or
        !eql(u8, bytes(want.customs[0..want.custom_len]), bytes(got.customs[0..got.custom_len])) or
        !eql(u8, want.strings, got.strings)) return error.PaintDiffers;
    const n = want.cmd_len;
    inline for (.{ "kind", "first", "count", "key" }) |name| {
        if (!eql(@typeInfo(@TypeOf(@field(want.cmd, name))).pointer.child, @field(want.cmd, name)[0..n], @field(got.cmd, name)[0..n])) return error.PaintDiffers;
    }
}

/// The frame loop's passes, then incr_names.
var samples: [all_names.len][frames]u64 = undefined;

/// Incremental layout after the frame loop, on the last frame's tree: a full `layout.run` for
/// reference, then one leaf's height changed and `incremental.update` each frame, first as the
/// scene is (no px container, so the change reaches the root) and then with every row pinned to
/// its own height (rows become relayout boundaries, so it reaches one row).
const incr_names = [_][]const u8{ "full.run", "incr.root", "incr.row" };
const all_names = pass_names ++ incr_names ++ flex_names;
const incr_samples = samples[pass_names.len..];

/// Flex layout after the frame loop, on the last frame's tree, with every row (dir x) a
/// wrapping row in a 400 px viewport: `layout.runFlex` whole, then its line assignment pass
/// alone (src/layout/wrap.zig).
const flex_names = [_][]const u8{ "flex", "lines" };
const flex_samples = samples[pass_names.len + incr_names.len ..];

fn flexWrap(t: *Tree, tx: *Texts, fx: *lcgr.flex.Flex, viewport: [2]f32) void {
    for (0..t.len) |i| fx.c.wrap[i] = t.c.main[0][i];
    const narrow: [2]f32 = .{ 400, viewport[1] };
    for (&flex_samples[0], &flex_samples[1]) |*whole, *lines| {
        const t0 = now();
        lcgr.layout.runFlex(t, fx, tx, narrow);
        const t1 = now();
        lcgr.wrap.wrap(t, fx);
        lines.* = now() - t1;
        whole.* = t1 - t0;
    }
}

fn incremental(t: *Tree, tx: *Texts, d: *lcgr.incremental.Dirty, viewport: [2]f32) void {
    lcgr.layout.run(t, tx, viewport);
    for (&incr_samples[0]) |*s| {
        const t0 = now();
        lcgr.layout.run(t, tx, viewport);
        s.* = now() - t0;
    }
    // The 12 x 12 accent leaf of the middle row.
    var leaf: u32 = 0;
    var seen: u32 = 0;
    for (0..t.len) |i| {
        if (t.c.min[0][i] != 12 or t.c.max[0][i] != 12 or t.c.max[1][i] != 12) continue;
        seen += 1;
        if (seen == rows / 2) leaf = @intCast(i);
    }
    std.debug.assert(leaf != 0);
    const row = t.c.parent[leaf];
    for (1..3) |v| {
        if (v == 2) {
            // Pin every row to the height it has: the layout is the same, the rows are boundaries.
            for (0..t.len) |i| {
                if (t.c.parent[i] != t.c.parent[row] or i == 0) continue;
                t.c.min[1][i] = t.c.size[1][i];
                t.c.max[1][i] = t.c.size[1][i];
            }
            lcgr.layout.run(t, tx, viewport);
        }
        for (&incr_samples[v], 0..) |*s, k| {
            const h: f32 = if (k % 2 == 0) 14 else 12;
            t.c.min[1][leaf] = h;
            t.c.max[1][leaf] = h;
            d.mark(leaf, .y);
            const t0 = now();
            lcgr.incremental.update(t, tx, d, viewport);
            s.* = now() - t0;
        }
    }
}
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
    var sk = lcgr.coefs.Coefs.init(&carver, limits.nodes);
    var slv = lcgr.levels.Levels.init(&carver, limits.nodes);
    var sdirty = lcgr.incremental.Dirty.init(&carver, limits.nodes);
    var sflex = lcgr.flex.Flex.init(&carver, limits.nodes);
    var scu = Customs.init(&carver, limits.customs);
    var sd = DrawList.init(&carver, limits.nodes, limits.texts, limits.customs);
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
        @memset(st.c.uv[0..pt.len], .{ 0, 0, 1, 1 }); // the prototype paints every quad with the whole texture
        for (st.c.radii[0..pt.len], st.c.look[0..pt.len]) |*r, look| r.* = @splat(look.radius); // and one radius
        @memset(st.c.opacity[0..pt.len], 1); // and no opacity
        @memset(st.c.alpha[0..pt.len], 1);
        @memset(st.c.transform[0..pt.len], .{ 1, 0, 0, 1, 0, 0 }); // and no transform
        @memset(st.c.world[0..pt.len], .{ 1, 0, 0, 1, 0, 0 });
        @memset(st.c.clip_radii[0..pt.len], @splat(0)); // and square clips
        copyColumns(&stx.c, &ptx.c, ptx.len);
        const pcu = &f.ctx.customs[f.ctx.cur];
        scu.len = pcu.len;
        copyColumns(&scu.c, &pcu.c, pcu.len);
        const strings = &f.ctx.strings[f.ctx.cur];
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
        // Level-order resolve (C0849); the order is rebuilt every frame and timed here.
        lcgr.levels.build(t, &slv);
        lcgr.levels.resolve(t, &slv, .x, in.viewport[0]);
        m[7] = now();
        lcgr.layout.textAvail(t, tx);
        font.wrap(tx);
        m[8] = now();
        lcgr.layout.applyText(t, tx, .y);
        lcgr.layout.fit(t, .y);
        m[9] = now();
        lcgr.levels.resolve(t, &slv, .y, in.viewport[1]);
        m[10] = now();
        lcgr.coefs.placeRows(t, &sk);
        lcgr.coefs.placeK(t, &sk);
        m[11] = now();
        lcgr.layout.finalize(t);
        m[12] = now();
        lcgr.paint.emit(t, tx, &scu, strings.buf[0..strings.len], &sd);
        m[13] = now();
        copyColumns(&pt.c, &st.c, pt.len);
        copyColumns(&ptx.c, &stx.c, ptx.len);
        const out = f.finish();
        // Differential check, untimed: the ported paint must emit the prototype's draw list.
        if (k == 0) try sameDrawList(out.draw, &sd);
        sink +%= sd.cmd_len + sd.quad_len;
        nodes = t.len;
        texts = tx.len;
        samples[0][k] = m[1] - m[0];
        samples[1][k] = m[2] - m[1];
        samples[2][k] = m[12] - m[3];
        samples[3][k] = m[13] - m[12];
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
    gridBench();
    flexWrap(&st, &stx, &sflex, in.viewport);
    incremental(&st, &stx, &sdirty, in.viewport);
    try w.print("nodes={d} texts={d} frames={d} lanes={d} bytes={d} sink={d}\n", .{ nodes, texts, frames, ui.simd.lanes, buffer.len, sink });
    try w.print("{s:<10} {s:>9} {s:>9}\n", .{ "pass", "median us", "p99 us" });
    for (all_names, &samples) |name, *s| {
        std.mem.sort(u64, s, {}, std.sort.asc(u64));
        try w.print("{s:<10} {d:9.1} {d:9.1}\n", .{ name, us(s[frames / 2]), us(s[frames * 99 / 100]) });
    }
    try w.print("grid: items={d} frames={d}\n", .{ grid_items, grid_frames });
    for (grid_pass_names, &grid_samples) |name, *s| {
        std.mem.sort(u64, s, {}, std.sort.asc(u64));
        try w.print("{s:<14} {d:9.1} {d:9.1}\n", .{ name, us(s[grid_frames / 2]), us(s[grid_frames * 99 / 100]) });
    }
    // Batch counts of the last frame (src/draw/order.zig): what a GPU back end issues per frame
    // in paint order, after merging across text, and the opaque quads a depth back end draws
    // first in one call.
    const plain = lcgr.order.counts(&sd);
    lcgr.order.mergeAcrossText(&sd);
    const merged = lcgr.order.counts(&sd);
    lcgr.order.depthOrder(&sd);
    try w.print("batches   quads={d} text={d} custom={d} merged: quads={d} text={d} custom={d} opaque={d} of {d} quads\n", .{ plain.quads, plain.text, plain.custom, merged.quads, merged.text, merged.custom, sd.opaque_len, sd.quad_len });
    try w.flush();

    const path = json_path orelse return;
    var json_buf: [4096]u8 = undefined;
    var j = std.Io.Writer.fixed(&json_buf);
    try j.print("{{\"nodes\": {d}, \"texts\": {d}, \"frames\": {d}, \"lanes\": {d}, \"passes\": {{", .{ nodes, texts, frames, ui.simd.lanes });
    for (all_names, &samples, 0..) |name, *s, p| {
        try j.print("{s}\n  \"{s}\": {{\"median_us\": {d:.1}, \"p99_us\": {d:.1}}}", .{ if (p == 0) "" else ",", name, us(s[frames / 2]), us(s[frames * 99 / 100]) });
    }
    for (grid_pass_names, &grid_samples) |name, *s| {
        try j.print(",\n  \"{s}\": {{\"median_us\": {d:.1}, \"p99_us\": {d:.1}}}", .{ name, us(s[grid_frames / 2]), us(s[grid_frames * 99 / 100]) });
    }
    try j.writeAll("\n}}\n");
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = j.buffered() });
}
