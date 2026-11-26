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
    /// The matching root rows in the previous generation, for finalization guards.
    kept_source: []u32,
    kept_len: u32 = 0,

    pub const Columns = struct {
        id: []u32,
        /// Root row of the subtree in the tree of frame `frame`.
        node: []u32,
        frame: []u32,
        /// `Signals.stamp` of the dependencies the subtree was built from.
        stamp: []u64,
        /// Focus identity and focus-visible state used by the last build/copy.
        focus: []u64,
    };

    /// Carves every column from `carver`, `simd.rows(cap)` rows each, so `simd.find` can scan
    /// the id column in whole vectors.
    pub fn init(carver: *mem.Carver, cap: u32) Memos {
        std.debug.assert(cap > 0);
        return .{
            .cap = cap,
            .c = carver.columns(Columns, simd.rows(cap)),
            .kept = carver.slice(u32, simd.rows(cap)),
            .kept_source = carver.slice(u32, simd.rows(cap)),
        };
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
/// moving; animations elsewhere do not stop the copy. Keyboard/text/touch events conservatively
/// rebuild all memos, and a changed focus identity or ring state rebuilds their focus visuals.
/// An active text-input subtree rebuilds to republish the current IME/caret host request.
/// A copy preserves declared focus scopes and keeps animations and pending timers alive. A
/// timer due inside the subtree rebuilds it so the request can fire and update the application.
/// Reuse skips building (the caller's code and the column writes); layout and paint still run
/// over the copied rows.
pub fn reuse(f: *Frame, id: Id, deps: []const Signal) bool {
    const ctx = f.ctx;
    const m = &ctx.memos;
    const t = f.tree();
    const prev = f.prevTree();
    const k = @backingInt(id);
    const stamp = ctx.signals.stamp(deps);
    const focus_state = @as(u64, ctx.inter.focus) | (@as(u64, @intFromBool(ctx.focus.visible)) << 32);

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
    const k0, const k1 = rangeRanks(ptx.c.node, ptx.len, a, b);
    const c0, const c1 = rangeRanks(pcu.c.node, pcu.len, a, b);
    // The extras rows too (row 0, the defaults, has node 0 and is never in a reused range).
    const x0, const x1 = rangeRanks(prev.x.node, prev.xlen, a, b);

    const same_inputs = andB(andB(!is_new, m.c.stamp[slot] == stamp), m.c.focus[slot] == focus_state);
    const complete = !orB(orB(prev.overflow, ptx.overflow), orB(pcu.overflow, ctx.strings[ctx.cur ^ 1].overflow));
    const from_last_frame = andB(complete, andB(m.c.frame[slot] +% 1 == ctx.frame, andB(a < prev.len, prev.c.id[a] == k)));
    // Unsigned range tests: (x - a) < count  <=>  a <= x < b.
    const pointer = orB((ctx.inter.hot_node -% a) < count, (ctx.inter.active_node -% a) < count);
    const text_input = (ctx.text_input_node -% a) < count;
    // Key handlers and shortcuts are application code: skipping their build would swallow
    // input. A conservative coarse guard also handles raw held-key and gesture consumers.
    const held: @Vector(4, u64) = f.in.keys.bits;
    const events = orB(f.in.events.len | f.in.text.len | f.in.contacts.len != 0, @reduce(.Or, held) != 0);
    const scroll: @Vector(4, f32) = .{ f.in.wheel[0], f.in.wheel[1], f.in.scroll[0], f.in.scroll[1] };
    const touched = orB(orB(pointer, text_input), orB(events, @reduce(.Or, scroll != @as(@Vector(4, f32), @splat(0)))));
    // Written as "need <= room" so a stale, oversized `count` cannot overflow.
    const fits = andB(andB(count <= t.cap - t.len, (x1 -% x0) <= t.cap + 1 - t.xlen), andB(
        (k1 -% k0) <= f.texts().cap - f.texts().len,
        (c1 -% c0) <= ctx.customs[ctx.cur].cap - ctx.customs[ctx.cur].len,
    ));
    const busy = moving(ctx, a, count, f.in.time);
    // Collapsing masks layout inputs while building. A parent participation change must
    // rebuild original inputs instead of reviving rows whose stored dimensions were zeroed.
    const new_parent = ctx.stack[ctx.depth - 1];
    const same_participation = @as(u8, @bitCast(t.participation(new_parent))) == @as(u8, @bitCast(prev.participation(prev.c.parent[a])));
    var references_valid = true;
    if (from_last_frame and fits) {
        for (x0..x1) |r| {
            const source = prev.x.row[r].paint_reference;
            if (source == none or (source >= a and source < b) or source == prev.c.parent[a]) continue;
            references_valid = references_valid and source < prev.len and prev.c.id[@min(source, prev.cap - 1)] != 0;
            if (references_valid) references_valid = t.find(@fromBackingInt(prev.c.id[source])) != none;
        }
    }
    const ok = andB(andB(same_inputs, from_last_frame), andB(andB(!touched, fits), andB(!busy, andB(andB(same_participation, t.cursor(new_parent) == prev.cursor(prev.c.parent[a])), references_valid))));

    // The subtree starts at the next row whether it is copied or rebuilt.
    m.c.id[slot] = k;
    m.c.node[slot] = t.len;
    m.c.frame[slot] = ctx.frame;
    m.c.focus[slot] = focus_state;
    // A rebuild caused by the pointer or by a moving animation is followed by one more, so
    // hover and press visuals, and an animation's next-to-last value, are not frozen into the
    // copy: the stored stamp cannot match the next frame's.
    m.c.stamp[slot] = stamp ^ @intFromBool(orB(touched, busy));

    // The one coarse branch: copying and rebuilding are different work.
    if (!ok) return false;
    copySubtree(f, a, b, .{ k0, k1 }, .{ c0, c1 }, .{ x0, x1 });
    return true;
}

/// Both insertion ranks share the same owner column and live mask. Scan them together;
/// separate rank calls otherwise load every owner twice. Kept inline so the production
/// branch probe measures this loop along with the rest of reuse.
inline fn rangeRanks(nodes: []const u32, len: u32, low: u32, high: u32) [2]u32 {
    var before_low: simd.U = @splat(0);
    var before_high: simd.U = @splat(0);
    var i: usize = 0;
    while (i < simd.padded(len)) : (i += simd.lanes) {
        const live = simd.iota + simd.u(@intCast(i)) < simd.u(len);
        const node = simd.loadU(nodes, i);
        before_low += @intFromBool(live & (node < simd.u(low)));
        before_high += @intFromBool(live & (node < simd.u(high)));
    }
    return .{ @reduce(.Add, before_low), @reduce(.Add, before_high) };
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
    var scope_bits: simd.Bytes = @splat(0);
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
        const live = simd.iota + simd.u(@intCast(i - n)) < simd.u(count);
        const kinds: simd.Bytes = ctx.previous_scope_kind[a + i - n ..][0..simd.lanes].*;
        const copied = @select(u8, live, kinds, @as(simd.Bytes, @splat(0)));
        ctx.scopes.c.kind[i..][0..simd.lanes].* = copied;
        scope_bits |= copied;
    }
    ctx.scoped = orB(ctx.scoped, @reduce(.Or, scope_bits) != 0);
    t.c.parent[n] = parent;
    t.c.nkids[parent] += t.c.flow[n];
    t.len = n + count;

    const tn = k1 - k0;
    mem.copyRows(Texts.Columns, &tx.c, tx.len, &ptx.c, k0, tn);
    copyTextBytes(ctx, tx, tn, delta);
    tx.len += tn;

    const cn = c1 - c0;
    mem.copyRows(Customs.Columns, &cu.c, cu.len, &pcu.c, c0, cn);
    rebaseNodes(cu.c.node, cu.len, cn, delta);
    cu.len += cn;

    const xn = x1 - x0;
    mem.copyRows(Tree.Extras, &t.x, t.xlen, &prev.x, x0, xn);
    rebaseNodes(t.x.node, t.xlen, xn, delta);
    for (t.xlen..t.xlen + xn) |r| {
        const source = t.x.row[r].paint_reference;
        if (source != none) t.x.row[r].paint_reference = if (source >= a and source < b) source +% delta else if (source == prev.c.parent[a]) parent else t.find(@fromBackingInt(prev.c.id[source]));
    }
    t.xlen += xn;

    keepAlive(ctx, a, count, delta);

    // Layout can skip the copy's interior if its root is a relayout boundary. Written always,
    // counted only when keepable; past `cap` the last entry is replaced, and a subtree left
    // off the list is simply laid out.
    const m = &ctx.memos;
    const kept_slot = @min(m.kept_len, m.cap - 1);
    m.kept[kept_slot] = n;
    m.kept_source[kept_slot] = a;
    m.kept_len = @min(m.kept_len + @intFromBool(incremental.keepable(t, n)), m.cap);
}

