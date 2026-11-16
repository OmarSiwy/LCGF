//! Reuse: signals-driven skipping of unchanged subtrees in the runtime front end (tier 1). A
//! memo remembers where a subtree was built last frame and the stamp of the signals it read;
//! while neither changed, `Frame.reuse` copies its rows from last frame's tree instead of
//! letting the caller build it again. Ported from prototype/ui.zig ("Memos", "Frame.reuse").

const std = @import("std");
const mem = @import("../core/mem.zig");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const none = types.none;
const Id = types.Id;
const Frame = @import("frame.zig").Frame;
const Signal = @import("signals.zig").Signal;
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const Customs = @import("../core/customs.zig").Customs;
const selU = simd.selU;
const andB = simd.andB;
const orB = simd.orB;

/// One row per memoized subtree. See `Frame.reuse`.
pub const Memos = struct {
    len: u32 = 0,
    cap: u32,
    c: Columns,

    pub const Columns = struct {
        id: []u32,
        /// Root row of the subtree in the tree of frame `frame`.
        node: []u32,
        frame: []u32,
        /// `Signals.stamp` of the dependencies the subtree was built from.
        stamp: []u64,
    };

    /// Carves every column from `carver`, `simd.rows(cap)` rows each, so `simd.find` can scan
    /// the id column in whole vectors.
    pub fn init(carver: *mem.Carver, cap: u32) Memos {
        std.debug.assert(cap > 0);
        return .{ .cap = cap, .c = carver.columns(Columns, simd.rows(cap)) };
    }
};

/// Signals-driven skipping. Returns true when the subtree rooted at the node with `id` was
/// copied from last frame, in which case the caller must not build it:
///
///     if (!f.reuse(id, &.{ items.signal })) {
///         _ = f.open(id, style);   // the root must carry the same id
///         ...
///         f.close();
///     }
///
/// A subtree is rebuilt when a dependency changed, when the pointer is over it or holding
/// something in it, and while any spring is moving. Reuse skips building (the caller's code and
/// the column writes); layout and paint still run over the copied rows.
pub fn reuse(f: *Frame, id: Id, deps: []const Signal) bool {
    const ctx = f.ctx;
    const m = &ctx.memos;
    const t = f.tree();
    const prev = f.prevTree();
    const k = @backingInt(id);
    const stamp = ctx.signals.stamp(deps);

    const found = simd.find(m.c.id, m.len, k);
    const is_new = found == none;
    const slot = selU(is_new, @min(m.len, m.cap - 1), found);
    m.len = @min(m.len + @intFromBool(is_new), m.cap);

    // Candidate source rows in last frame's tree. Clamped so the reads are in bounds even when
    // the memo is new or stale; `ok` decides whether they are used.
    const a = @min(m.c.node[slot], prev.cap - 1);
    const b = prev.c.end[a];
    const count = b -% a;
    const ptx = &ctx.texts[ctx.cur ^ 1];
    const pcu = &ctx.customs[ctx.cur ^ 1];
    // Side-list rows are in node order, so a subtree's rows are one range found by rank.
    const k0 = simd.rank(ptx.c.node, ptx.len, a);
    const k1 = simd.rank(ptx.c.node, ptx.len, b);
    const c0 = simd.rank(pcu.c.node, pcu.len, a);
    const c1 = simd.rank(pcu.c.node, pcu.len, b);

    const same_inputs = andB(!is_new, m.c.stamp[slot] == stamp);
    const from_last_frame = andB(m.c.frame[slot] +% 1 == ctx.frame, andB(a < prev.len, prev.c.id[a] == k));
    // Unsigned range tests: (x - a) < count  <=>  a <= x < b.
    const touched = orB((ctx.inter.hot_node -% a) < count, (ctx.inter.active_node -% a) < count);
    // Written as "need <= room" so a stale, oversized `count` cannot overflow.
    const fits = andB(count <= t.cap - t.len, andB(
        (k1 -% k0) <= f.texts().cap - f.texts().len,
        (c1 -% c0) <= ctx.customs[ctx.cur].cap - ctx.customs[ctx.cur].len,
    ));
    const ok = andB(andB(same_inputs, from_last_frame), andB(andB(!touched, fits), ctx.motion == 0));

    // The subtree starts at the next row whether it is copied or rebuilt.
    m.c.id[slot] = k;
    m.c.node[slot] = t.len;
    m.c.frame[slot] = ctx.frame;
    // A rebuild caused by the pointer is followed by one more, so hover and press visuals are
    // not frozen into the copy: the stored stamp cannot match the next frame's.
    m.c.stamp[slot] = stamp ^ @intFromBool(touched);

    // The one coarse branch: copying and rebuilding are different work.
    if (!ok) return false;
    copySubtree(f, a, b, k0, k1, c0, c1);
    return true;
}

