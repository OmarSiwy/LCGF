//! Anims: every spring in the UI as one table of columns, stepped together (tier 0). A spring is
//! a row keyed by widget id; the caller sets its target each frame and reads its position.
//! Ported from prototype/ui.zig ("Anims").

const std = @import("std");
const mem = @import("../core/mem.zig");
const simd = @import("../core/simd.zig");
const types = @import("../core/types.zig");
const Id = types.Id;
const none = types.none;

/// A damped spring's constants. The defaults settle in about a third of a second without
/// overshoot you can see.
pub const Spring = struct {
    stiffness: f32 = 170,
    damping: f32 = 26,
};

pub const Anims = struct {
    len: u32 = 0,
    cap: u32,
    c: Columns,

    /// `simd.rows(cap)` rows each. Rows past `len` are kept zero (inert for `step`).
    pub const Columns = struct {
        id: []u32,
        x: []f32,
        v: []f32,
        target: []f32,
        stiffness: []f32,
        damping: []f32,
        /// Frame this spring was last asked for.
        seen: []u32,
    };

    pub fn init(carver: *mem.Carver, cap: u32) Anims {
        return .{ .cap = cap, .c = carver.columns(Columns, simd.rows(cap)) };
    }

    /// Row for `id`, created resting at `initial` on first use. SIMD lookup. Past `cap` new ids
    /// share the last row.
    pub fn slot(a: *Anims, id: Id, initial: f32) u32 {
        const c = &a.c;
        const k = @backingInt(id);
        const found = simd.find(c.id, a.len, k);
        const is_new = found == none;
        const i = simd.selU(is_new, @min(a.len, a.cap - 1), found);
        a.len = @min(a.len + @intFromBool(is_new), a.cap);
        c.id[i] = k;
        c.x[i] = simd.selF(is_new, initial, c.x[i]);
        c.v[i] = simd.selF(is_new, 0, c.v[i]);
        return i;
    }
};

const testing = std.testing;

/// Anims over a static buffer, for tests.
fn fixture(comptime cap: u32) Anims {
    const S = struct {
        var buffer: [7 * (simd.rows(cap) * 4 + mem.column_align)]u8 align(mem.column_align) = undefined;
    };
    var carver: mem.Carver = .{ .buf = &S.buffer };
    return .init(&carver, cap);
}

test "slot: one row per id, created at rest at its initial value" {
    var a = fixture(4);
    const glow = Id.from("glow");
    const i = a.slot(glow, 0.5);
    try testing.expectEqual(@as(u32, 1), a.len);
    try testing.expectEqual(@as(f32, 0.5), a.c.x[i]);
    try testing.expectEqual(@as(f32, 0), a.c.v[i]);

    // Later calls find the row and leave its state alone.
    a.c.x[i] = 0.75;
    a.c.v[i] = 2;
    try testing.expectEqual(i, a.slot(glow, 0));
    try testing.expectEqual(@as(f32, 0.75), a.c.x[i]);
    try testing.expectEqual(@as(f32, 2), a.c.v[i]);
    try testing.expectEqual(@as(u32, 1), a.len);

    const j = a.slot(Id.from("width"), 100);
    try testing.expect(i != j);
    try testing.expectEqual(@as(f32, 100), a.c.x[j]);
}

test "slot: past capacity, new ids share the last row" {
    var a = fixture(2);
    _ = a.slot(Id.from("a"), 1);
    const b = a.slot(Id.from("b"), 2);
    const c = a.slot(Id.from("c"), 3);
    try testing.expectEqual(b, c);
    try testing.expectEqual(@as(u32, 2), a.len);
    try testing.expectEqual(@as(f32, 3), a.c.x[c]);
    try testing.expectEqual(@backingInt(Id.from("c")), a.c.id[c]);
}
