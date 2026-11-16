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
const Context = @import("context.zig").Context;
const Signal = @import("signals.zig").Signal;
const Tree = @import("../core/tree.zig").Tree;
const Texts = @import("../core/texts.zig").Texts;
const Customs = @import("../core/customs.zig").Customs;
const incremental = @import("../layout/incremental.zig");
const selU = simd.selU;
const andB = simd.andB;
const orB = simd.orB;

/// One row per memoized subtree. See `Frame.reuse`.
pub const Memos = struct {
    len: u32 = 0,
    cap: u32,
    c: Columns,
    /// Root rows of this frame's copies whose layout `Frame.end` can skip
    /// (`incremental.keepable`), ascending. Emptied by `Context.begin`.
    kept: []u32,
    kept_len: u32 = 0,

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
        return .{ .cap = cap, .c = carver.columns(Columns, simd.rows(cap)), .kept = carver.slice(u32, simd.rows(cap)) };
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
/// something in it, and while a spring or tween asked for inside it (after its `open`) is
/// moving; animations elsewhere do not stop the copy. A copy keeps its animations alive, so a
/// spring at rest inside it still starts from where it is when the subtree is next built.
/// Reuse skips building (the caller's code and the column writes); layout and paint still run
/// over the copied rows.
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
    // The extras rows too (row 0, the defaults, has node 0 and is never in a reused range).
    const x0 = simd.rank(prev.x.node, prev.xlen, a);
    const x1 = simd.rank(prev.x.node, prev.xlen, b);

    const same_inputs = andB(!is_new, m.c.stamp[slot] == stamp);
    const from_last_frame = andB(m.c.frame[slot] +% 1 == ctx.frame, andB(a < prev.len, prev.c.id[a] == k));
    // Unsigned range tests: (x - a) < count  <=>  a <= x < b.
    const touched = orB((ctx.inter.hot_node -% a) < count, (ctx.inter.active_node -% a) < count);
    // Written as "need <= room" so a stale, oversized `count` cannot overflow.
    const fits = andB(andB(count <= t.cap - t.len, (x1 -% x0) <= t.cap + 1 - t.xlen), andB(
        (k1 -% k0) <= f.texts().cap - f.texts().len,
        (c1 -% c0) <= ctx.customs[ctx.cur].cap - ctx.customs[ctx.cur].len,
    ));
    const busy = moving(ctx, a, count);
    const ok = andB(andB(same_inputs, from_last_frame), andB(andB(!touched, fits), !busy));

    // The subtree starts at the next row whether it is copied or rebuilt.
    m.c.id[slot] = k;
    m.c.node[slot] = t.len;
    m.c.frame[slot] = ctx.frame;
    // A rebuild caused by the pointer or by a moving animation is followed by one more, so
    // hover and press visuals, and an animation's next-to-last value, are not frozen into the
    // copy: the stored stamp cannot match the next frame's.
    m.c.stamp[slot] = stamp ^ @intFromBool(orB(touched, busy));

    // The one coarse branch: copying and rebuilding are different work.
    if (!ok) return false;
    copySubtree(f, a, b, .{ k0, k1 }, .{ c0, c1 }, .{ x0, x1 });
    return true;
}