/// Appends last frame's rows [a, b) of the tree, [k0, k1) of the texts and [c0, c1) of the
/// customs to this frame's tables, under the open node, and moves every link by how far its
/// target moved (SIMD over the copied rows). The bytes of each text run are copied into this frame's strings.
fn copySubtree(f: *Frame, a: u32, b: u32, k0: u32, k1: u32, c0: u32, c1: u32) void {
    const ctx = f.ctx;
    const t = f.tree();
    const tx = f.texts();
    const cu = &ctx.customs[ctx.cur];
    const prev = f.prevTree();
    const ptx = &ctx.texts[ctx.cur ^ 1];
    const pcu = &ctx.customs[ctx.cur ^ 1];
    const n = t.len;
    const count = b - a;
    const delta = n -% a;

    mem.copyRows(Tree.Columns, &t.c, n, &prev.c, a, count);
    // Rebase links, `lanes` rows per step. The last vector may run past the subtree into rows
    // that are not in use yet; the next push rewrites them. `n + count <= cap`, so it stays
    // inside the padded columns (`simd.rows`).
    const text_shift = simd.u(tx.len -% k0);
    const custom_shift = simd.u(cu.len -% c0);
    const shift = simd.u(delta);
    const nil = simd.u(none);
    var i: usize = n;
    while (i < n + count) : (i += simd.lanes) {
        simd.storeU(t.c.parent, i, simd.loadU(t.c.parent, i) +% shift);
        simd.storeU(t.c.end, i, simd.loadU(t.c.end, i) +% shift);
        const ti = simd.loadU(t.c.text, i);
        simd.storeU(t.c.text, i, @select(u32, ti != nil, ti +% text_shift, ti));
        const ci = simd.loadU(t.c.custom, i);
        simd.storeU(t.c.custom, i, @select(u32, ci != nil, ci +% custom_shift, ci));
    }
    const parent = ctx.stack[ctx.depth - 1];
    t.c.parent[n] = parent;
    t.c.nkids[parent] += t.c.flow[n];
    t.len = n + count;

    const tn = k1 - k0;
    mem.copyRows(Texts.Columns, &tx.c, tx.len, &ptx.c, k0, tn);
    const old_strings = &ctx.strings[ctx.cur ^ 1];
    for (tx.len..tx.len + tn) |r| {
        tx.c.node[r] +%= delta;
        const span = ctx.strings[ctx.cur].add(old_strings.get(.{ .start = tx.c.start[r], .bytes = tx.c.bytes[r] }));
        tx.c.start[r] = span.start;
        tx.c.bytes[r] = span.bytes;
    }
    tx.len += tn;

    const cn = c1 - c0;
    mem.copyRows(Customs.Columns, &cu.c, cu.len, &pcu.c, c0, cn);
    for (cu.len..cu.len + cn) |r| cu.c.node[r] +%= delta;
    cu.len += cn;
}

const testing = std.testing;

test "Memos.init: padded columns carved from the caller's buffer, empty" {
    var raw: [4096]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &raw };
    const m = Memos.init(&carver, 5);
    try testing.expectEqual(@as(u32, 0), m.len);
    try testing.expectEqual(@as(u32, 5), m.cap);
    inline for (.{ m.c.id, m.c.node, m.c.frame }) |col| try testing.expectEqual(simd.rows(5), col.len);
    try testing.expectEqual(simd.rows(5), m.c.stamp.len);
    try testing.expectEqual(none, simd.find(m.c.id, m.len, 0));

    // A counting carver sizes the same columns.
    var counter: mem.Carver = .{ .buf = null };
    _ = Memos.init(&counter, 5);
    try testing.expectEqual(carver.off, counter.off);
}

const Context = @import("context.zig").Context;
const Input = @import("../core/input.zig").Input;
const Output = @import("context.zig").Output;

/// A context over a static buffer, for tests.
fn Fixture(comptime limits: @import("context.zig").Limits) type {
    return struct {
        var buffer: [Context.requiredBytes(limits)]u8 align(mem.column_align) = undefined;
        fn context() !Context {
            return Context.init(&buffer, limits);
        }
    };
}