/// Appended side-list rows have a spare vector, as the tree columns do. Rebase that padded
/// span directly; future pushes overwrite its unused tail. This avoids a separate scalar
/// remainder loop for small custom/extras lists without changing their live rows.
inline fn rebaseNodes(nodes: []u32, first: u32, count: u32, delta: u32) void {
    var i: usize = first;
    while (i < first + count) : (i += simd.lanes)
        simd.storeU(nodes, i, simd.loadU(nodes, i) +% simd.u(delta));
}

/// Ordinary frame text is appended contiguously. Copy that byte range once and rebase its
/// run columns in vectors; preserve Strings.add's prefix-truncation behavior when capacity
/// is exhausted. Public columns can also describe noncontiguous spans, which retain the
/// original per-run copy path. Padding is masked when checking adjacency.
fn copyTextBytes(ctx: *Context, tx: *Texts, count: u32, delta: u32) void {
    if (count == 0) return;
    const first = tx.len;
    const end = first + count;
    const c = &tx.c;
    var contiguous: simd.B = @splat(true);
    var off: usize = 0;
    while (off < count) : (off += simd.lanes) {
        const row = first + off;
        const adjacent = simd.iota + simd.u(@intCast(off + 1)) < simd.u(count);
        const next = simd.loadU(c.start, row + 1);
        const after = simd.loadU(c.start, row) +% simd.loadU(c.bytes, row);
        contiguous &= !adjacent | (next == after);
    }
    const old = &ctx.strings[ctx.cur ^ 1];
    const now = &ctx.strings[ctx.cur];
    if (!@reduce(.And, contiguous)) {
        for (first..end) |r| {
            c.node[r] +%= delta;
            const span = now.add(old.get(.{ .start = c.start[r], .bytes = c.bytes[r] }));
            c.start[r] = span.start;
            c.bytes[r] = span.bytes;
        }
        return;
    }
    const start = c.start[first];
    const bytes = c.start[end - 1] + c.bytes[end - 1] - start;
    const span = now.add(old.get(.{ .start = start, .bytes = bytes }));
    off = 0;
    while (off < count) : (off += simd.lanes) {
        const row = first + off;
        const relative = simd.loadU(c.start, row) -% simd.u(start);
        const within = @min(relative, simd.u(span.bytes));
        simd.storeU(c.node, row, simd.loadU(c.node, row) +% simd.u(delta));
        simd.storeU(c.start, row, simd.u(span.start) + within);
        simd.storeU(c.bytes, row, @min(simd.loadU(c.bytes, row), simd.u(span.bytes) - within));
    }
}

