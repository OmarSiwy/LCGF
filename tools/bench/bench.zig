//! Frame benchmark: per-pass timers over a 330-row scene of 3,961 nodes and 1,320 text runs
//! (bench/scenes/rows.zig, the scene of docs/CHECKS.md section 3, so the numbers compare).
//! Linux only: it reads the monotonic clock through std.os.linux.
//!
//! Every pass times lcgf's runtime front end (src/runtime/): `Context.begin` (settle, hit test,
//! spring and tween step) is begin+hit, the scene building through `Frame` and the reference
//! widgets (src/widgets/base.zig) is build, the body of `Frame.end` split at each pass is layout,
//! and `Frame.finish` (paint and bookkeeping) is paint. `frame` is the sum of the four, over the
//! frames built; `poll` times every poll, `Context.needsFrame` included, as a host polls (every
//! scene but rows builds only the frames needsFrame asks for: bench/scenes/scenes.zig). The
//! first frame's draw list is checked against the normal `Frame.end` entry point.
//!
//! A second scene times the grid passes (src/layout/grid.zig): one grid of 16 columns and 250
//! rows holding 4,000 auto-placed items, laid out `grid_frames` times.
//!
//!   zig build bench                    print median and p99 per pass, in microseconds
//!   zig build bench -- --json PATH     also write them as JSON for tools/bench/compare.py
//!   zig build bench -- --scene NAME    run another scene of bench/scenes/ (frame passes only)
//!   zig build bench -- --counters      also count cycles, instructions, L1D and LLC read misses
//!                                      per pass (perf_event_open; pin to one core with taskset)
//!   zig build bench -- --huge          put benchmark columns in 2 MB transparent huge pages
//!                                      (mmap + madvise; docs/perf/huge-pages.md)
//!   zig build probe                    build one frame, then idle: resident memory and wake-ups
//!                                      (bench --idle under tools/bench/probe.py)
const std = @import("std");
const lcgf = @import("lcgf");
const scenes = @import("scenes");
const linux = std.os.linux;

/// No 256 KB thread-local signal stack (std's default, for stack traces on a crash): start.zig
/// clears it before main, which the other harnesses' start-up does not pay.
pub const std_options: std.Options = .{ .signal_stack_size = null };

const rows = scenes.rows.count;
const frames = 3000;