const id_panel = Id.from("panel");
const id_item = Id.from("item");
const hot = types.Color.rgb(200, 0, 0);
const cold = types.Color.rgb(0, 0, 200);

/// `lead` anonymous leaves, then a reusable panel holding a hoverable item, `items` labels and
/// a custom draw, then a trailing label. `builds` counts the frames that built the panel.
const Scene = struct {
    lead: u32 = 0,
    items: u32 = 2,
    sig: Signal,
    builds: u32 = 0,

    fn frame(s: *Scene, ctx: *Context, in: *const Input) Output {
        var f = ctx.begin(in);
        _ = f.open(.from("body"), .{ .dir = .x, .size = .{ .fill, .fill } });
        for (0..s.lead) |_| _ = f.leaf(.none, .{ .size = .{ .px(10), .px(10) } });
        if (!f.reuse(id_panel, &.{s.sig})) {
            s.builds += 1;
            _ = f.open(id_panel, .{ .size = .{ .px(100), .fill }, .pad = @splat(4), .gap = 2 });
            const item = f.leaf(id_item, .{ .size = .{ .fill, .px(20) } });
            const r = f.interact(item, .button);
            f.setFill(item, if (r.hovered) hot else cold);
            var name: [16]u8 = undefined;
            for (0..s.items) |i| _ = f.text(std.fmt.bufPrint(&name, "row {d}", .{i}) catch "?", .{ .px = 10 });
            _ = f.custom(.from("swatch"), .{ .size = .{ .px(8), .px(8) } }, 9);
            f.close();
        }
        _ = f.text("tail", .{ .px = 10 });
        f.close();
        return f.end(.{});
    }
};

/// Every run's bytes, in order, joined by '|'.
fn runText(out: Output, ctx: *const Context, buf: []u8) []const u8 {
    var w = std.Io.Writer.fixed(buf);
    for (0..out.texts.len) |k| {
        const s = ctx.strings[ctx.cur].get(.{ .start = out.texts.c.start[k], .bytes = out.texts.c.bytes[k] });
        w.print("{s}|", .{s}) catch {};
    }
    return w.buffered();
}

test "reuse: unchanged signals copy the subtree; a changed one rebuilds it once" {
    const Fx = Fixture(.{ .nodes = 32, .texts = 16, .customs = 4, .strings = 512, .signals = 4, .memos = 4, .depth = 8 });
    var ctx = try Fx.context();
    var s: Scene = .{ .sig = ctx.signals.create() };
    const in: Input = .{ .viewport = .{ 400, 300 } };

    var out = s.frame(&ctx, &in);
    try testing.expectEqual(@as(u32, 1), s.builds);
    const rect = out.tree.rect(out.tree.find(id_item));
    const len = out.tree.len;
    var b0: [128]u8 = undefined;
    const want = try testing.allocator.dupe(u8, runText(out, &ctx, &b0));
    defer testing.allocator.free(want);
    try testing.expectEqualStrings("row 0|row 1|tail|", want);

    for (0..3) |_| {
        out = s.frame(&ctx, &in);
        try testing.expectEqual(@as(u32, 1), s.builds);
        try testing.expectEqual(len, out.tree.len);
        try testing.expectEqual(rect, out.tree.rect(out.tree.find(id_item)));
        try testing.expectEqualStrings(want, runText(out, &ctx, &b0));
        try testing.expectEqual(@as(u32, 1), out.draw.custom_len);
        try testing.expect(out.status.ok());
    }

    s.items = 4;
    ctx.signals.touch(s.sig);
    out = s.frame(&ctx, &in);
    try testing.expectEqual(@as(u32, 2), s.builds);
    try testing.expectEqualStrings("row 0|row 1|row 2|row 3|tail|", runText(out, &ctx, &b0));
    out = s.frame(&ctx, &in);
    try testing.expectEqual(@as(u32, 2), s.builds);
    try testing.expectEqualStrings("row 0|row 1|row 2|row 3|tail|", runText(out, &ctx, &b0));
}

