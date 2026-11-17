//! Static paint only: layout is complete before the timers start. Run with
//! zig build ct-paint-bench. Each result is the median of 15 batches of 2,000 frames.
const std = @import("std");
const ui = @import("lcgr");
const DrawList = ui.draw_list.DrawList;
const Spec = ui.spec.Spec;
const batches = 15;
const frames = 2000;

fn tiles(comptime count: usize, comptime mixed: bool) Spec {
    @setEvalBranchQuota(1000 + 20 * count);
    var kids: [count]Spec = undefined;
    for (&kids, 0..) |*k, i| k.* = ui.spec.col(.{
        .size = .{ .px(12), .px(12) },
        .fill = .white,
        .texture = @fromBackingInt(if (mixed) i % 2 else 0),
    }, .{});
    return ui.spec.row(.{ .clip = true, .gap = 3 }, kids);
}

fn push(t: *ui.tree.Tree, comptime spec: Spec, parent: u32) void {
    const i = t.push(parent, .none, &spec.style);
    inline for (spec.children) |c| push(t, c, i);
    t.seal(i);
}

fn ns(start: std.Io.Timestamp, end: std.Io.Timestamp) u64 {
    return @intCast(@divTrunc(start.durationTo(end).toNanoseconds(), frames));
}

fn median(xs: *[batches]u64) u64 {
    std.mem.sort(u64, xs, {}, std.sort.asc(u64));
    return xs[batches / 2];
}

fn run(io: std.Io, w: *std.Io.Writer, buf: []align(64) u8, comptime spec: Spec, name: []const u8, width: f32) !void {
    const P = ui.ct_paint.Paint(spec, .{});
    const L = ui.ct_layout.Layout(spec, .{});
    const State = struct { tint: ui.types.Color };
    const Patch = P.Patches(State, &.{.{ .field = .tint, .node = 1, .target = .fill_rgb }});
    var c: ui.mem.Carver = .{ .buf = buf };
    var tree = ui.tree.Tree.init(&c, P.Cols.node_count);
    var tx = ui.texts.Texts.init(&c, 1);
    var cu = ui.customs.Customs.init(&c, 1);
    var runtime = DrawList.init(&c, P.Cols.node_count, 0, 0);
    var compiled = DrawList.init(&c, P.quad_count, 0, 0);
    var scratch: L.Scratch = undefined;
    var ram: P.Cols.Dynamic = undefined;
    var viewport = [2]f32{ width, 48 };
    std.mem.doNotOptimizeAway(&viewport);
    push(&tree, spec, 0);
    ui.layout.run(&tree, &tx, viewport);
    L.run(&scratch, &ram, viewport);
    var order = P.order;
    const layers: ui.overlay.Layers = .{ .c = .{ .own = &.{}, .layer = &.{}, .order = &order } };
    ui.paint.emitLayered(&tree, &tx, &cu, "", &layers, &runtime);
    P.emit(&ram, &compiled);
    if (!std.mem.eql(u8, runtime.quadBytes(), compiled.quadBytes()) or runtime.cmd_len != compiled.cmd_len)
        return error.DrawListMismatch;

    var rt: [batches]u64 = undefined;
    var ct: [batches]u64 = undefined;
    var patch: [batches]u64 = undefined;
    var state: State = .{ .tint = .white };
    for (&rt, &ct, &patch) |*r, *c_full, *p| {
        const t0 = std.Io.Timestamp.now(io, .awake);
        for (0..frames) |_| {
            ui.paint.emitLayered(&tree, &tx, &cu, "", &layers, &runtime);
            std.mem.doNotOptimizeAway(runtime.quads.ptr);
        }
        const t1 = std.Io.Timestamp.now(io, .awake);
        for (0..frames) |_| {
            P.emit(&ram, &compiled);
            std.mem.doNotOptimizeAway(compiled.quads.ptr);
        }
        const t2 = std.Io.Timestamp.now(io, .awake);
        for (0..frames) |_| {
            var dirty: P.Dirty = .empty;
            state.tint.r +%= 1;
            Patch.apply(.tint, &state, &ram, &compiled, &dirty);
            std.mem.doNotOptimizeAway(&dirty);
            std.mem.doNotOptimizeAway(compiled.quads.ptr);
        }
        const t3 = std.Io.Timestamp.now(io, .awake);
        r.* = ns(t0, t1);
        c_full.* = ns(t1, t2);
        p.* = ns(t2, t3);
    }
    try w.print("{s:<16} {d:>5} {d:>7} {d:>8} {d:>11} {d:>9}\n", .{
        name, P.Cols.node_count, compiled.quad_len, median(&rt), median(&ct), median(&patch),
    });
}

pub fn main(init: std.process.Init) !void {
    var out_buf: [1024]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &out_buf);
    const w = &out.interface;
    const buf = try init.gpa.alignedAlloc(u8, .fromByteUnits(64), 1 << 20);
    defer init.gpa.free(buf);
    try w.writeAll("scene            nodes visible    rt ns comptime ns  patch ns\n");
    try run(init.io, w, buf, tiles(16, true), "mixed", 800);
    try run(init.io, w, buf, tiles(128, false), "solid", 2400);
    try run(init.io, w, buf, tiles(128, false), "clipped", 150);
    try w.flush();
}