/// Frame passes first, then the layout passes that make up `layout`.
const pass_names = [_][]const u8{
    "begin+hit", "build",     "layout", "paint",     "frame",
    "measure",   "prepare",   "fit.x",  "resolve.x", "wrap",
    "fit.y",     "resolve.y", "place",  "finalize",
};
const Tree = lcgf.tree.Tree;
const Texts = lcgf.texts.Texts;
const DrawList = lcgf.draw_list.DrawList;
const Context = lcgf.context.Context;
const limits: lcgf.context.Limits = .{ .nodes = 4096, .texts = 2048, .strings = 128 * 1024, .anims = 1024 };
var ctx_buffer: [Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = @splat(0);

const grid_frames = 1000;
const grid_items = 4000;
const grid_cols = 16;
const grid_rows = grid_items / grid_cols;
const grid_pass_names = [_][]const u8{ "grid.place", "grid.fit.x", "grid.resolve.x", "grid.fit.y", "grid.resolve.y" };
var grid_samples: [grid_pass_names.len][grid_frames]u64 = undefined;
const grid_cap: lcgf.grid.Grids.Capacity = .{ .grids = 1, .tracks = grid_cols + grid_rows, .items = grid_items, .cells = grid_items };
const grid_bytes = blk: {
    @setEvalBranchQuota(20_000);
    var counter: lcgf.mem.Carver = .{ .buf = null };
    _ = Tree.init(&counter, grid_items + 2);
    _ = Texts.init(&counter, 1);
    _ = lcgf.grid.Grids.init(&counter, grid_cap);
    break :blk counter.off;
};
const layout_bytes = blk: {
    @setEvalBranchQuota(20_000);
    var counter: lcgf.mem.Carver = .{ .buf = null };
    _ = lcgf.flex.Flex.init(&counter, limits.nodes);
    _ = lcgf.incremental.Dirty.init(&counter, limits.nodes);
    break :blk counter.off;
};
// The grid's tables are dead before the flex and incremental passes reuse their storage.
var rows_buffer: [@max(grid_bytes, layout_bytes)]u8 align(lcgf.mem.column_align) = @splat(0);

/// Times the grid passes on a 4,000-item grid after the frame loops: columns cycle through fixed, fit and fraction
/// tracks, rows are fit tracks, items differ in natural width so the fit tracks have work.
fn gridBench(buf: []align(lcgf.mem.column_align) u8) void {
    var carver: lcgf.mem.Carver = .{ .buf = buf };
    var t = Tree.init(&carver, grid_items + 2);
    var tx = Texts.init(&carver, 1);
    var gs = lcgf.grid.Grids.init(&carver, grid_cap);
    const root = t.push(0, .none, &.{ .size = .{ .px(1280), .fit } });
    const g = t.push(root, .none, &.{ .size = .{ .fill, .fit } });
    var cols: [grid_cols]lcgf.grid.Track = undefined;
    const kinds = [4]lcgf.grid.Track{ .px(40), .fit, .fr(1), .fr(2) };
    for (&cols, 0..) |*c, i| c.* = kinds[i % 4];
    const rows_: [grid_rows]lcgf.grid.Track = @splat(.fit);
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
        lcgf.grid.autoPlace(&gs);
        m[1] = now();
        lcgf.layout.prepare(&t);
        lcgf.layout.applyText(&t, &tx, .x);
        lcgf.grid.fit(&t, &gs, .x);
        m[2] = now();
        lcgf.grid.resolve(&t, &gs, .x, 1280);
        m[3] = now();
        lcgf.layout.applyText(&t, &tx, .y);
        lcgf.grid.fit(&t, &gs, .y);
        m[4] = now();
        lcgf.grid.resolve(&t, &gs, .y, 8000);
        m[5] = now();
        lcgf.layout.place(&t);
        for (0..grid_pass_names.len) |p| grid_samples[p][f] = m[p + 1] - m[p];
    }
}

/// The frame loop's passes, then incr_names.
var samples: [all_names.len][frames]u64 = undefined;
/// Every poll: `Context.needsFrame`, and the frame when it asked for one. The comparison's
/// frame time (bench/vs/measure.py), as the other harnesses time every poll.
var poll_samples: [frames]u64 = undefined;

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

fn flexWrap(t: *Tree, tx: *Texts, fx: *lcgf.flex.Flex, viewport: [2]f32) void {
    for (0..t.len) |i| fx.c.wrap[i] = t.c.main[0][i];
    const narrow: [2]f32 = .{ 400, viewport[1] };
    for (&flex_samples[0], &flex_samples[1]) |*whole, *lines| {
        const t0 = now();
        lcgf.layout.runFlex(t, fx, tx, narrow);
        const t1 = now();
        lcgf.wrap.wrap(t, fx);
        lines.* = now() - t1;
        whole.* = t1 - t0;
    }
}