test "reuse: a copy moved to other rows has its links rebased" {
    const Fx = Fixture(.{ .nodes = 32, .texts = 16, .customs = 4, .strings = 512, .signals = 4, .memos = 4, .depth = 8 });
    var ctx = try Fx.context();
    var s: Scene = .{ .sig = ctx.signals.create(), .lead = 1 };
    const in: Input = .{ .viewport = .{ 400, 300 } };
    _ = s.frame(&ctx, &in);
    // Three more leaves before the panel: it lands 3 rows later, its runs and custom do not move.
    s.lead = 4;
    const out = s.frame(&ctx, &in);
    try testing.expectEqual(@as(u32, 1), s.builds);
    const t = out.tree;
    const p = t.find(id_panel);
    try testing.expectEqual(@as(u32, 2 + 4), p);
    try testing.expectEqual(@as(u32, 1), t.c.parent[p]);
    try testing.expectEqual(p, t.c.parent[t.find(id_item)]);
    try testing.expectEqual(p + 5, t.c.end[p]);
    try testing.expectEqual(t.c.end[p], t.c.end[t.c.end[p] - 1]);
    for (0..out.texts.len) |k| try testing.expectEqual(@as(u32, @intCast(k)), t.c.text[out.texts.c.node[k]]);
    const cu = &ctx.customs[ctx.cur];
    try testing.expectEqual(@as(u32, 1), cu.len);
    try testing.expectEqual(@as(u32, 0), t.c.custom[cu.c.node[0]]);
    try testing.expectEqual(@backingInt(Id.from("swatch")), t.c.id[cu.c.node[0]]);
    // The body counts the panel once.
    try testing.expectEqual(@as(f32, 4 + 2), t.c.nkids[1]);
    // Layout ran over the copy: the panel sits after four 10 px leaves.
    try testing.expectEqual(@as(f32, 40), t.rect(p).x0);
}

test "reuse: the pointer over the subtree forces a rebuild" {
    const Fx = Fixture(.{ .nodes = 32, .texts = 16, .customs = 4, .strings = 512, .signals = 4, .memos = 4, .depth = 8 });
    var ctx = try Fx.context();
    var s: Scene = .{ .sig = ctx.signals.create() };
    var in: Input = .{ .viewport = .{ 400, 300 } };
    var out = s.frame(&ctx, &in);
    _ = s.frame(&ctx, &in);
    try testing.expectEqual(@as(u32, 1), s.builds);
    const r = out.tree.rect(out.tree.find(id_item));
    in.pointer = .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
    out = s.frame(&ctx, &in);
    try testing.expectEqual(@as(u32, 2), s.builds);
    out = s.frame(&ctx, &in);
    try testing.expectEqual(@as(u32, 3), s.builds);
}

test "reuse: after the pointer leaves, one more rebuild clears the hover, then reuse resumes" {
    const Fx = Fixture(.{ .nodes = 32, .texts = 16, .customs = 4, .strings = 512, .signals = 4, .memos = 4, .depth = 8 });
    var ctx = try Fx.context();
    var s: Scene = .{ .sig = ctx.signals.create() };
    var in: Input = .{ .viewport = .{ 400, 300 } };
    var out = s.frame(&ctx, &in);
    const r = out.tree.rect(out.tree.find(id_item));
    in.pointer = .{ (r.x0 + r.x1) * 0.5, (r.y0 + r.y1) * 0.5 };
    _ = s.frame(&ctx, &in);
    out = s.frame(&ctx, &in);
    try testing.expectEqual(hot.bitsOf(), out.tree.c.look[out.tree.find(id_item)].fill);
    const hovering = s.builds;

    in.pointer = .{ 390, 290 };
    // Nothing in the subtree is touched now, but the copy would carry the hover colour: the
    // memo of a touched build never matches, so this frame rebuilds once.
    out = s.frame(&ctx, &in);
    try testing.expectEqual(hovering + 1, s.builds);
    try testing.expectEqual(cold.bitsOf(), out.tree.c.look[out.tree.find(id_item)].fill);
    for (0..3) |_| out = s.frame(&ctx, &in);
    try testing.expectEqual(hovering + 1, s.builds);
    try testing.expectEqual(cold.bitsOf(), out.tree.c.look[out.tree.find(id_item)].fill);
}

test "reuse: no room for the copy means a rebuild, never an overflow" {
    const Fx = Fixture(.{ .nodes = 32, .texts = 16, .customs = 4, .strings = 512, .signals = 4, .memos = 1, .depth = 8 });
    var ctx = try Fx.context();
    var s: Scene = .{ .sig = ctx.signals.create(), .lead = 2 };
    const in: Input = .{ .viewport = .{ 400, 300 } };
    _ = s.frame(&ctx, &in);
    // 26 leaves before the panel: 1 + 1 + 26 + 5 rows do not fit in 32.
    s.lead = 26;
    const out = s.frame(&ctx, &in);
    try testing.expectEqual(@as(u32, 2), s.builds);
    try testing.expect(out.status.nodes);
}
