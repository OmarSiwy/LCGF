//! Tree: the node columns. Rows are in depth-first order, parents before children, so a forward
//! sweep is top-down and a reverse sweep is bottom-up. Tier 0: no allocator, no I/O.
//! Ported from prototype/ui.zig ("Tree").

const std = @import("std");
const simd = @import("simd.zig");
const mem = @import("mem.zig");

pub const Tree = struct {
    len: u32 = 0,
    cap: u32,
    c: Columns,

    /// One slice per property, grouped by the pass that reads them, so a pass touches only the
    /// cache lines it needs. Every column has `simd.rows(cap)` rows (the padding contract).
    pub const Columns = struct {
        // ---- identity and structure: indices, never pointers
        id: []u32,
        parent: []u32,
        /// One past the last descendant. The subtree of i is rows [i, end[i]).
        end: []u32,

        // ---- layout inputs. Sizing modes are coefficients, not tags.
        min: [2][]f32,
        max: [2][]f32,
        grow: [2][]f32,
        pct: [2][]f32,
        pad_lo: [2][]f32,
        pad_hi: [2][]f32,
        offset: [2][]f32,
        scroll: [2][]f32,
        gap: []f32,
        /// Number of in-flow children, kept as f32 because it only feeds arithmetic.
        nkids: []f32,
        /// 1.0 in flow, 0.0 floating.
        flow: []f32,
        shrink: []f32,
        align_main: []f32,
        align_cross: []f32,
        /// main[a] is 1.0 when children are stacked along axis a, else 0.0.
        /// The stacking direction is a coefficient, so no pass compares it.
        main: [2][]f32,

        // ---- layout scratch, rewritten every frame
        fit: [2][]f32,
        nat: [2][]f32,
        grow_sum: [2][]f32,
        /// 1 / grow_sum, filled by `fit` so `resolve` multiplies instead of dividing.
        grow_inv: [2][]f32,
        used: [2][]f32,
        gap_total: []f32,
        cursor: []f32,

        // ---- layout outputs
        size: [2][]f32,
        pos: [2][]f32,
        /// x0, y0, x1, y1 snapped to whole pixels.
        rect: [4][]f32,
        /// `rect` cut down to the inherited clip. What hit testing reads.
        vis: [4][]f32,
        /// Clip handed down to children, as (x0, y0, -x1, -y1). Rectangular:
        /// children of a rounded node are not clipped to its corners.
        child_clip: [][4]f32,
        visible: []u8,
        clips: []u8,
        sense: []u8,

        // ---- semantics, read by the host to build an accessibility tree
        role: []u8,
        value: []f32,

        // ---- links into the side lists, or `none`
        text: []u32,
        custom: []u32,
    };
};

const testing = std.testing;

/// Bytes one row costs summed over every column, ignoring cache-line rounding.
fn rowBytes(comptime S: type) usize {
    var n: usize = 0;
    const info = @typeInfo(S).@"struct";
    inline for (info.field_types) |FT| n += switch (@typeInfo(FT)) {
        .pointer => |p| @sizeOf(p.child),
        .array => |a| a.len * @sizeOf(@typeInfo(a.child).pointer.child),
        else => unreachable,
    };
    return n;
}

test "Columns: every column is carved with rows(cap) rows, zeroed and cache-line aligned" {
    const cap = 37;
    const n = comptime simd.rows(cap);
    const bytes = comptime blk: {
        @setEvalBranchQuota(20_000);
        var counter: mem.Carver = .{ .buf = null };
        _ = counter.columns(Tree.Columns, n);
        break :blk counter.off;
    };
    var buf: [bytes]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    const c = carver.columns(Tree.Columns, n);
    try testing.expectEqual(bytes, carver.off);

    const info = @typeInfo(Tree.Columns).@"struct";
    inline for (info.field_names, info.field_types) |name, FT| {
        const cols = switch (@typeInfo(FT)) {
            .pointer => .{@field(c, name)},
            else => @field(c, name),
        };
        inline for (cols) |col| {
            try testing.expectEqual(n, col.len);
            try testing.expectEqual(0, @intFromPtr(col.ptr) % mem.column_align);
            for (std.mem.sliceAsBytes(col)) |b| try testing.expectEqual(0, b);
        }
    }
}

test "Columns: structure first, then layout, outputs, semantics and links, in pass order" {
    const names = @typeInfo(Tree.Columns).@"struct".field_names;
    // Each group starts where the previous one ends; a pass reads one contiguous run of columns.
    const firsts = .{ "id", "min", "fit", "size", "role", "text" };
    var at: usize = 0;
    inline for (firsts) |first| {
        const k = std.meta.fieldIndex(Tree.Columns, first).?;
        try testing.expect(k >= at);
        at = k;
    }
    try testing.expectEqual(names.len - 1, std.meta.fieldIndex(Tree.Columns, "custom").?);
    // Indices are u32, never pointers: 4 bytes per link.
    try testing.expectEqual([]u32, @FieldType(Tree.Columns, "parent"));
    try testing.expectEqual([]u32, @FieldType(Tree.Columns, "end"));
    // Sum of one row over every column, the per-node cost before line rounding.
    // u32 links, layout inputs, scratch, outputs, child clip, three u8 flags, role, value.
    try testing.expectEqual(4 * 5 + 4 * (9 * 2 + 6) + 4 * (5 * 2 + 2) + 4 * 12 + 16 + 3 + 1 + 4, rowBytes(Tree.Columns));
}
