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
//!   zig build bench                    print median and p99 per pass, in microseconds
//!   zig build bench -- --json PATH     also write them as JSON for tools/bench/compare.py
//!   zig build bench -- --scene NAME    run another scene of bench/scenes/ (frame passes only)
//!   zig build bench -- --counters      also count cycles, instructions, L1D and LLC read misses
//!                                      per pass (perf_event_open; pin to one core with taskset)
//!   zig build bench -- --huge          put both column buffers in 2 MB transparent huge pages
//!                                      (mmap + madvise; docs/perf/huge-pages.md)
//!   zig build probe                    build one frame, then idle: resident memory and wake-ups
//!                                      (bench --idle under tools/bench/probe.py)
const std = @import("std");
const ui = @import("ui");
const lcgr = @import("lcgr");
const scenes = @import("scenes");
const linux = std.os.linux;

const rows = 330;
const frames = 3000;

const limits: ui.Limits = .{ .nodes = 4096, .texts = 2048, .strings = 128 * 1024, .anims = 1024 };
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
/// same name in `to`. The column sets have the same names and row sizes, except `look`, which
/// is copied field by field (src reorders it and keeps the border width in its own column). Columns only src/ has (paint inputs added after the port, such
/// as `uv`) are left as they are; the caller gives them the values the prototype implies.
fn copyColumns(to: anytype, from: anytype, len: u32) void {
    inline for (@typeInfo(@TypeOf(to.*)).@"struct".field_names) |name| {
        if (comptime !@hasField(@TypeOf(from.*), name)) continue;
        if (comptime std.mem.eql(u8, name, "look")) {
            // src's Look is reordered and has no border (its own column, C0801): copy the
            // fields both rows have, by name.
            for (@field(to, name)[0..len], @field(from, name)[0..len]) |*d, sr| {
                inline for (@typeInfo(@TypeOf(d.*)).@"struct".field_names) |f| {
                    if (comptime @hasField(@TypeOf(sr), f)) @field(d, f) = @field(sr, f);
                }
            }
            continue;
        }
        if (@typeInfo(@TypeOf(@field(to, name))) == .array) {
            inline for (&@field(to, name), &@field(from, name)) |d, s| copyRows(d, s, len);
        } else copyRows(@field(to, name), @field(from, name), len);
    }
}
fn copyRows(to: anytype, from: anytype, len: u32) void {
    const n = @min(lcgr.simd.rows(len), to.len);
    @memcpy(std.mem.sliceAsBytes(to[0..n]), std.mem.sliceAsBytes(from[0..n]));
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
/// The scene above: 330 rows of label, two buttons, checkbox, slider and accent leaf.
const rows_scene: scenes.Scene = .{ .name = "rows", .frames = frames, .input = rowsInput, .build = build };
const all_scenes = [_]scenes.Scene{rows_scene} ++ scenes.list;

fn rowsInput(in: *ui.Input, k: u32) void {
    in.viewport = .{ 1280, 8000 };
    in.pointer = .{ @floatFromInt(100 + (k * 7) % 900), @floatFromInt(50 + (k * 13) % 7000) };
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

/// Hardware counters per pass, user space only, one group read per timestamp: cycles,
/// instructions, L1D read misses, last-level read misses. -1 when not counting.
var group: i32 = -1;
const counter_names = [_][]const u8{ "cycles", "insns", "L1D miss", "LLC miss" };
var counter_sums: [pass_names.len][counter_names.len]u64 = @splat(@splat(0));

fn openCounters() !void {
    const P = linux.PERF;
    const miss = (@backingInt(P.COUNT.HW.CACHE.OP.READ) << 8) | (@backingInt(P.COUNT.HW.CACHE.RESULT.MISS) << 16);
    const events = [counter_names.len]struct { linux.PERF.TYPE, u64 }{
        .{ .HARDWARE, @backingInt(P.COUNT.HW.CPU_CYCLES) },
        .{ .HARDWARE, @backingInt(P.COUNT.HW.INSTRUCTIONS) },
        .{ .HW_CACHE, @backingInt(P.COUNT.HW.CACHE.L1D) | miss },
        .{ .HW_CACHE, @backingInt(P.COUNT.HW.CACHE.LL) | miss },
    };
    for (events) |e| {
        var a: linux.perf_event_attr = .{ .type = e[0], .config = e[1], .read_format = 8 }; // PERF_FORMAT_GROUP
        a.flags.exclude_kernel = true;
        a.flags.exclude_hv = true;
        const rc: isize = @bitCast(linux.perf_event_open(&a, 0, -1, group, 0));
        if (rc < 0) return error.PerfEventOpen; // perf_event_paranoid > 2, or no such event on this core
        if (group < 0) group = @intCast(rc);
    }
}

/// Timestamps (and, when counting, counter values) at the points the frame loop marks.
const Marks = struct {
    t: [16]u64 = undefined,
    c: [16][counter_names.len]u64 = undefined,

    fn mark(m: *Marks, j: usize) void {
        m.t[j] = now();
        if (group < 0) return;
        var v: [1 + counter_names.len]u64 = undefined; // nr, then one value per event
        _ = linux.read(group, @ptrCast(&v), @sizeOf(@TypeOf(v)));
        m.c[j] = v[1..].*;
    }
    fn count(m: *const Marks, p: usize, from: usize, to: usize) void {
        if (group < 0) return;
        for (&counter_sums[p], m.c[from], m.c[to]) |*s, a, b| s.* += b - a;
    }
};

/// `n` bytes of anonymous memory, 2 MB aligned, advised as transparent huge pages and touched,
/// so the kernel backs it with huge pages now rather than on first use inside a timed pass.
fn hugeBuffer(n: usize) ![]align(2 << 20) u8 {
    const huge = 2 << 20;
    const size = std.mem.alignForward(usize, n, huge);
    const rc = linux.mmap(null, size + huge, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0);
    if (@as(isize, @bitCast(rc)) < 0) return error.Mmap;
    const base: [*]align(huge) u8 = @ptrFromInt(std.mem.alignForward(usize, rc, huge));
    if (linux.madvise(base, size, linux.MADV.HUGEPAGE) != 0) return error.Madvise;
    @memset(base[0..size], 0);
    return base[0..n];
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
    var counters = false;
    var huge = false;
    var scene = rows_scene;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--idle")) {
            idle = true;
        } else if (std.mem.eql(u8, arg, "--huge")) {
            huge = true;
        } else if (std.mem.eql(u8, arg, "--counters")) {
            counters = true;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_path = args.next() orelse return error.MissingPath;
        } else if (std.mem.eql(u8, arg, "--scene")) {
            const name = args.next() orelse return error.MissingScene;
            scene = for (all_scenes) |s| {
                if (std.mem.eql(u8, s.name, name)) break s;
            } else return error.UnknownScene;
        } else return error.UnknownArgument;
    }

    if (counters) try openCounters();
    const proto_buf: []align(ui.mem.column_align) u8 = if (huge) try hugeBuffer(buffer.len) else &buffer;
    const src_buf: []align(lcgr.mem.column_align) u8 = if (huge) try hugeBuffer(src_buffer.len) else &src_buffer;
    var ctx = try ui.Context.init(proto_buf, limits);
    const th: ui.Theme = .{};
    var in: ui.Input = .{};
    const font: lcgr.protocol.Mono = .{};
    var carver: lcgr.mem.Carver = .{ .buf = src_buf };
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
    const polls: u32 = if (idle) 1 else scene.frames;
    var built: usize = 0;
    for (0..polls) |k| {
        scene.input(&in, @intCast(k));
        if (scene.idle and !ctx.needsFrame(&in)) continue;
        var m: Marks = .{};
        m.mark(0);
        var f = ctx.begin(&in); // includes the SIMD hit test and spring step
        m.mark(1);
        scene.build(&f, &th);
        m.mark(2);
        const pt = f.tree();
        const ptx = f.texts();
        pt.seal(0);
        st.len = pt.len;
        stx.len = ptx.len;
        copyColumns(&st.c, &pt.c, pt.len);
        for (st.c.border[0..pt.len], pt.c.look[0..pt.len]) |*d, look| d.* = look.border;
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
        m.mark(3);
        font.measure(tx);
        m.mark(4);
        lcgr.layout.prepare(t);
        m.mark(5);
        lcgr.layout.applyText(t, tx, .x);
        lcgr.layout.fit(t, .x);
        m.mark(6);
        // Level-order resolve (C0849); the order is rebuilt every frame and timed here.
        lcgr.levels.build(t, &slv);
        lcgr.levels.resolve(t, &slv, .x, in.viewport[0]);
        m.mark(7);
        lcgr.layout.textAvail(t, tx);
        font.wrap(tx);
        m.mark(8);
        lcgr.layout.applyText(t, tx, .y);
        lcgr.layout.fit(t, .y);
        m.mark(9);
        lcgr.levels.resolve(t, &slv, .y, in.viewport[1]);
        m.mark(10);
        lcgr.coefs.placeRows(t, &sk);
        lcgr.coefs.placeK(t, &sk);
        m.mark(11);
        lcgr.layout.finalize(t);
        m.mark(12);
        lcgr.paint.emit(t, tx, &scu, strings.buf[0..strings.len], &sd);
        m.mark(13);
        copyColumns(&pt.c, &st.c, pt.len);
        copyColumns(&ptx.c, &stx.c, ptx.len);
        const out = f.finish();
        // Differential check, untimed: the ported paint must emit the prototype's draw list.
        if (built == 0) try sameDrawList(out.draw, &sd);
        sink +%= sd.cmd_len + sd.quad_len;
        nodes = t.len;
        texts = tx.len;
        const b = built;
        const spans = [pass_names.len][2]u8{ .{ 0, 1 }, .{ 1, 2 }, .{ 3, 12 }, .{ 12, 13 }, .{ 0, 0 }, .{ 3, 4 }, .{ 4, 5 }, .{ 5, 6 }, .{ 6, 7 }, .{ 7, 8 }, .{ 8, 9 }, .{ 9, 10 }, .{ 10, 11 }, .{ 11, 12 } };
        for (spans, 0..) |sp, p| {
            samples[p][b] = m.t[sp[1]] - m.t[sp[0]];
            m.count(p, sp[0], sp[1]);
        }
        samples[4][b] = samples[0][b] + samples[1][b] + samples[2][b] + samples[3][b];
        for (0..4) |p| m.count(4, spans[p][0], spans[p][1]);
        built += 1;
    }
    // Target D5: with input that never changes, only the first frame and its settle frame are built.
    if (scene.idle and built > 2) return error.WorkWhileIdle;

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
    // The incremental and flex passes are measured on the rows scene only.
    const is_rows = scene.build == rows_scene.build;
    if (is_rows) {
        flexWrap(&st, &stx, &sflex, in.viewport);
        incremental(&st, &stx, &sdirty, in.viewport);
    }
    const names: []const []const u8 = if (is_rows) &all_names else &pass_names;
    // incremental and flexWrap fill all `frames` samples, the frame loop `built` of them.
    for (samples[0..names.len], 0..) |*s, p| std.mem.sort(u64, s[0..if (p < pass_names.len) built else frames], {}, std.sort.asc(u64));
    try w.print("scene={s} nodes={d} texts={d} frames={d} polls={d} lanes={d} bytes={d} sink={d}\n", .{ scene.name, nodes, texts, built, polls, ui.simd.lanes, buffer.len, sink });
    try w.print("{s:<10} {s:>9} {s:>9}\n", .{ "pass", "median us", "p99 us" });
    for (names, samples[0..names.len], 0..) |name, *s, p| {
        const n = if (p < pass_names.len) built else frames;
        try w.print("{s:<10} {d:9.1} {d:9.1}\n", .{ name, us(s[n / 2]), us(s[n * 99 / 100]) });
    }
    if (group >= 0) {
        // Means per built frame. Each read is a syscall: its kernel half is not counted, but it
        // evicts some L1 lines, so short passes carry a few dozen extra misses.
        try w.print("{s:<10}", .{"counters"});
        for (counter_names) |name| try w.print(" {s:>10}", .{name});
        try w.print(" {s:>10} {s:>10}\n", .{ "IPC", "L1D/node" });
        for (pass_names, counter_sums) |name, sums| {
            try w.print("{s:<10}", .{name});
            for (sums) |v| try w.print(" {d:10.0}", .{@as(f64, @floatFromInt(v)) / @as(f64, @floatFromInt(built))});
            const f: [4]f64 = .{ @floatFromInt(sums[0]), @floatFromInt(sums[1]), @floatFromInt(sums[2]), @floatFromInt(@max(built * nodes, 1)) };
            try w.print(" {d:10.2} {d:10.2}\n", .{ f[1] / @max(f[0], 1), f[2] / f[3] });
        }
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
    try j.print("{{\"nodes\": {d}, \"texts\": {d}, \"frames\": {d}, \"lanes\": {d}, \"passes\": {{", .{ nodes, texts, built, ui.simd.lanes });
    for (names, samples[0..names.len], 0..) |name, *s, p| {
        const n = if (p < pass_names.len) built else frames;
        try j.print("{s}\n  \"{s}\": {{\"median_us\": {d:.1}, \"p99_us\": {d:.1}}}", .{ if (p == 0) "" else ",", name, us(s[n / 2]), us(s[n * 99 / 100]) });
    }
    try j.writeAll("\n}}\n");
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = j.buffered() });
}
