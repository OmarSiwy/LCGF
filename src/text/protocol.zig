//! The measure / wrap protocol: how text extents reach layout. Data, not callbacks.
//!
//! The core never calls into a font. There is no `measure(node)` hook, no shaper interface and
//! no re-measure loop that layout drives. Text is a side list (`Texts`), and a font is anything
//! that reads its columns and writes others back, at two points the caller sequences:
//!
//! 1. Measure. After the tree is built and before layout, the caller fills `Texts.w` and
//!    `Texts.h` for every run, from `start`/`bytes` (the run's bytes in `Strings`), `px` and
//!    `font`. This is the single-line extent.
//! 2. Wrap. After widths are resolved, layout writes `Texts.avail` (the width it gave each run).
//!    For runs whose `wrap` is 1.0 the caller may then rewrite `w` and `h`; layout reads them for
//!    the vertical axis. Runs that do not wrap keep their measured extent.
//!
//! Why data: a callback per run is an indirect call per row, hides the loop from SIMD, and hands
//! control flow to the framework (Muratori, *Designing and Evaluating Reusable Components*:
//! flow control stays with the caller). Columns in and columns out let one font measure every
//! run in one vector loop, let a real shaper run on another thread or cache by string, and let
//! a test write the numbers by hand. Which font a run uses is a column (`font`), not a type, so
//! several fonts are several passes over the same rows, each masked by `font`.
//!
//! `Mono` below is the protocol for a fixed-advance font and the reference for plugging in a
//! real shaper. Ported from prototype/ui.zig ("fonts").

const std = @import("std");
const simd = @import("../core/simd.zig");
const mem = @import("../core/mem.zig");
const Texts = @import("../core/texts.zig").Texts;

const W = simd.lanes;

/// A fixed-advance font: every byte is `advance` ems wide, every line `line` ems tall.
pub const Mono = struct {
    /// Advance per byte, in ems.
    advance: f32 = 0.6,
    /// Line height, in ems.
    line: f32 = 1.25,

    /// SIMD. Single-line extent of every run. Reads `bytes`, `px`; writes `w`, `h`.
    /// Rows past `tx.len` up to the padding are written too; they are never read.
    pub fn measure(font: Mono, tx: *Texts) void {
        const c = &tx.c;
        const n = simd.padded(tx.len);
        var i: usize = 0;
        while (i < n) : (i += W) {
            const px = simd.loadF(c.px, i);
            const count: simd.F = @floatFromInt(simd.loadU(c.bytes, i));
            simd.storeF(c.w, i, count * px * simd.f(font.advance));
            simd.storeF(c.h, i, px * simd.f(font.line));
        }
    }
};

const testing = std.testing;

fn Fixture(comptime cap: u32) type {
    return struct {
        buf: [bytes]u8 align(mem.column_align) = undefined,

        const bytes = blk: {
            var counter: mem.Carver = .{ .buf = null };
            _ = Texts.init(&counter, cap);
            break :blk counter.off;
        };
        fn texts(fx: *@This()) Texts {
            var carver: mem.Carver = .{ .buf = &fx.buf };
            return Texts.init(&carver, cap);
        }
    };
}

test "the protocol is columns: a caller can measure by hand" {
    var fx: Fixture(4) = .{};
    var tx = fx.texts();
    const k = tx.push(0, .{ .start = 0, .bytes = 3 }, &.{ .px = 10, .wrap = true });
    // Inputs a font reads, outputs it writes: plain f32 columns, no hook to register.
    try testing.expectEqual(0, tx.c.w[k]);
    try testing.expectEqual(0, tx.c.h[k]);
    tx.c.w[k] = 18;
    tx.c.h[k] = 12;
    tx.c.avail[k] = 10;
    try testing.expectEqual(1, tx.c.wrap[k]);
    try testing.expectEqual(18, tx.c.w[k]);
}

test "Mono.measure: bytes * px * advance wide, px * line tall, for every run" {
    var fx: Fixture(20) = .{};
    var tx = fx.texts();
    // More runs than lanes, so the loop takes several steps at every lane count.
    for (0..19) |k| _ = tx.push(0, .{ .bytes = @intCast(k) }, &.{ .px = 10 });
    _ = tx.push(0, .{ .bytes = 24 }, &.{ .px = 20 });
    const font: Mono = .{ .advance = 0.5, .line = 1.2 };
    font.measure(&tx);
    for (0..19) |k| {
        try testing.expectEqual(@as(f32, @floatFromInt(k)) * 5, tx.c.w[k]);
        try testing.expectEqual(12, tx.c.h[k]);
    }
    try testing.expectEqual(240, tx.c.w[19]);
    try testing.expectEqual(24, tx.c.h[19]);
}