fn incremental(t: *Tree, tx: *Texts, d: *lcgf.incremental.Dirty, viewport: [2]f32) void {
    lcgf.layout.run(t, tx, viewport);
    for (&incr_samples[0]) |*s| {
        const t0 = now();
        lcgf.layout.run(t, tx, viewport);
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
            lcgf.layout.run(t, tx, viewport);
        }
        for (&incr_samples[v], 0..) |*s, k| {
            const h: f32 = if (k % 2 == 0) 14 else 12;
            t.c.min[1][leaf] = h;
            t.c.max[1][leaf] = h;
            d.mark(leaf, .y);
            const t0 = now();
            lcgf.incremental.update(t, tx, d, viewport);
            s.* = now() - t0;
        }
    }
}
fn now() u64 {
    var ts: linux.timespec = undefined;
    _ = linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
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

/// What a frame loop leaves for the report: counts, and the last frame's tables.
const Run = struct {
    built: usize = 0,
    nodes: usize = 0,
    texts: usize = 0,
    sink: u64 = 0,
    viewport: [2]f32 = .{ 0, 0 },
    tree: *Tree = undefined,
    texts_table: *Texts = undefined,
    draw: *DrawList = undefined,
};

/// Fills `samples` and `counter_sums` for frame `b` from the marks of the frame loop.
fn record(m: *const Marks, b: usize) void {
    const spans = [pass_names.len][2]u8{ .{ 0, 1 }, .{ 1, 2 }, .{ 3, 12 }, .{ 12, 13 }, .{ 0, 0 }, .{ 3, 4 }, .{ 4, 5 }, .{ 5, 6 }, .{ 6, 7 }, .{ 7, 8 }, .{ 8, 9 }, .{ 9, 10 }, .{ 10, 11 }, .{ 11, 12 } };
    for (spans, 0..) |sp, p| {
        samples[p][b] = m.t[sp[1]] - m.t[sp[0]];
        m.count(p, sp[0], sp[1]);
    }
    samples[4][b] = samples[0][b] + samples[1][b] + samples[2][b] + samples[3][b];
    for (0..4) |p| m.count(4, spans[p][0], spans[p][1]);
}

/// Checks the measured pass sequence against the ordinary host entry point, outside the timers.
fn checkFirstFrame(scene: scenes.Scene, in: *const lcgf.input.Input, got: *const DrawList) !void {
    const allocator = std.heap.page_allocator;
    const storage = try allocator.alignedAlloc(u8, .fromByteUnits(lcgf.mem.column_align), ctx_buffer.len);
    defer allocator.free(storage);
    var ctx = try Context.init(storage, limits);
    var f = ctx.begin(in);
    scene.build(&f, &.{});
    const want = f.end(.{}).draw;
    if (!lcgf.widgets_base.sameDraw(want, got) or !std.mem.eql(u8, want.strings, got.strings) or
        !std.mem.eql(u8, std.mem.sliceAsBytes(want.customs[0..want.custom_len]), std.mem.sliceAsBytes(got.customs[0..got.custom_len])))
        return error.PaintDiffers;
}

/// lcgf's runtime front end, end to end: `Context.begin`, the scene through `Frame`, the body of
/// `Frame.end` with a mark between passes, and `Frame.finish`.
fn runScene(scene: scenes.Scene, polls: u32, buf: []align(lcgf.mem.column_align) u8) !Run {
    const S = struct {
        var ctx: Context = undefined;
    };
    const ctx = &S.ctx;
    // A static buffer in bss (or fresh huge pages), used once: zero already.
    ctx.* = try Context.initZeroed(buf, limits);
    const th: lcgf.widgets_base.Theme = .{};
    var in: lcgf.input.Input = .{};
    const font: lcgf.protocol.Mono = .{};
    const inc = lcgf.incremental;
    var r: Run = .{};
    for (0..polls) |k| {
        scene.input(&in, @intCast(k));
        const p0 = now();
        if (!scene.every and !ctx.needsFrame(&in)) {
            poll_samples[k] = now() - p0;
            continue;
        }
        var m: Marks = .{};
        m.mark(0);
        var f = ctx.begin(&in);
        m.mark(1);
        scene.build(&f, &th);
        m.mark(2);
        // Frame.end, pass by pass.
        const t = f.tree();
        const tx = f.texts();
        t.seal(0);
        m.mark(3);
        font.measure(tx);
        m.mark(4);
        const memos = &ctx.memos;
        const kept = memos.kept[0..lcgf.simd.selU(t.overflow, 0, memos.kept_len)];
        inc.prepareKept(t, kept);
        m.mark(5);
        inc.applyTextKept(t, tx, .x, kept);
        inc.fitKept(t, .x, kept);
        m.mark(6);
        const lv = &ctx.levels;
        if (kept.len == 0) lcgf.levels.build(t, lv);
        lcgf.frame.resolve(t, lv, .x, in.viewport[0], kept);
        m.mark(7);
        lcgf.layout.textAvail(t, tx);
        font.wrap(tx);
        m.mark(8);
        inc.applyTextKept(t, tx, .y, kept);
        inc.fitKept(t, .y, kept);
        m.mark(9);
        lcgf.frame.resolve(t, lv, .y, in.viewport[1], kept);
        m.mark(10);
        inc.placeKept(t, kept);
        m.mark(11);
        if (!ctx.settings.reduced_motion) ctx.motion = @max(ctx.motion, lcgf.flip.apply(t, f.prevTree(), &ctx.flips, &ctx.anims, ctx.frame));
        lcgf.layout.finalize(t);
        m.mark(12);
        const out = f.finish();
        m.mark(13);
        // The one-poll startup and idle probe uses only the measured context.
        if (r.built == 0 and polls > 1) try checkFirstFrame(scene, &in, out.draw);
        r.sink +%= out.draw.cmd_len + out.draw.quad_len;
        r.nodes = t.len;
        r.texts = tx.len;
        record(&m, r.built);
        poll_samples[k] = m.t[13] - p0;
        r.built += 1;
    }
    r.viewport = in.viewport;
    r.tree = &ctx.trees[ctx.cur];
    r.texts_table = &ctx.texts[ctx.cur];
    r.draw = &ctx.draw;
    return r;
}

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    defer args.deinit();
    _ = args.next();
    var json_path: ?[]const u8 = null;
    var idle = false;
    var counters = false;
    var huge = false;
    var index: usize = 0;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--idle")) {
            idle = true;
        } else if (std.mem.eql(u8, arg, "--huge")) {
            huge = true;
        } else if (std.mem.eql(u8, arg, "--counters")) {
            counters = true;
        } else if (std.mem.startsWith(u8, arg, "--core=")) {
            if (!std.mem.eql(u8, arg, "--core=src")) return error.UnknownCore;
        } else if (std.mem.eql(u8, arg, "--json")) {
            json_path = args.next() orelse return error.MissingPath;
        } else if (std.mem.eql(u8, arg, "--scene")) {
            const name = args.next() orelse return error.MissingScene;
            index = for (scenes.all, 0..) |s, i| {
                if (std.mem.eql(u8, s.name, name)) break i;
            } else return error.UnknownScene;
        } else return error.UnknownArgument;
    }
    const scene = scenes.all[index];

    if (counters) try openCounters();
    const polls: u32 = if (idle) 1 else scene.frames;
    const run = try runScene(scene, polls, if (huge) try hugeBuffer(ctx_buffer.len) else &ctx_buffer);
    const built = run.built;
    // Target D5: with input that never changes, only the first frame and its settle frame are built.
    if (scene.idle and built > 2) return error.WorkWhileIdle;

    var buf: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &buf);
    const w = &out.interface;
    if (idle) {
        // Stand-in for a shell waiting for events: block on stdin until it closes.
        try w.print("ready nodes={d} sink={d}\n", .{ run.nodes, run.sink });
        try w.flush();
        var byte: [1]u8 = undefined;
        while (linux.read(0, &byte, 1) > 0) {}
        return;
    }
    // The incremental and flex passes are measured on the rows scene only, on the last frame's tree.
    const is_rows = index == 0;
    if (is_rows) {
        const scratch = if (huge) try hugeBuffer(rows_buffer.len) else &rows_buffer;
        gridBench(scratch);
        var carver: lcgf.mem.Carver = .{ .buf = scratch };
        var flex = lcgf.flex.Flex.init(&carver, limits.nodes);
        var dirty = lcgf.incremental.Dirty.init(&carver, limits.nodes);
        flexWrap(run.tree, run.texts_table, &flex, run.viewport);
        incremental(run.tree, run.texts_table, &dirty, run.viewport);
    }
    const names: []const []const u8 = if (is_rows) &all_names else &pass_names;
    // incremental and flexWrap fill all `frames` samples, the frame loop `built` of them.
    for (samples[0..names.len], 0..) |*s, p| std.mem.sort(u64, s[0..if (p < pass_names.len) built else frames], {}, std.sort.asc(u64));
    try w.print("scene={s} core=src nodes={d} texts={d} frames={d} polls={d} lanes={d} bytes={d} sink={d}\n", .{ scene.name, run.nodes, run.texts, built, polls, lcgf.simd.lanes, ctx_buffer.len, run.sink });
    try w.print("{s:<10} {s:>9} {s:>9}\n", .{ "pass", "median us", "p99 us" });
    for (names, samples[0..names.len], 0..) |name, *s, p| {
        const n = if (p < pass_names.len) built else frames;
        try w.print("{s:<10} {d:9.1} {d:9.1}\n", .{ name, us(s[n / 2]), us(s[n * 99 / 100]) });
    }
    std.mem.sort(u64, poll_samples[0..polls], {}, std.sort.asc(u64));
    try w.print("{s:<10} {d:9.1} {d:9.1}\n", .{ "poll", us(poll_samples[polls / 2]), us(poll_samples[polls * 99 / 100]) });
    if (group >= 0) {
        // Means per built frame. Each read is a syscall: its kernel half is not counted, but it
        // evicts some L1 lines, so short passes carry a few dozen extra misses.
        try w.print("{s:<10}", .{"counters"});
        for (counter_names) |name| try w.print(" {s:>10}", .{name});
        try w.print(" {s:>10} {s:>10}\n", .{ "IPC", "L1D/node" });
        for (pass_names, counter_sums) |name, sums| {
            try w.print("{s:<10}", .{name});
            for (sums) |v| try w.print(" {d:10.0}", .{@as(f64, @floatFromInt(v)) / @as(f64, @floatFromInt(built))});
            const f: [4]f64 = .{ @floatFromInt(sums[0]), @floatFromInt(sums[1]), @floatFromInt(sums[2]), @floatFromInt(@max(built * run.nodes, 1)) };
            try w.print(" {d:10.2} {d:10.2}\n", .{ f[1] / @max(f[0], 1), f[2] / f[3] });
        }
    }
    // The grid scene runs with the rows scene only.
    if (is_rows) {
        try w.print("grid: items={d} frames={d}\n", .{ grid_items, grid_frames });
        for (grid_pass_names, &grid_samples) |name, *s| {
            std.mem.sort(u64, s, {}, std.sort.asc(u64));
            try w.print("{s:<14} {d:9.1} {d:9.1}\n", .{ name, us(s[grid_frames / 2]), us(s[grid_frames * 99 / 100]) });
        }
    }
    // Batch counts of the last frame (src/draw/order.zig): what a GPU back end issues per frame
    // in paint order, after merging across text, and the opaque quads a depth back end draws
    // first in one call.
    const sd_last = run.draw;
    const plain = lcgf.order.counts(sd_last);
    lcgf.order.mergeAcrossText(sd_last);
    const merged = lcgf.order.counts(sd_last);
    lcgf.order.depthOrder(sd_last);
    try w.print("batches   quads={d} text={d} custom={d} merged: quads={d} text={d} custom={d} opaque={d} of {d} quads\n", .{ plain.quads, plain.text, plain.custom, merged.quads, merged.text, merged.custom, sd_last.opaque_len, sd_last.quad_len });
    try w.flush();

    const path = json_path orelse return;
    var json_buf: [4096]u8 = undefined;
    var j = std.Io.Writer.fixed(&json_buf);
    try j.print("{{\"nodes\": {d}, \"texts\": {d}, \"frames\": {d}, \"lanes\": {d}, \"passes\": {{", .{ run.nodes, run.texts, built, lcgf.simd.lanes });
    for (names, samples[0..names.len], 0..) |name, *s, p| {
        const n = if (p < pass_names.len) built else frames;
        try j.print("{s}\n  \"{s}\": {{\"median_us\": {d:.1}, \"p99_us\": {d:.1}}}", .{ if (p == 0) "" else ",", name, us(s[n / 2]), us(s[n * 99 / 100]) });
    }
    if (is_rows) {
        for (grid_pass_names, &grid_samples) |name, *s| {
            try j.print(",\n  \"{s}\": {{\"median_us\": {d:.1}, \"p99_us\": {d:.1}}}", .{ name, us(s[grid_frames / 2]), us(s[grid_frames * 99 / 100]) });
        }
    }
    try j.writeAll("\n}}\n");
    try std.Io.Dir.cwd().writeFile(init.io, .{ .sub_path = path, .data = j.buffered() });
}