/// Appends last frame's rows [a, b) of the tree, `ks` of the texts, `cs` of the customs and
/// `xs` of the tree's extras to this frame's tables, under the open node, and moves every link
/// by how far its target moved (SIMD over the copied rows). The bytes of each text run are
/// copied into this frame's strings.
fn copySubtree(f: *Frame, a: u32, b: u32, ks: [2]u32, cs: [2]u32, xs: [2]u32) void {
    const k0, const k1 = ks;
    const c0, const c1 = cs;
    const x0, const x1 = xs;
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

    // Not the layout scratch: both generations share it, and layout rewrites it.
    mem.copyRowsExcept(Tree.Columns, &t.c, n, &prev.c, a, count, &Tree.scratch);
    // Rebase links, `lanes` rows per step. The last vector may run past the subtree into rows
    // that are not in use yet; the next push rewrites them. `n + count <= cap`, so it stays
    // inside the padded columns (`simd.rows`).
    const text_shift = simd.u(tx.len -% k0);
    const custom_shift = simd.u(cu.len -% c0);
    const shift = simd.u(delta);
    const nil = simd.u(none);
    const parent = ctx.stack[ctx.depth - 1];
    // Extras links: a row of the copied range moves with it; anything else (row 0 or an
    // ancestor's row last frame) becomes the new parent's scope.
    const extra_shift = simd.u(t.xlen -% x0);
    const extra_from = simd.u(x0);
    const extra_count = simd.u(x1 - x0);
    const up_scope = simd.u(t.c.scope[parent]);
    const zero = simd.u(0);
    var i: usize = n;
    while (i < n + count) : (i += simd.lanes) {
        simd.storeU(t.c.parent, i, simd.loadU(t.c.parent, i) +% shift);
        simd.storeU(t.c.end, i, simd.loadU(t.c.end, i) +% shift);
        const ti = simd.loadU(t.c.text, i);
        simd.storeU(t.c.text, i, @select(u32, ti != nil, ti +% text_shift, ti));
        const ci = simd.loadU(t.c.custom, i);
        simd.storeU(t.c.custom, i, @select(u32, ci != nil, ci +% custom_shift, ci));
        const xi = simd.loadU(t.c.extra, i);
        simd.storeU(t.c.extra, i, @select(u32, xi != zero, xi +% extra_shift, zero));
        const si = simd.loadU(t.c.scope, i);
        simd.storeU(t.c.scope, i, @select(u32, (si -% extra_from) < extra_count, si +% extra_shift, up_scope));
    }
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

    const xn = x1 - x0;
    mem.copyRows(Tree.Extras, &t.x, t.xlen, &prev.x, x0, xn);
    for (t.xlen..t.xlen + xn) |r| t.x.node[r] +%= delta;
    t.xlen += xn;

    keepAlive(ctx, a, count, delta);

    // Layout can skip the copy's interior if its root is a relayout boundary. Written always,
    // counted only when keepable; past `cap` the last entry is replaced, and a subtree left
    // off the list is simply laid out.
    const m = &ctx.memos;
    m.kept[@min(m.kept_len, m.cap - 1)] = n;
    m.kept_len = @min(m.kept_len + @intFromBool(incremental.keepable(t, n)), m.cap);
}

/// SIMD. Whether a spring or tween asked for last frame from inside last frame's rows
/// [a, a + count) is still moving. A spring at rest sits exactly on its target with no
/// velocity (`Anims.step` snaps it there); a tween is moving until its leg's time is up.
fn moving(ctx: *const Context, a: u32, count: u32) bool {
    const last = simd.u(ctx.frame -% 1);
    const lo = simd.u(a);
    const n = simd.u(count);
    var any: simd.B = @splat(false);
    const an = &ctx.anims.c;
    var i: usize = 0;
    while (i < simd.padded(ctx.anims.len)) : (i += simd.lanes) {
        const inside = (simd.loadU(an.seen, i) == last) & ((simd.loadU(an.node, i) -% lo) < n);
        const busy = (simd.loadF(an.x, i) != simd.loadF(an.target, i)) | (simd.loadF(an.v, i) != simd.f(0));
        any |= inside & busy;
    }
    const tw = &ctx.tweens.c;
    i = 0;
    while (i < simd.padded(ctx.tweens.len)) : (i += simd.lanes) {
        const inside = (simd.loadU(tw.seen, i) == last) & ((simd.loadU(tw.node, i) -% lo) < n);
        any |= inside & (simd.loadF(tw.elapsed, i) < simd.loadF(tw.duration, i));
    }
    return @reduce(.Or, any);
}

