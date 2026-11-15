//! Tree: the node columns. Rows are in depth-first order, parents before children, so a forward
//! sweep is top-down and a reverse sweep is bottom-up. Tier 0: no allocator, no I/O.
//! Ported from prototype/ui.zig ("Tree").

const std = @import("std");
const simd = @import("simd.zig");
const mem = @import("mem.zig");
const types = @import("types.zig");
const none = types.none;
const Id = types.Id;
const Size = types.Size;
const Align = types.Align;
const Style = types.Style;
const b01 = simd.b2f;

/// How a node is painted. One row per node in `Tree.Columns.look`: paint reads all of these
/// together and layout reads none, so they are one cold row instead of seven hot columns.
/// `extern` because the row crosses to the GPU; hence `[4]f32`, not a vector.
pub const Look = extern struct {
    fill: u32,
    border_color: u32,
    border: f32,
    radius: f32,
    params: [4]f32,
    texture: u16,
    material: u16,
};

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

        // ---- paint inputs. Cold during layout and always read together, so
        //      they are one row per node rather than seven columns.
        look: []Look,

        // ---- semantics, read by the host to build an accessibility tree
        role: []u8,
        value: []f32,

        // ---- links into the side lists, or `none`
        text: []u32,
        custom: []u32,
    };

    /// Rows allocated for `cap` nodes: whole vectors plus one spare, so batch
    /// passes may read and write one vector past `len`.
    pub fn rows(cap: u32) usize {
        return simd.rows(cap);
    }
    /// Carves every column from `carver`. With a counting carver this sizes the buffer instead.
    pub fn init(carver: *mem.Carver, cap: u32) Tree {
        return .{ .cap = cap, .c = carver.columns(Columns, rows(cap)) };
    }
    /// Empties the tree for the next frame. Columns keep their memory and stale rows; every
    /// row is rewritten before it is read again.
    pub fn reset(t: *Tree) void {
        t.len = 0;
    }

    /// Appends a node as the last child of `parent` and returns its row.
    /// One row write per column; no searching, no allocation, no branch.
    pub fn push(t: *Tree, parent: u32, id: Id, s: *const Style) u32 {
        std.debug.assert(t.len < t.cap);
        const c = &t.c;
        const i = t.len;
        t.len = i + 1;

        c.id[i] = @backingInt(id);
        c.parent[i] = parent;
        c.end[i] = i + 1;
        inline for (0..2) |a| {
            const k = @backingInt(s.size[a].kind);
            const v = s.size[a].v;
            c.min[a][i] = @max(v * Size.k_min[k], s.min[a]);
            c.max[a][i] = @min(v * Size.k_max[k] + Size.c_max[k], s.max[a]);
            c.grow[a][i] = v * Size.k_grow[k];
            c.pct[a][i] = v * Size.k_pct[k];
            c.pad_lo[a][i] = s.pad[a];
            c.pad_hi[a][i] = s.pad[a + 2];
            c.offset[a][i] = s.offset[a];
            c.scroll[a][i] = s.scroll[a];
        }
        const fl = b01(!s.float);
        c.gap[i] = s.gap;
        c.nkids[i] = 0;
        c.flow[i] = fl;
        c.shrink[i] = b01(s.shrink);
        c.align_main[i] = Align.factor[@backingInt(s.main)];
        c.align_cross[i] = Align.factor[@backingInt(s.cross)];
        const along_y: f32 = @floatFromInt(@backingInt(s.dir));
        c.main[0][i] = 1 - along_y;
        c.main[1][i] = along_y;
        c.clips[i] = @intFromBool(s.clip);
        c.sense[i] = 0;
        c.look[i] = .{
            .fill = s.fill.bitsOf(),
            .border_color = s.border_color.bitsOf(),
            .border = s.border,
            .radius = s.radius,
            .params = s.params,
            .texture = @backingInt(s.texture),
            .material = @backingInt(s.material),
        };
        c.role[i] = @backingInt(s.role);
        c.value[i] = s.value;
        c.text[i] = none;
        c.custom[i] = none;
        // The root is its own parent and must not count itself.
        c.nkids[parent] += fl * b01(i != 0);
        return i;
    }
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
    const firsts = .{ "id", "min", "fit", "size", "look", "role", "text" };
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
    // u32 links, layout inputs, scratch, outputs, child clip, three u8 flags, look, role, value.
    try testing.expectEqual(4 * 5 + 4 * (9 * 2 + 6) + 4 * (5 * 2 + 2) + 4 * 12 + 16 + 3 + @sizeOf(Look) + 1 + 4, rowBytes(Tree.Columns));
}

test "Look: one 36-byte row with the C layout the GPU reads" {
    try testing.expectEqual(36, @sizeOf(Look));
    try testing.expectEqual(4, @alignOf(Look));
    inline for (.{ "fill", "border_color", "border", "radius", "params", "texture", "material" }, .{ 0, 4, 8, 12, 16, 32, 34 }) |name, off|
        try testing.expectEqual(off, @offsetOf(Look, name));
    try testing.expectEqual([]Look, @FieldType(Tree.Columns, "look"));
}

