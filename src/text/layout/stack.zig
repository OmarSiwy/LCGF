//! The full text stack on the measure / wrap protocol (src/text/protocol.zig): shaping, line
//! breaking and placement for every run of `Texts`, at the two points the caller sequences.
//! Tier 0.
//!
//! `Stack` is to real fonts what `protocol.Mono` is to the fixed-advance one, and slots into
//! the same places of the frame (prototype/ui.zig `Frame.end`):
//!
//!   tree.seal(0);
//!   stack.measure(tx, strings, ascent);  // was font.measure(tx)
//!   layout.prepare(t); layout.applyText(t, tx, .x); layout.fit(t, .x); layout.resolve(t, .x, vw);
//!   layout.textAvail(t, tx);
//!   stack.wrap(tx, strings, ascent);     // was font.wrap(tx)
//!   layout.applyText(t, tx, .y); layout.fit(t, .y); layout.resolve(t, .y, vh);
//!   layout.place(t); layout.finalize(t); paint.emit(...);
//!
//! and, when drawing, `paragraph` lays run k out again exactly as `wrap` did (draw list run k
//! is texts row k), for glyph quads at the run's rect. Which runs it serves is the `font`
//! column: a run whose font has no shaper here is left alone for another font to measure.
//!
//! `ascent` is one row per run: the first line's baseline below the run's top, for
//! layout/baseline.zig `apply` to line rows of text up. Shaping is per run and reads its bytes,
//! like `shape.measure`: not a row pass, so it may skip rows.

const std = @import("std");
const shape = @import("../shape/shape.zig");
const lines = @import("lines.zig");
const Texts = @import("../../core/texts.zig").Texts;
const Strings = @import("../../core/strings.zig").Strings;

/// Shapers by font index, and scratch for one paragraph. The caller owns all of it.
pub const Stack = struct {
    shapers: []const shape.Shaper,
    run: shape.Run,
    g: lines.Glyphs,
    l: lines.Lines,
    /// A run did not fit the scratch: it was measured as empty. Reset by the caller.
    overflow: bool = false,

    /// Whether this stack measures row `k`.
    pub fn serves(st: *const Stack, tx: *const Texts, k: usize) bool {
        return tx.c.font[k] < st.shapers.len;
    }

    /// Lays row `k` of `tx` out into the scratch (`g`, `l`), start aligned, broken at
    /// `width`: shaped with its font at its size, then `lines.breakLines` and `lines.place`.
    pub fn layoutAt(st: *Stack, tx: *const Texts, strings: *const Strings, k: usize, width: f32) error{NoSpace}!void {
        const c = &tx.c;
        const sh = &st.shapers[c.font[k]];
        const text = strings.get(.{ .start = c.start[k], .bytes = c.bytes[k] });
        try sh.shape(text, &st.run, .{});
        st.g.len = 0;
        try st.g.append(&st.run, c.px[k] / @as(f32, @floatFromInt(sh.face.units_per_em)), 0, 0);
        try lines.breakLines(&st.g, text, width, &st.l);
        lines.place(&st.l, &st.g, text, &.{lines.Metrics.of(&sh.face, c.px[k])}, .{ .width = width });
    }

    /// Row `k` laid out as `wrap` left it: broken at `avail` when it wraps, else not at all.
    /// For drawing run k of the draw list at its rect.
    pub fn paragraph(st: *Stack, tx: *const Texts, strings: *const Strings, k: usize) error{NoSpace}!void {
        return st.layoutAt(tx, strings, k, breakWidth(tx, k));
    }

    /// Step 1 of the protocol: every run's extent unbroken (newlines still break): `w` the
    /// widest line, `h` the stacked lines, `ascent` the first baseline.
    pub fn measure(st: *Stack, tx: *Texts, strings: *const Strings, ascent: []f32) void {
        std.debug.assert(ascent.len >= tx.len);
        for (0..tx.len) |k| {
            if (!st.serves(tx, k)) continue;
            st.fill(tx, strings, k, std.math.inf(f32), ascent);
        }
    }

    /// Step 2: runs flagged `wrap` broken at `avail` (written by `layout.textAvail`); `w`, `h`
    /// and `ascent` rewritten. Other runs keep their measured extent.
    pub fn wrap(st: *Stack, tx: *Texts, strings: *const Strings, ascent: []f32) void {
        std.debug.assert(ascent.len >= tx.len);
        for (0..tx.len) |k| {
            if (!st.serves(tx, k) or tx.c.wrap[k] == 0) continue;
            st.fill(tx, strings, k, tx.c.avail[k], ascent);
        }
    }

    fn fill(st: *Stack, tx: *Texts, strings: *const Strings, k: usize, at: f32, ascent: []f32) void {
        st.layoutAt(tx, strings, k, at) catch {
            st.overflow = true;
            tx.c.w[k] = 0;
            tx.c.h[k] = 0;
            ascent[k] = 0;
            return;
        };
        tx.c.w[k] = lines.widest(&st.l);
        tx.c.h[k] = lines.stackHeight(&st.l);
        ascent[k] = st.l.baseline[0];
    }
};