/// SIMD. Marks the springs and tweens of a copied subtree as asked for this frame, at their
/// copied rows, as building it would have: `sweep` keeps them, and the next build finds them
/// where they were instead of starting a new one at its target.
fn keepAlive(ctx: *Context, a: u32, count: u32, delta: u32) void {
    const last = simd.u(ctx.frame -% 1);
    const now = simd.u(ctx.frame);
    const lo = simd.u(a);
    const n = simd.u(count);
    const shift = simd.u(delta);
    inline for (.{ &ctx.anims, &ctx.tweens }) |table| {
        const c = &table.c;
        var i: usize = 0;
        while (i < simd.padded(table.len)) : (i += simd.lanes) {
            const seen = simd.loadU(c.seen, i);
            const node = simd.loadU(c.node, i);
            const inside = (seen == last) & ((node -% lo) < n);
            simd.storeU(c.seen, i, @select(u32, inside, now, seen));
            simd.storeU(c.node, i, @select(u32, inside, node +% shift, node));
        }
    }
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
    /// Target of a spring outside the panel, and of one inside it; the inner one's last value.
    outer: f32 = 0,
    inner: f32 = 0,
    inner_x: f32 = 0,
    /// A px panel on both axes: a relayout boundary, so its copies skip layout.
    fixed: bool = false,

    fn frame(s: *Scene, ctx: *Context, in: *const Input) Output {
        var f = ctx.begin(in);
        _ = f.animate(.from("outer"), s.outer, .{});
        _ = f.open(.from("body"), .{ .dir = .x, .size = .{ .fill, .fill } });
        for (0..s.lead) |_| _ = f.leaf(.none, .{ .size = .{ .px(10), .px(10) } });
        if (!f.reuse(id_panel, &.{s.sig})) {
            s.builds += 1;
            const tall: types.Size = if (s.fixed) .px(120) else .fill;
            _ = f.open(id_panel, .{ .size = .{ .px(100), tall }, .pad = @splat(4), .gap = 2 });
            s.inner_x = f.animate(.from("inner"), s.inner, .{});
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

test "reuse: springs moving outside the subtree do not stop the copy" {
    const Fx = Fixture(.{ .nodes = 32, .texts = 16, .customs = 4, .strings = 512, .signals = 4, .memos = 4, .depth = 8 });
    var ctx = try Fx.context();
    var s: Scene = .{ .sig = ctx.signals.create() };
    const in: Input = .{ .viewport = .{ 400, 300 }, .dt = 1.0 / 60.0 };
    _ = s.frame(&ctx, &in);
    s.outer = 100;
    var frames: u32 = 0;
    var out = s.frame(&ctx, &in);
    while (out.wake == 0 and frames < 600) : (frames += 1) out = s.frame(&ctx, &in);
    // The outer spring moved for many frames; the panel was built once.
    try testing.expect(frames > 5 and frames < 600);
    try testing.expectEqual(@as(u32, 1), s.builds);
    try testing.expectEqual(@as(u32, 2), ctx.anims.len);
}

test "reuse: a spring moving inside the subtree rebuilds it until it lands, then survives copies" {
    const Fx = Fixture(.{ .nodes = 32, .texts = 16, .customs = 4, .strings = 512, .signals = 4, .memos = 4, .depth = 8 });
    var ctx = try Fx.context();
    var s: Scene = .{ .sig = ctx.signals.create() };
    const in: Input = .{ .viewport = .{ 400, 300 }, .dt = 1.0 / 60.0 };
    _ = s.frame(&ctx, &in);
    // The inner target is read by the build, so it changes with the signal.
    s.inner = 50;
    ctx.signals.touch(s.sig);
    var frames: u32 = 0;
    var out = s.frame(&ctx, &in);
    while (out.wake == 0 and frames < 600) : (frames += 1) out = s.frame(&ctx, &in);
    try testing.expectEqual(@as(f32, 50), s.inner_x);
    // Every frame of the movement rebuilt the panel: its spring's value is fresh each frame.
    try testing.expect(s.builds > frames);
    const settled = s.builds;
    for (0..5) |_| _ = s.frame(&ctx, &in);
    try testing.expectEqual(settled, s.builds);
    // Copies kept the resting spring: a new target eases from 50, not jumps to it.
    try testing.expectEqual(@as(u32, 2), ctx.anims.len);
    s.inner = 0;
    ctx.signals.touch(s.sig);
    _ = s.frame(&ctx, &in);
    try testing.expectEqual(@as(f32, 50), s.inner_x);
    _ = s.frame(&ctx, &in);
    try testing.expect(s.inner_x > 0 and s.inner_x < 50);
}

test "reuse: a copy behind a relayout boundary skips layout and lands where a rebuild would" {
    const Fx = Fixture(.{ .nodes = 32, .texts = 16, .customs = 4, .strings = 512, .signals = 4, .memos = 4, .depth = 8 });
    var ctx = try Fx.context();
    var s: Scene = .{ .sig = ctx.signals.create(), .fixed = true };
    const in: Input = .{ .viewport = .{ 400, 300 } };
    _ = s.frame(&ctx, &in);
    try testing.expectEqual(@as(u32, 0), ctx.memos.kept_len);
    var out = s.frame(&ctx, &in);
    try testing.expectEqual(@as(u32, 1), s.builds);
    try testing.expectEqual(@as(u32, 1), ctx.memos.kept_len);
    try testing.expectEqual(out.tree.find(id_panel), ctx.memos.kept[0]);

    // Three 10 px leaves before it move the panel right by 30 px, then it stays: copied and
    // kept each time, placed again only when it moved.
    for ([_]u32{ 0, 3, 3 }) |lead| {
        s.lead = lead;
        out = s.frame(&ctx, &in);
        try testing.expectEqual(@as(u32, 1), s.builds);
        try testing.expectEqual(@as(u32, 1), ctx.memos.kept_len);
        const copied = out.tree.rect(out.tree.find(id_item));
        const copied_text = out.texts.c.avail[0];
        // The same frame built from scratch.
        ctx.signals.touch(s.sig);
        out = s.frame(&ctx, &in);
        try testing.expectEqual(@as(u32, 0), ctx.memos.kept_len);
        try testing.expectEqual(out.tree.rect(out.tree.find(id_item)), copied);
        try testing.expectEqual(out.texts.c.avail[0], copied_text);
        try testing.expectEqual(@as(f32, @floatFromInt(10 * lead)), out.tree.rect(out.tree.find(id_panel)).x0);
        s.builds = 1;
    }

    // A panel that is not a boundary is copied but laid out.
    s.fixed = false;
    ctx.signals.touch(s.sig);
    _ = s.frame(&ctx, &in);
    _ = s.frame(&ctx, &in);
    try testing.expectEqual(@as(u32, 0), ctx.memos.kept_len);
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

/// A faded body around a lead of `lead` bordered leaves and a reusable panel holding a faded,
/// turned item and a rounded, clipping box: every kind of extras row and scope link.
fn extrasFrame(ctx: *Context, in: *const Input, lead: u32, sig: Signal, builds: *u32) Output {
    var f = ctx.begin(in);
    _ = f.open(.from("body"), .{ .dir = .x, .size = .{ .fill, .fill }, .opacity = 0.5 });
    for (0..lead) |_| _ = f.leaf(.none, .{ .size = .{ .px(10), .px(10) }, .border = 1, .fill = hot });
    if (!f.reuse(id_panel, &.{sig})) {
        builds.* += 1;
        // The panel and its first leaf have no row: they take the body's scope.
        _ = f.open(id_panel, .{ .size = .{ .px(100), .px(80) }, .fill = cold });
        _ = f.leaf(.none, .{ .size = .{ .px(20), .px(20) }, .fill = cold });
        _ = f.leaf(.none, .{ .size = .{ .px(20), .px(20) }, .opacity = 0.5, .transform = .{ 0, 1, -1, 0, 0, 0 }, .fill = hot });
        _ = f.open(.none, .{ .size = .{ .px(40), .px(40) }, .clip = true, .radius = 6, .border = 2, .fill = cold });
        _ = f.leaf(.none, .{ .size = .{ .px(60), .px(60) }, .fill = hot });
        f.close();
        f.close();
    }
    _ = f.leaf(.none, .{ .size = .{ .px(10), .px(10) }, .fill = hot });
    f.close();
    return f.end(.{});
}

test "reuse: a copied subtree keeps its extras rows and inherits from its new place" {
    const limits: @import("context.zig").Limits = .{ .nodes = 32, .texts = 4, .customs = 2, .strings = 64, .signals = 2, .memos = 2, .depth = 8 };
    const Fx = Fixture(limits);
    var ctx = try Fx.context();
    const sig = ctx.signals.create();
    const in: Input = .{ .viewport = .{ 400, 300 } };
    var builds: u32 = 0;
    _ = extrasFrame(&ctx, &in, 0, sig, &builds);
    // The copy lands one row and one extras row later than it was built.
    const out = extrasFrame(&ctx, &in, 1, sig, &builds);
    try testing.expectEqual(@as(u32, 1), builds);

    // The same frame built from scratch in a second context.
    const Gx = struct {
        var buffer: [Context.requiredBytes(limits)]u8 align(mem.column_align) = undefined;
    };
    var fresh = try Context.init(&Gx.buffer, limits);
    var fresh_builds: u32 = 0;
    const want = extrasFrame(&fresh, &in, 1, fresh.signals.create(), &fresh_builds);
    try testing.expectEqual(want.draw.quad_len, out.draw.quad_len);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(want.draw.quads[0..want.draw.quad_len]), std.mem.sliceAsBytes(out.draw.quads[0..out.draw.quad_len]));
}