test "init carves rows(cap) rows per column; counting and carving agree; reset empties" {
    const cap = 10;
    const bytes = comptime blk: {
        @setEvalBranchQuota(20_000);
        var counter: mem.Carver = .{ .buf = null };
        _ = Tree.init(&counter, cap);
        break :blk counter.off;
    };
    var buf: [bytes]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    var t = Tree.init(&carver, cap);
    try testing.expectEqual(bytes, carver.off);
    try testing.expectEqual(0, t.len);
    try testing.expectEqual(cap, t.cap);
    try testing.expectEqual(simd.padded(cap) + simd.lanes, Tree.rows(cap));
    try testing.expectEqual(Tree.rows(cap), t.c.id.len);
    try testing.expectEqual(Tree.rows(cap), t.c.look.len);
    try testing.expectEqual(Tree.rows(cap), t.c.vis[3].len);

    t.len = 7;
    t.reset();
    try testing.expectEqual(0, t.len);
    try testing.expectEqual(cap, t.cap);
}

/// A tree of `cap` rows in a caller-owned buffer, for tests.
fn Fixture(comptime cap: u32) type {
    return struct {
        buf: [bytes]u8 align(mem.column_align) = undefined,

        const bytes = blk: {
            @setEvalBranchQuota(20_000);
            var counter: mem.Carver = .{ .buf = null };
            _ = Tree.init(&counter, cap);
            break :blk counter.off;
        };
        fn tree(f: *@This()) Tree {
            var carver: mem.Carver = .{ .buf = &f.buf };
            return Tree.init(&carver, cap);
        }
    };
}

test "push writes one row per column from the style's coefficients" {
    var fx: Fixture(8) = .{};
    var t = fx.tree();
    const root = t.push(0, Id.from("root"), &.{ .dir = .x, .size = .{ .px(100), .fill }, .pad = .{ 1, 2, 3, 4 }, .gap = 5, .clip = true });
    try testing.expectEqual(0, root);
    const a = t.push(root, Id.from("a"), &.{ .size = .{ .pct(0.5), .fit }, .min = .{ 0, 7 }, .max = .{ 30, types.inf }, .main = .center, .cross = .end, .shrink = true, .fill = .rgb(1, 2, 3), .radius = 4, .texture = @fromBackingInt(9), .role = .button, .value = 0.25 });
    const b = t.push(root, Id.from("b"), &.{ .float = true, .offset = .{ 6, 8 }, .scroll = .{ 1, 2 } });
    try testing.expectEqual(1, a);
    try testing.expectEqual(2, b);
    try testing.expectEqual(3, t.len);
    const c = t.c;

    try testing.expectEqual(@backingInt(Id.from("a")), c.id[a]);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 0 }, c.parent[0..3]);
    // end is one past the row until `seal` closes the subtree.
    try testing.expectEqualSlices(u32, &.{ 1, 2, 3 }, c.end[0..3]);
    // px(100) on x: min = max = 100; fill on y: grow 1, unbounded.
    try testing.expectEqual(100, c.min[0][root]);
    try testing.expectEqual(100, c.max[0][root]);
    try testing.expectEqual(0, c.grow[0][root]);
    try testing.expectEqual(1, c.grow[1][root]);
    try testing.expectEqual(types.inf, c.max[1][root]);
    // pct(0.5) is a coefficient, clamped by the style's own max; min on y comes from Style.min.
    try testing.expectEqual(0.5, c.pct[0][a]);
    try testing.expectEqual(30, c.max[0][a]);
    try testing.expectEqual(7, c.min[1][a]);
    try testing.expectEqualSlices(f32, &.{ 1, 2 }, &.{ c.pad_lo[0][root], c.pad_lo[1][root] });
    try testing.expectEqualSlices(f32, &.{ 3, 4 }, &.{ c.pad_hi[0][root], c.pad_hi[1][root] });
    try testing.expectEqual(5, c.gap[root]);
    try testing.expectEqualSlices(f32, &.{ 6, 8, 1, 2 }, &.{ c.offset[0][b], c.offset[1][b], c.scroll[0][b], c.scroll[1][b] });
    // Direction as a coefficient pair.
    try testing.expectEqualSlices(f32, &.{ 1, 0 }, &.{ c.main[0][root], c.main[1][root] });
    try testing.expectEqualSlices(f32, &.{ 0, 1 }, &.{ c.main[0][a], c.main[1][a] });
    try testing.expectEqualSlices(f32, &.{ 0.5, 1 }, &.{ c.align_main[a], c.align_cross[a] });
    try testing.expectEqualSlices(f32, &.{ 1, 0 }, &.{ c.shrink[a], c.shrink[b] });
    try testing.expectEqualSlices(f32, &.{ 1, 1, 0 }, c.flow[0..3]);
    try testing.expectEqualSlices(u8, &.{ 1, 0, 0 }, c.clips[0..3]);
    // Only in-flow children are counted, and the root does not count itself.
    try testing.expectEqualSlices(f32, &.{ 1, 0, 0 }, c.nkids[0..3]);
    try testing.expectEqual(types.Color.rgb(1, 2, 3).bitsOf(), c.look[a].fill);
    try testing.expectEqual(4, c.look[a].radius);
    try testing.expectEqual(9, c.look[a].texture);
    try testing.expectEqual(@backingInt(types.Role.button), c.role[a]);
    try testing.expectEqual(0.25, c.value[a]);
    try testing.expectEqualSlices(u32, &.{ none, none, none }, c.text[0..3]);
    try testing.expectEqualSlices(u32, &.{ none, none, none }, c.custom[0..3]);
}