/// The width run `k` is broken at: `avail` when it wraps, else infinite.
pub fn breakWidth(tx: *const Texts, k: usize) f32 {
    return if (tx.c.wrap[k] > 0) tx.c.avail[k] else std.math.inf(f32);
}

// ---------------------------------------------------------------------------------------------

const testing = std.testing;
const golden = @import("golden.zig");

test "measure and wrap fill w, h and ascent of the runs in this stack's fonts" {
    const mem = @import("../../core/mem.zig");
    const shapers = [_]shape.Shaper{.init(try @import("../font/opentype.zig").Face.parse(golden.font, 0))};
    var buf: [16 * 1024]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var tx: Texts = .init(&carver, 4);
    var bytes: [128]u8 = undefined;
    var strings: Strings = .{ .buf = &bytes };
    const a = tx.push(0, strings.add("one two three"), &.{ .px = 20, .wrap = true });
    const b = tx.push(1, strings.add("one two three"), &.{ .px = 20 });
    const c = tx.push(2, strings.add("other font"), &.{ .px = 20, .font = @fromBackingInt(1) });
    const d = tx.push(3, strings.add("two\nlines"), &.{ .px = 20 });
    var p: golden.Para = .{};
    p.bind();
    var cols: golden.RunCols = .{};
    var st: Stack = .{ .shapers = &shapers, .run = cols.run(), .g = p.g, .l = p.l };
    var ascent: [4]f32 = @splat(-1);
    st.measure(&tx, &strings, &ascent);
    const m: lines.Metrics = .of(&shapers[0].face, 20);
    try testing.expectEqual(tx.c.w[a], tx.c.w[b]);
    try testing.expect(tx.c.w[a] > 100);
    try testing.expectEqual(m.height(), tx.c.h[a]);
    try testing.expectEqual(m.ascent, ascent[a]);
    try testing.expectEqual(0, tx.c.w[c]); // not this stack's font: untouched
    try testing.expectEqual(-1, ascent[c]);
    try testing.expectEqual(2 * m.height(), tx.c.h[d]);
    // The measured width fits exactly: wrapping at it changes nothing.
    const w = tx.c.w[a];
    tx.c.avail[a] = w;
    tx.c.avail[b] = 10;
    st.wrap(&tx, &strings, &ascent);
    try testing.expectEqual(w, tx.c.w[a]);
    try testing.expectEqual(m.height(), tx.c.h[a]);
    // Narrower: three lines; the run that does not wrap keeps its extent.
    tx.c.avail[a] = w / 2;
    st.wrap(&tx, &strings, &ascent);
    try testing.expectEqual(3 * m.height(), tx.c.h[a]);
    try testing.expect(tx.c.w[a] <= w / 2);
    try testing.expectEqual(w, tx.c.w[b]);
    try testing.expectEqual(m.height(), tx.c.h[b]);
    try testing.expect(!st.overflow);
}

test "golden: a frame measured, wrapped and painted through the stack matches the reference" {
    try golden.expectFrame();
}