/// SIMD. Whether a spring or tween asked for last frame from inside last frame's rows
/// [a, a + count) is still moving. A spring at rest sits exactly on its target with no
/// velocity (`Anims.step` snaps it there); a tween is moving until its leg's time is up.
fn moving(ctx: *const Context, a: u32, count: u32, time: f64) bool {
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
    const ti = &ctx.timers.c;
    const now: @Vector(simd.lanes, f64) = @splat(time);
    i = 0;
    while (i < simd.padded(ctx.timers.len)) : (i += simd.lanes) {
        const inside = (simd.loadU(ti.seen, i) == last) & ((simd.loadU(ti.node, i) -% lo) < n);
        const at: @Vector(simd.lanes, f64) = ti.at[i..][0..simd.lanes].*;
        any |= inside & (now >= at);
    }
    return @reduce(.Or, any);
}

/// SIMD. Marks the springs, tweens and timers of a copied subtree as asked for this frame, at their
/// copied rows, as building it would have: `sweep` keeps them, and the next build finds them
/// where they were instead of starting a new one at its target.
fn keepAlive(ctx: *Context, a: u32, count: u32, delta: u32) void {
    const last = simd.u(ctx.frame -% 1);
    const now = simd.u(ctx.frame);
    const lo = simd.u(a);
    const n = simd.u(count);
    const shift = simd.u(delta);
    inline for (.{ &ctx.anims, &ctx.tweens, &ctx.timers }) |table| {
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

test "reuse range ranks match independent ranks with duplicate owners and partial vectors" {
    var nodes: [simd.rows(33)]u32 = @splat(0);
    for (nodes[0..33], 0..) |*node, i| node.* = @intCast(i / 3);
    for (0..34) |n| {
        const len: u32 = @intCast(n);
        for ([_][2]u32{ .{ 0, 0 }, .{ 0, 4 }, .{ 2, 7 }, .{ 10, 11 }, .{ 11, none } }) |bounds| {
            const got = rangeRanks(&nodes, len, bounds[0], bounds[1]);
            try testing.expectEqual(simd.rank(&nodes, len, bounds[0]), got[0]);
            try testing.expectEqual(simd.rank(&nodes, len, bounds[1]), got[1]);
        }
    }
}

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

test "reuse: a canvas in a kept subtree stays a canvas, with its row" {
    const canvas = @import("../draw/canvas.zig");
    const limits: @import("context.zig").Limits = .{ .nodes = 16, .texts = 4, .customs = 4, .strings = 64, .signals = 2, .memos = 2, .depth = 6 };
    const Fx = Fixture(limits);
    var ctx = try Fx.context();
    var rows: [2 * limits.customs]@import("../draw/draw_list.zig").CanvasDraw = undefined;
    ctx.enableCanvas(&rows);
    var buf: [canvas.Instances.requiredBytes(2, 0, 1, .{})]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var shapes: canvas.Instances = .init(&carver, 2, 0, 1, .{});
    _ = shapes.segment(.{ 0, 0 }, .{ 10, 0 }, .{});
    const pal: canvas.Palette = .{ .layers = &.{.of(.{})} };
    const all = [_]canvas.Range{shapes.since(0)};
    const cam: canvas.Camera = .{ .origin = .{ 7, 8 }, .scale = 2 };
    const sig = ctx.signals.create();
    const S = struct {
        builds: u32 = 0,
        lead: u32 = 0,
        fn frame(st: *@This(), c: *Context, in: *const Input, sh: *const canvas.Instances, p: *const canvas.Palette, r: []const canvas.Range, cm: canvas.Camera, dep: Signal) Output {
            var f = c.begin(in);
            _ = f.open(.from("body"), .{ .dir = .x, .size = .{ .fill, .fill } });
            // Custom rows before the panel, so the copy lands on other rows than last frame's.
            for (0..st.lead) |_| _ = f.custom(.none, .{ .size = .{ .px(4), .px(4) } }, 1);
            if (!f.reuse(id_panel, &.{dep})) {
                st.builds += 1;
                _ = f.open(id_panel, .{ .size = .{ .px(100), .px(80) } });
                _ = f.canvas(.from("sheet"), .{ .size = .{ .fill, .fill } }, sh, .{ .camera = cm, .palette = p, .ranges = r });
                f.close();
            }
            f.close();
            return f.end(.{});
        }
    };
    var st: S = .{};
    const in: Input = .{ .viewport = .{ 200, 100 } };
    _ = st.frame(&ctx, &in, &shapes, &pal, &all, cam, sig);
    for (0..3) |lead| {
        st.lead = @intCast(lead);
        const out = st.frame(&ctx, &in, &shapes, &pal, &all, cam, sig);
        try testing.expectEqual(@as(u32, 1), st.builds);
        var found: u32 = 0;
        for (0..out.draw.cmd_len) |i| switch (out.draw.command(@intCast(i))) {
            .canvas => |k| {
                found += 1;
                try testing.expectEqual(&shapes, out.draw.canvases[k].instances);
                try testing.expectEqual(cam, out.draw.canvases[k].camera);
                try testing.expectEqual(@as(f32, 100), out.draw.customs[k].rect[2] - out.draw.customs[k].rect[0]);
            },
            else => {},
        };
        try testing.expectEqual(1, found);
    }
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

const KeyboardScene = struct {
    builds: u32 = 0,
    activated: u32 = 0,

    fn frame(s: *KeyboardScene, ctx: *Context, in: *const Input) Output {
        var f = ctx.begin(in);
        _ = f.open(.from("keyboard-body"), .{ .size = .{ .fill, .fill } });
        if (!f.reuse(id_panel, &.{})) {
            s.builds += 1;
            _ = f.open(id_panel, .{ .size = .{ .px(120), .px(80) } });
            const button = f.leaf(id_item, .{ .size = .{ .px(80), .px(24) } });
            const response = f.interact(button, .button);
            f.setFill(button, if (response.focused) hot else cold);
            for (in.events) |event| {
                if (response.focused and event.kind == .press and event.code == 40) s.activated += 1;
            }
            f.close();
        }
        _ = f.interact(f.leaf(.from("other-button"), .{ .size = .{ .px(80), .px(24) } }), .button);
        f.close();
        return f.end(.{});
    }
};

test "reuse: keyboard activation and programmatic focus changes rebuild with the pointer elsewhere" {
    const Fx = Fixture(.{ .nodes = 16, .texts = 2, .customs = 1, .strings = 64, .signals = 2, .memos = 2, .depth = 8 });
    var ctx = try Fx.context();
    var scene: KeyboardScene = .{};
    var in: Input = .{ .viewport = .{ 400, 300 } };
    _ = scene.frame(&ctx, &in);
    _ = scene.frame(&ctx, &in);
    try testing.expectEqual(1, scene.builds);

    in.events = &.{.{ .kind = .press, .code = ctx.focus.keys.tab }};
    var out = scene.frame(&ctx, &in);
    try testing.expectEqual(@backingInt(id_item), ctx.inter.focus);
    try testing.expectEqual(hot.bitsOf(), out.tree.c.look[out.tree.find(id_item)].fill);
    in.events = &.{.{ .kind = .press, .code = 40 }};
    _ = scene.frame(&ctx, &in);
    try testing.expectEqual(1, scene.activated);
    in.events = &.{};
    _ = scene.frame(&ctx, &in);
    const settled = scene.builds;
    _ = scene.frame(&ctx, &in);
    try testing.expectEqual(settled, scene.builds);

    ctx.inter.focus = @backingInt(Id.from("other-button"));
    out = scene.frame(&ctx, &in);
    try testing.expectEqual(settled + 1, scene.builds);
    try testing.expectEqual(cold.bitsOf(), out.tree.c.look[out.tree.find(id_item)].fill);
    // An event can be a global shortcut even when the focus owner is outside the memo.
    in.events = &.{.{ .kind = .press, .code = 41 }};
    _ = scene.frame(&ctx, &in);
    try testing.expectEqual(settled + 2, scene.builds);
}

test "reuse: idle focused text fields republish their IME state while unrelated subtrees copy" {
    const tf = @import("../widgets/textfield.zig");
    const Theme = @import("../widgets/base.zig").Theme;
    const Fx = Fixture(.{ .nodes = 64, .texts = 4, .customs = 1, .strings = 64, .signals = 2, .memos = 4, .depth = 8 });
    var ctx = try Fx.context();
    const in: Input = .{ .viewport = .{ 400, 300 } };
    const field_id = comptime Id.from("memo-field");
    const S = struct {
        field: tf.Text(32) = .init("hello"),
        builds: u32 = 0,
        other_builds: u32 = 0,

        fn frame(s: *@This(), c: *Context, input: *const Input) Output {
            var f = c.begin(input);
            if (!f.reuse(id_panel, &.{})) {
                s.builds += 1;
                _ = f.open(id_panel, .{ .size = .{ .px(200), .px(80) } });
                _ = tf.textfield(&f, &Theme.default, field_id, &s.field, "");
                f.close();
            }
            if (!f.reuse(.from("other-panel"), &.{})) {
                s.other_builds += 1;
                _ = f.open(.from("other-panel"), .{ .size = .{ .px(80), .px(80) } });
                _ = f.leaf(.none, .{ .size = .{ .px(10), .px(10) }, .fill = cold });
                f.close();
            }
            return f.end(.{});
        }
    };
    var scene: S = .{};
    _ = scene.frame(&ctx, &in);
    _ = scene.frame(&ctx, &in);
    try testing.expectEqual(1, scene.builds);
    ctx.inter.focus = @backingInt(field_id);
    for (0..6) |_| {
        const out = scene.frame(&ctx, &in);
        try testing.expect(out.platform.wants_text);
        try testing.expectEqualStrings("hello", out.platform.surrounding);
        try testing.expectEqual([2]u32{ 5, 5 }, out.platform.selection);
        try testing.expect(out.platform.ime_rect.x0 > 0);
    }
    try testing.expectEqual(7, scene.builds);
    try testing.expectEqual(2, scene.other_builds); // only the focus-state change invalidates it
    ctx.inter.focus = 0;
    _ = scene.frame(&ctx, &in);
    const settled = scene.builds;
    const out = scene.frame(&ctx, &in);
    try testing.expect(!out.platform.wants_text);
    try testing.expectEqual(settled, scene.builds);
}

const ScopedScene = struct {
    builds: u32 = 0,
    lead: u32 = 0,
    show: bool = true,
    kind: u8 = @import("../interact/focus.zig").Scopes.group,

    const before = Id.from("scope-before");
    const a = Id.from("scope-a");
    const b = Id.from("scope-b");
    const after = Id.from("scope-after");

    fn frame(s: *ScopedScene, ctx: *Context, in: *const Input) Output {
        var f = ctx.begin(in);
        _ = f.interact(f.leaf(before, .{ .size = .{ .px(40), .px(20) } }), .button);
        for (0..s.lead) |_| _ = f.leaf(.none, .{ .size = .{ .px(1), .px(1) } });
        if (s.show and !f.reuse(id_panel, &.{})) {
            s.builds += 1;
            const panel = f.open(id_panel, .{ .size = .{ .px(100), .px(80) } });
            f.focusScope(panel, s.kind);
            _ = f.interact(f.leaf(a, .{ .size = .{ .px(40), .px(20) } }), .button);
            _ = f.interact(f.leaf(b, .{ .size = .{ .px(40), .px(20) } }), .button);
            f.close();
        }
        _ = f.interact(f.leaf(after, .{ .size = .{ .px(40), .px(20) } }), .button);
        return f.end(.{});
    }
};

test "reuse: copied focus groups remain one Tab stop after idle frames and row movement" {
    const Fx = Fixture(.{ .nodes = 32, .texts = 2, .customs = 1, .strings = 64, .signals = 2, .memos = 2, .depth = 8 });
    var ctx = try Fx.context();
    var scene: ScopedScene = .{};
    var in: Input = .{ .viewport = .{ 400, 300 } };
    _ = scene.frame(&ctx, &in);
    scene.lead = 3;
    var out = scene.frame(&ctx, &in);
    try testing.expectEqual(1, scene.builds);
    try testing.expectEqual(scene.kind, ctx.scopes.c.kind[out.tree.find(id_panel)]);
    for ([_]Id{ ScopedScene.before, ScopedScene.a, ScopedScene.after, ScopedScene.before }) |want| {
        in.events = &.{};
        _ = scene.frame(&ctx, &in);
        out = scene.frame(&ctx, &in);
        try testing.expectEqual(scene.kind, ctx.scopes.c.kind[out.tree.find(id_panel)]);
        in.events = &.{.{ .kind = .press, .code = ctx.focus.keys.tab }};
        _ = scene.frame(&ctx, &in);
        try testing.expectEqual(@backingInt(want), ctx.inter.focus);
    }
}

test "reuse: copied modal scope keeps trapping focus and closing restores it" {
    const Fx = Fixture(.{ .nodes = 32, .texts = 2, .customs = 1, .strings = 64, .signals = 2, .memos = 2, .depth = 8 });
    var ctx = try Fx.context();
    var scene: ScopedScene = .{ .kind = @import("../interact/focus.zig").Scopes.trap };
    const in: Input = .{ .viewport = .{ 400, 300 } };
    ctx.inter.focus = @backingInt(ScopedScene.before);
    _ = scene.frame(&ctx, &in);
    for (0..6) |i| {
        scene.lead = @intCast(i % 3);
        const out = scene.frame(&ctx, &in);
        try testing.expectEqual(@backingInt(ScopedScene.a), ctx.inter.focus);
        try testing.expectEqual(1, ctx.focus.depth);
        try testing.expectEqual(scene.kind, ctx.scopes.c.kind[out.tree.find(id_panel)]);
    }
    try testing.expectEqual(2, scene.builds); // initial declaration, then focus acquisition
    scene.show = false;
    _ = scene.frame(&ctx, &in);
    _ = scene.frame(&ctx, &in);
    try testing.expectEqual(0, ctx.focus.depth);
    try testing.expectEqual(@backingInt(ScopedScene.before), ctx.inter.focus);
    try testing.expect(!ctx.scoped);
}

const TimedScene = struct {
    builds: u32 = 0,
    fires: u32 = 0,
    lead: u32 = 0,
    mode: @import("scheduler.zig").TimerMode = .repeat,

    fn frame(s: *TimedScene, ctx: *Context, in: *const Input) Output {
        var f = ctx.begin(in);
        _ = f.timer(.from("outside-timer"), 5, .repeat);
        for (0..s.lead) |_| _ = f.leaf(.none, .{ .size = .{ .px(1), .px(1) } });
        if (!f.reuse(id_panel, &.{})) {
            s.builds += 1;
            _ = f.open(id_panel, .{ .size = .{ .px(100), .px(80) } });
            if (s.mode == .repeat or s.fires == 0) {
                if (f.timer(.from("inside-timer"), 0.5, s.mode)) s.fires += 1;
            }
            _ = f.leaf(.none, .{ .size = .{ .px(40), .px(20) }, .fill = if (s.fires & 1 != 0) hot else cold });
            f.close();
        }
        return f.end(.{});
    }
};

test "reuse: pending timers follow moved copies, fire on deadlines and one-shots disappear" {
    const Fx = Fixture(.{ .nodes = 32, .texts = 2, .customs = 1, .strings = 64, .signals = 2, .memos = 2, .timers = 4, .depth = 8 });
    inline for (.{ @import("scheduler.zig").TimerMode.once, .repeat }) |mode| {
        var ctx = try Fx.context();
        var scene: TimedScene = .{ .mode = mode };
        var in: Input = .{ .viewport = .{ 400, 300 }, .time = 10 };
        _ = scene.frame(&ctx, &in);
        in.time = 10.2;
        scene.lead = 3;
        var out = scene.frame(&ctx, &in);
        _ = scene.frame(&ctx, &in);
        try testing.expectEqual(1, scene.builds);
        try testing.expectEqual(2, ctx.timers.len);
        const timer_row = simd.find(ctx.timers.c.id, ctx.timers.len, @backingInt(Id.from("inside-timer")));
        try testing.expectEqual(out.tree.find(id_panel), ctx.timers.c.node[timer_row]);
        try testing.expectApproxEqAbs(@as(f32, 0.3), out.wake, 1e-5);
        in.time = 10.5;
        try testing.expect(ctx.needsFrame(&in));
        out = scene.frame(&ctx, &in);
        try testing.expectEqual(2, scene.builds);
        try testing.expectEqual(1, scene.fires);
        const panel = out.tree.find(id_panel);
        try testing.expectEqual(hot.bitsOf(), out.tree.c.look[panel + 1].fill);
        in.time = 10.6;
        _ = scene.frame(&ctx, &in); // a settle rebuild after the deadline
        const settled = scene.builds;
        _ = scene.frame(&ctx, &in);
        try testing.expectEqual(settled, scene.builds);
        try testing.expectEqual(if (mode == .repeat) @as(u32, 2) else 1, ctx.timers.len);
        in.time = 11;
        _ = scene.frame(&ctx, &in);
        try testing.expectEqual(if (mode == .repeat) @as(u32, 2) else 1, scene.fires);
    }
}

test "reuse: bulk text copy matches prefix truncation and rebuilds after a truncated source" {
    const Fx = Fixture(.{ .nodes = 16, .texts = 4, .customs = 1, .strings = 8, .signals = 2, .memos = 2, .depth = 8 });
    var ctx = try Fx.context();
    const in: Input = .{ .viewport = .{ 400, 300 } };
    const S = struct {
        fn frame(c: *Context, input: *const Input, prefix: []const u8, builds: *u32) Output {
            var f = c.begin(input);
            if (prefix.len > 0) _ = f.text(prefix, .{});
            if (!f.reuse(id_panel, &.{})) {
                builds.* += 1;
                _ = f.open(id_panel, .{ .size = .{ .px(100), .px(80) } });
                _ = f.text("abcd", .{});
                _ = f.text("efg", .{});
                f.close();
            }
            return f.end(.{});
        }
    };
    var builds: u32 = 0;
    _ = S.frame(&ctx, &in, "", &builds);
    var out = S.frame(&ctx, &in, "123456", &builds);
    try testing.expectEqual(1, builds);
    try testing.expect(out.status.strings);
    try testing.expectEqualStrings("123456ab", out.draw.strings);
    try testing.expectEqual(2, out.texts.c.bytes[1]);
    try testing.expectEqual(0, out.texts.c.bytes[2]);
    out = S.frame(&ctx, &in, "", &builds);
    try testing.expectEqual(2, builds);
    try testing.expect(!out.status.strings);
    try testing.expectEqualStrings("abcdefg", out.draw.strings);
}

test "reuse: noncontiguous public text spans retain their per-run copy semantics" {
    const Fx = Fixture(.{ .nodes = 16, .texts = 4, .customs = 1, .strings = 16, .signals = 2, .memos = 2, .depth = 8 });
    var ctx = try Fx.context();
    const in: Input = .{ .viewport = .{ 400, 300 } };
    const S = struct {
        fn frame(c: *Context, input: *const Input, prefix: []const u8, builds: *u32) Output {
            var f = c.begin(input);
            if (prefix.len > 0) _ = f.text(prefix, .{});
            if (!f.reuse(id_panel, &.{})) {
                builds.* += 1;
                _ = f.open(id_panel, .{ .size = .{ .px(100), .px(80) } });
                _ = f.text("abc", .{});
                _ = f.text("defg", .{});
                _ = f.text("h", .{});
                f.close();
            }
            return f.end(.{});
        }
    };
    var builds: u32 = 0;
    _ = S.frame(&ctx, &in, "", &builds);
    // The tables are public: two runs can share bytes and leave a gap before another run.
    const texts = &ctx.texts[ctx.cur];
    texts.c.start[1] = 0;
    texts.c.bytes[1] = 3;
    const out = S.frame(&ctx, &in, "!", &builds);
    try testing.expectEqual(1, builds);
    try testing.expect(out.status.ok());
    try testing.expectEqualStrings("!abcabch", out.draw.strings);
    try testing.expectEqualSlices(u32, &.{ 0, 1, 4, 7 }, out.texts.c.start[0..4]);
    try testing.expectEqualSlices(u32, &.{ 1, 3, 3, 1 }, out.texts.c.bytes[0..4]);
    const panel = out.tree.find(id_panel);
    try testing.expectEqualSlices(u32, &.{ panel + 1, panel + 2, panel + 3 }, out.texts.c.node[1..4]);
}

const FinalizeScene = struct {
    width: f32 = 190,
    height: f32 = 150,
    offset: f32 = 0,
    scroll: f32 = 0,
    opacity: f32 = 1,
    transform: [6]f32 = .{ 1, 0, 0, 1, 0, 0 },
    border: f32 = 1,
    lead: u32 = 0,
    flip: bool = false,

    fn frame(s: *const FinalizeScene, ctx: *Context, in: *const Input, rebuild: bool) Output {
        var f = ctx.begin(in);
        const body = f.open(.from("finalize-body"), .{
            .size = .{ .px(s.width), .px(s.height) },
            .clip = true,
            .border = s.border,
            .offset = .{ s.offset, 0 },
            .scroll = .{ 0, s.scroll },
            .opacity = s.opacity,
            .transform = s.transform,
            .radius = 7,
            .fill = cold,
        });
        if (s.flip) f.animateLayout(body, .{});
        for (0..s.lead) |_| _ = f.leaf(.none, .{ .size = .{ .px(1), .px(1) } });
        if (rebuild or !f.reuse(id_panel, &.{})) {
            _ = f.open(id_panel, .{ .size = .{ .px(180), .px(120) }, .offset = .{ 0.25, 0.25 }, .gap = 0.75 });
            for (0..9) |i| {
                _ = f.open(Id.from("fixed-row").with(@intCast(i)), .{ .size = .{ .fill, .px(17.25) }, .fill = hot, .opacity = 0.75 });
                _ = f.text("fractional label", .{ .px = 11.25 });
                f.close();
            }
            f.close();
        }
        f.close();
        return f.end(.{});
    }
};

fn expectFrameEqual(want: Output, actual: Output) !void {
    const a = want.tree;
    const b = actual.tree;
    try testing.expect(want.status.ok() and actual.status.ok());
    try testing.expectEqual(a.len, b.len);
    inline for (0..4) |axis| {
        try testing.expectEqualSlices(f32, a.c.rect[axis][0..a.len], b.c.rect[axis][0..b.len]);
        try testing.expectEqualSlices(f32, a.c.vis[axis][0..a.len], b.c.vis[axis][0..b.len]);
    }
    try testing.expectEqualSlices([4]f32, a.c.child_clip[0..a.len], b.c.child_clip[0..b.len]);
    try testing.expectEqualSlices(u8, a.c.visible[0..a.len], b.c.visible[0..b.len]);
    try testing.expectEqual(want.draw.quad_len, actual.draw.quad_len);
    try testing.expectEqual(want.draw.run_len, actual.draw.run_len);
    try testing.expectEqual(want.draw.cmd_len, actual.draw.cmd_len);
    try testing.expectEqualSlices(@import("../draw/draw_list.zig").Quad, want.draw.quads[0..want.draw.quad_len], actual.draw.quads[0..actual.draw.quad_len]);
    try testing.expectEqualSlices(@import("../draw/draw_list.zig").TextRun, want.draw.runs[0..want.draw.run_len], actual.draw.runs[0..actual.draw.run_len]);
    try testing.expectEqualStrings(want.draw.strings, actual.draw.strings);
    for (0..want.draw.cmd_len) |i| try testing.expectEqual(want.draw.command(@intCast(i)), actual.draw.command(@intCast(i)));
}

test "reuse finalization matches rebuilding through ancestor clips, transforms, opacity and fractional movement" {
    const limits: @import("context.zig").Limits = .{ .nodes = 64, .texts = 16, .customs = 1, .strings = 512, .signals = 2, .memos = 2, .depth = 8 };
    var buf_a: [Context.requiredBytes(limits)]u8 align(mem.column_align) = undefined;
    var buf_b: [Context.requiredBytes(limits)]u8 align(mem.column_align) = undefined;
    var retained = try Context.init(&buf_a, limits);
    var rebuilt = try Context.init(&buf_b, limits);
    var scene: FinalizeScene = .{};
    var in: Input = .{ .viewport = .{ 400, 300 }, .dt = 1.0 / 60.0 };
    for (0..24) |step| {
        switch (step) {
            2 => scene.height = 70,
            3 => scene.height = 160,
            4 => scene.width = 90,
            5 => scene.width = 200,
            6 => scene.offset = 0.375,
            7 => scene.offset = 0.625,
            8 => scene.scroll = 0.375,
            9 => scene.scroll = 7.5,
            10 => scene.opacity = 0.375,
            11 => scene.transform = .{ 0, 1, -1, 0, 3.5, -2 },
            12 => scene.border = 4,
            13 => scene.lead = 3,
            14 => in.viewport = .{ 120, 90 },
            15 => in.scale = 1.25,
            16 => scene.flip = true,
            17 => scene.offset = 40,
            20 => scene.flip = false,
            else => {},
        }
        const got = scene.frame(&retained, &in, false);
        const want = scene.frame(&rebuilt, &in, true);
        try expectFrameEqual(want, got);
        if (step > 0) try testing.expectEqual(1, retained.memos.kept_len);
    }
}

test "reuse rebuilds collapsed and cursor-dependent children when their parent changes" {
    const Fx = Fixture(.{ .nodes = 24, .texts = 1, .customs = 1, .strings = 16, .signals = 2, .memos = 2, .depth = 5 });
    var ctx = try Fx.context();
    const in: Input = .{ .viewport = .{ 100, 100 } };
    var builds: u32 = 0;
    for (0..4) |step| {
        var f = ctx.begin(&in);
        _ = f.open(.from("parent"), .{ .participation = if (step == 0) .collapsed else .all, .cursor = if (step < 2) .crosshair else .pointer, .size = .{ .fill, .fill } });
        if (!f.reuse(.from("memo"), &.{})) {
            builds += 1;
            _ = f.leaf(.from("memo"), .{ .fill = .white, .size = .{ .px(20), .px(10) } });
        }
        f.close();
        const out = f.end(.{});
        const n = out.tree.find(.from("memo"));
        try testing.expectEqual(@as(f32, if (step == 0) 0 else 10), out.tree.rect(n).h());
        try testing.expectEqual(@as(?types.Cursor, if (step < 2) .crosshair else .pointer), out.tree.cursor(n));
    }
    try testing.expectEqual(@as(u32, 3), builds);
}

test "reuse rebases paint references when an unchanged decorated subtree moves in row storage" {
    const Fx = Fixture(.{ .nodes = 32, .texts = 1, .customs = 1, .strings = 16, .signals = 2, .memos = 2, .depth = 6 });
    var ctx = try Fx.context();
    const in: Input = .{ .viewport = .{ 100, 100 } };
    var builds: u32 = 0;
    for (0..2) |step| {
        var f = ctx.begin(&in);
        if (step != 0) _ = f.leaf(.none, .{ .size = .{ .px(5), .px(5) } });
        const owner = f.open(.from("outside"), .{ .size = .{ .px(60), .px(40) } });
        if (!f.reuse(.from("paint-memo"), &.{})) {
            builds += 1;
            const box = f.open(.from("paint-memo"), .{ .size = .{ .px(20), .px(20) }, .fill = .white });
            _ = f.leaf(.from("outline"), .{ .float = true, .paint_reference = box.ix(), .paint_outset = @splat(2), .border = 1, .border_color = .white });
            _ = f.leaf(.from("external-outline"), .{ .float = true, .paint_reference = owner.ix(), .paint_outset = @splat(1), .border = 1, .border_color = .white });
            f.close();
        }
        f.close();
        const out = f.end(.{});
        const tree = out.tree;
        const internal = tree.find(.from("outline"));
        const external = tree.find(.from("external-outline"));
        try testing.expectEqual(tree.find(.from("paint-memo")), tree.x.row[tree.c.extra[internal]].paint_reference);
        try testing.expectEqual(owner.ix(), tree.x.row[tree.c.extra[external]].paint_reference);
    }
    try testing.expectEqual(@as(u32, 1), builds);
}
