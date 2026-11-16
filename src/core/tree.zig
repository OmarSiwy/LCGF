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
const Rect = types.Rect;
const b01 = simd.b2f;

/// How a node is painted. One row per node in `Tree.Columns.look`: paint reads all of these
/// together and layout reads none, so they are one cold row instead of six hot columns.
/// 32 bytes with `params` first, so rows and `params` are 16-byte aligned. The border width is
/// its own column (`Tree.Columns.border`): finalize and `draw.inherit.clip` read it alone
/// (docs/perf/columns.md). `extern` for a fixed layout; hence `[4]f32`, not a vector.
pub const Look = extern struct {
    params: [4]f32,
    fill: u32,
    border_color: u32,
    radius: f32,
    texture: u16,
    material: u16,
};

/// One node's row as `Tree.push` writes it, computed from a `Style`: sizing modes as
/// coefficients, enums as factors, paint fields as their GPU row. A widget whose style does not
/// change between nodes builds it once (`from`, also at comptime) and pushes it with
/// `Tree.pushRow`, so the per-node work is the copy alone. Field names are the column names;
/// `[2]f32` fields go to the two axis columns.
pub const Template = struct {
    min: [2]f32,
    max: [2]f32,
    grow: [2]f32,
    pct: [2]f32,
    pad_lo: [2]f32,
    pad_hi: [2]f32,
    offset: [2]f32,
    scroll: [2]f32,
    main: [2]f32,
    gap: f32,
    flow: f32,
    shrink: f32,
    align_main: f32,
    align_cross: f32,
    clips: u8,
    sense: u8 = 0,
    look: Look,
    border: f32,
    uv: [4]f32,
    radii: [4]f32,
    opacity: f32,
    alpha: f32,
    transform: [6]f32,
    world: [6]f32 = .{ 1, 0, 0, 1, 0, 0 },
    clip_radii: [4]f32 = @splat(0),
    role: u8,
    value: f32,
    text: u32 = none,
    custom: u32 = none,

    pub fn from(s: *const Style) Template {
        var r: Template = undefined;
        inline for (0..2) |a| {
            const k = @backingInt(s.size[a].kind);
            const v = s.size[a].v;
            r.min[a] = @max(v * Size.k_min[k], s.min[a]);
            r.max[a] = @min(v * Size.k_max[k] + Size.c_max[k], s.max[a]);
            r.grow[a] = v * Size.k_grow[k];
            r.pct[a] = v * Size.k_pct[k];
            r.pad_lo[a] = s.pad[a];
            r.pad_hi[a] = s.pad[a + 2];
            r.offset[a] = s.offset[a];
            r.scroll[a] = s.scroll[a];
        }
        const along_y: f32 = @floatFromInt(@backingInt(s.dir));
        const corners: @Vector(4, f32) = s.radii;
        r.main = .{ 1 - along_y, along_y };
        r.gap = s.gap;
        r.flow = b01(!s.float);
        r.shrink = b01(s.shrink);
        r.align_main = Align.factor[@backingInt(s.main)];
        r.align_cross = Align.factor[@backingInt(s.cross)];
        r.clips = @intFromBool(s.clip);
        r.sense = 0;
        r.look = .{
            .fill = s.fill.bitsOf(),
            .border_color = s.border_color.bitsOf(),
            .radius = s.radius,
            .params = s.params,
            .texture = @backingInt(s.texture),
            .material = @backingInt(s.material),
        };
        r.border = s.border;
        r.uv = s.uv;
        r.radii = @select(f32, corners < @as(@Vector(4, f32), @splat(0)), @as(@Vector(4, f32), @splat(s.radius)), corners);
        r.opacity = s.opacity;
        r.alpha = s.opacity;
        r.transform = s.transform;
        r.world = .{ 1, 0, 0, 1, 0, 0 };
        r.clip_radii = @splat(0);
        r.role = @backingInt(s.role);
        r.value = s.value;
        r.text = none;
        r.custom = none;
        return r;
    }
};

/// Where the columns live: slices carved from a caller's buffer (`init`), or arrays inside the
/// tree value itself for a capacity known at compile time (`empty`), as the comptime front end
/// keeps its tables.
pub const Storage = union(enum) {
    slice,
    array: u32,
};

/// The runtime front end's tree: u32 indices, columns carved from the caller's buffer.
pub const Tree = TreeOf(u32, .slice);

/// A tree whose node links (`parent`, `end`, `push`'s rows) are `Index`, the smallest integer
/// that fits the capacity, as `Ui().Index` is in prototype/comptime_ui_probe.zig. Ids and the
/// side-list links stay u32: ids are hashes and side lists have their own capacity.
pub fn TreeOf(comptime Index: type, comptime storage: Storage) type {
    comptime std.debug.assert(@typeInfo(Index).int.signedness == .unsigned);
    if (storage == .array) comptime std.debug.assert(storage.array > 0 and storage.array <= std.math.maxInt(Index));
    return struct {
        const Self = @This();
        /// A column of `T`: one row per node, `simd.rows(cap)` rows.
        fn Col(comptime T: type) type {
            return switch (storage) {
                .slice => []T,
                .array => |n| [simd.rows(n)]T,
            };
        }

        len: u32 = 0,
        cap: u32,
        /// `push` ran out of rows. The last row is overwritten; nothing is written out of bounds.
        /// The front end reports it as `Status.nodes`.
        overflow: bool = false,
        c: Columns,

        /// One column per property, grouped by the pass that reads them, so a pass touches only the
        /// cache lines it needs. Every column has `simd.rows(cap)` rows (the padding contract).
        pub const Columns = struct {
            // ---- identity and structure: indices, never pointers
            id: Col(u32),
            parent: Col(Index),
            /// One past the last descendant. The subtree of i is rows [i, end[i]).
            end: Col(Index),

            // ---- layout inputs. Sizing modes are coefficients, not tags.
            min: [2]Col(f32),
            max: [2]Col(f32),
            grow: [2]Col(f32),
            pct: [2]Col(f32),
            pad_lo: [2]Col(f32),
            pad_hi: [2]Col(f32),
            offset: [2]Col(f32),
            scroll: [2]Col(f32),
            gap: Col(f32),
            /// Number of in-flow children, kept as f32 because it only feeds arithmetic.
            nkids: Col(f32),
            /// 1.0 in flow, 0.0 floating.
            flow: Col(f32),
            shrink: Col(f32),
            align_main: Col(f32),
            align_cross: Col(f32),
            /// main[a] is 1.0 when children are stacked along axis a, else 0.0.
            /// The stacking direction is a coefficient, so no pass compares it.
            main: [2]Col(f32),

            // ---- layout scratch, rewritten every frame
            fit: [2]Col(f32),
            nat: [2]Col(f32),
            grow_sum: [2]Col(f32),
            /// 1 / grow_sum, filled by `fit` so `resolve` multiplies instead of dividing.
            grow_inv: [2]Col(f32),
            used: [2]Col(f32),
            gap_total: Col(f32),
            cursor: Col(f32),

            // ---- layout outputs
            size: [2]Col(f32),
            pos: [2]Col(f32),
            /// x0, y0, x1, y1 snapped to whole pixels.
            rect: [4]Col(f32),
            /// `rect` cut down to the inherited clip. What hit testing reads.
            vis: [4]Col(f32),
            /// Clip handed down to children, as (x0, y0, -x1, -y1). Rectangular here; its
            /// rounded corners are `clip_radii`, which paint passes to the shader.
            child_clip: Col([4]f32),
            visible: Col(u8),
            clips: Col(u8),
            sense: Col(u8),

            // ---- paint inputs. Cold during layout and always read together, so
            //      they are one row per node rather than six columns.
            look: Col(Look),
            /// Border width (`Style.border`). Read by finalize (children clip inside it),
            /// `draw.inherit.clip` and paint, so kept out of `look`.
            border: Col(f32),
            /// Texture coordinates u0, v0, u1, v1 of the quad's corners (`Style.uv`). Kept out
            /// of `Look`, which is a fixed GPU row; read only by paint.
            uv: Col([4]f32),
            /// Corner radii top-left, top-right, bottom-right, bottom-left (`Style.radii`, with
            /// negative corners taken from `Style.radius`).
            radii: Col([4]f32),
            /// `Style.opacity` of this node alone.
            opacity: Col(f32),
            /// Opacity paint applies: the product of `opacity` over the node and its ancestors,
            /// written by `draw.inherit.opacity`. Push sets it to the node's own.
            alpha: Col(f32),
            /// `Style.transform` of this node alone, about its centre.
            transform: Col([6]f32),
            /// Layout space to screen: the node's transform after its ancestors', written by
            /// `draw.inherit.transform`. Push sets the identity.
            world: Col([6]f32),
            /// Corner radii of the clip handed to children (`child_clip`), written by
            /// `draw.inherit.clip`: a clipping node's radii less its border, otherwise the
            /// parent's. Push sets 0, a rectangular clip.
            clip_radii: Col([4]f32),

            // ---- semantics, read by the host to build an accessibility tree
            role: Col(u8),
            value: Col(f32),

            // ---- links into the side lists, or `none`
            text: Col(u32),
            custom: Col(u32),
        };

        /// Rows allocated for `cap` nodes: whole vectors plus one spare, so batch
        /// passes may read and write one vector past `len`.
        pub fn rows(cap: u32) usize {
            return simd.rows(cap);
        }
        /// Carves every column from `carver`. With a counting carver this sizes the buffer instead.
        /// Slice storage only.
        pub fn init(carver: *mem.Carver, cap: u32) Self {
            comptime std.debug.assert(storage == .slice);
            std.debug.assert(cap > 0 and cap <= std.math.maxInt(Index));
            return .{ .cap = cap, .c = carver.columns(Columns, rows(cap)) };
        }
        /// An empty tree with zeroed columns. Array storage only: the value holds every row.
        pub const empty = if (storage == .array) Self{ .cap = storage.array, .c = std.mem.zeroes(Columns) } else {};
        /// Empties the tree for the next frame. Columns keep their memory and stale rows; every
        /// row is rewritten before it is read again.
        pub fn reset(t: *Self) void {
            t.len = 0;
            t.overflow = false;
        }

        /// Appends a node as the last child of `parent` and returns its row.
        /// One row write per column; no searching, no allocation, no branch.
        pub fn push(t: *Self, parent: Index, id: Id, s: *const Style) Index {
            return t.pushRow(parent, id, &.from(s));
        }

        /// `push` from a style already turned into its row (`Template.from`, once per style
        /// rather than once per node): the row is copied as it is, one store per column.
        pub fn pushRow(t: *Self, parent: Index, id: Id, row: *const Template) Index {
            const c = &t.c;
            const i: Index = @intCast(@min(t.len, t.cap - 1));
            t.overflow = simd.orB(t.overflow, t.len >= t.cap);
            t.len = i + 1;

            c.id[i] = @backingInt(id);
            c.parent[i] = parent;
            c.end[i] = i + 1;
            inline for (@typeInfo(Template).@"struct".field_names) |name| {
                const v = @field(row, name);
                if (@TypeOf(@field(c, name)) == [2]Col(f32)) {
                    inline for (0..2) |a| @field(c, name)[a][i] = v[a];
                } else @field(c, name)[i] = v;
            }
            // Count this node in its parent, then clear its own count. The root is its own
            // parent, so the clear also removes its self-count: no `i != 0` test, which
            // Zig 0.18's LLVM turned back into a branch. Every other row has parent < i.
            c.nkids[parent] += row.flow;
            c.nkids[i] = 0;
            return i;
        }

        /// Closes node `i`: everything pushed since belongs to its subtree.
        pub fn seal(t: *Self, i: Index) void {
            t.c.end[i] = @intCast(t.len);
        }

        pub fn rect(t: *const Self, i: u32) Rect {
            return .{ .x0 = t.c.rect[0][i], .y0 = t.c.rect[1][i], .x1 = t.c.rect[2][i], .y1 = t.c.rect[3][i] };
        }

        /// Row of the node with `id`, or `none`. SIMD scan of the id column.
        pub fn find(t: *const Self, id: Id) u32 {
            return simd.find(t.c.id[0..], t.len, @backingInt(id));
        }

        pub const Invalid = error{
            /// len > cap.
            LenOverCap,
            /// Row 0 is not its own parent.
            RootParent,
            /// A row's parent is not an earlier row.
            ParentNotBefore,
            /// end[i] is not in (i, len].
            EndOutOfRange,
            /// A row is not inside its parent's range, or a range before it still contains it:
            /// the parent is not the innermost open range, so the ranges do not nest.
            RangesCross,
        };

        /// Checks the structural invariants every pass relies on: rows in depth-first order,
        /// parent before child, and subtree ranges [i, end[i]) that nest exactly as the parent
        /// links say. O(len * depth), no memory. Callable in any build; `validate` is the
        /// debug-only form.
        pub fn check(t: *const Self) Invalid!void {
            if (t.len > t.cap) return error.LenOverCap;
            if (t.len == 0) return;
            const c = &t.c;
            if (c.parent[0] != 0) return error.RootParent;
            for (0..t.len) |j| {
                if (c.end[j] <= j or c.end[j] > t.len) return error.EndOutOfRange;
                if (j == 0) continue;
                const p = c.parent[j];
                if (p >= j) return error.ParentNotBefore;
                // The innermost range still open at j must be j's parent: climb from the row
                // before j past every range that closed at or before j.
                var a: u32 = @intCast(j - 1);
                while (c.end[a] <= j and a != 0) a = c.parent[a];
                if (a != p or c.end[j] > c.end[p]) return error.RangesCross;
            }
        }

        /// `check`, asserted in Debug and ReleaseSafe; compiled out in ReleaseFast and ReleaseSmall.
        pub fn validate(t: *const Self) void {
            if (!std.debug.runtime_safety) return;
            t.check() catch |e| std.debug.panic("tree: {s}", .{@errorName(e)});
        }
    };
}

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
    // u32 links, layout inputs, scratch, outputs, child clip, three u8 flags, look, border, uv, radii,
    // opacity, alpha, transform, world, clip radii, role, value.
    try testing.expectEqual(4 * 5 + 4 * (9 * 2 + 6) + 4 * (5 * 2 + 2) + 4 * 12 + 16 + 3 + @sizeOf(Look) + 4 + 16 + 16 + 4 + 4 + 24 + 24 + 16 + 1 + 4, rowBytes(Tree.Columns));
}

test "Look: one 32-byte row, params first" {
    try testing.expectEqual(32, @sizeOf(Look));
    try testing.expectEqual(4, @alignOf(Look));
    inline for (.{ "params", "fill", "border_color", "radius", "texture", "material" }, .{ 0, 16, 20, 24, 28, 30 }) |name, off|
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
    try testing.expectEqual([4]f32{ 4, 4, 4, 4 }, c.radii[a]);
    try testing.expectEqual(9, c.look[a].texture);
    try testing.expectEqual(@backingInt(types.Role.button), c.role[a]);
    try testing.expectEqual(0.25, c.value[a]);
    try testing.expectEqualSlices(u32, &.{ none, none, none }, c.text[0..3]);
    try testing.expectEqualSlices(u32, &.{ none, none, none }, c.custom[0..3]);
}

test "pushRow of a style's template writes the row push writes" {
    var fx: Fixture(8) = .{};
    var fy: Fixture(8) = .{};
    var a = fx.tree();
    var b = fy.tree();
    const styles = comptime [_]Style{
        .{ .dir = .x, .size = .{ .px(100), .fill }, .pad = .{ 1, 2, 3, 4 }, .gap = 5, .clip = true },
        .{ .size = .{ .pct(0.5), .fit }, .max = .{ 30, types.inf }, .cross = .end, .shrink = true, .radius = 4, .radii = .{ -1, 2, -1, 3 }, .opacity = 0.5 },
        .{ .float = true, .offset = .{ 6, 8 }, .transform = .{ 2, 0, 0, 2, 1, 1 }, .role = .button },
    };
    // At comptime too: a widget's fixed style costs nothing per node.
    const fixed = comptime Template.from(&styles[2]);
    for (&styles, 0..) |*s, k| {
        const p: u32 = @intCast(@min(k, 1));
        _ = a.push(p, Id.from("n").with(@intCast(k)), s);
        _ = b.pushRow(p, Id.from("n").with(@intCast(k)), &if (k == 2) fixed else Template.from(s));
    }
    try testing.expectEqual(a.len, b.len);
    inline for (@typeInfo(Tree.Columns).@"struct".field_names) |name| {
        const ca = @field(a.c, name);
        const cb = @field(b.c, name);
        if (@typeInfo(@TypeOf(ca)) == .array) {
            inline for (ca, cb) |x, y| try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(x[0..a.len]), std.mem.sliceAsBytes(y[0..a.len]));
        } else try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(ca[0..a.len]), std.mem.sliceAsBytes(cb[0..a.len]));
    }
}

test "seal closes a subtree over everything pushed since its node" {
    var fx: Fixture(8) = .{};
    var t = fx.tree();
    // root { a { a1 a2 } b }
    const root = t.push(0, .none, &.{});
    const a = t.push(root, .none, &.{});
    const a1 = t.push(a, .none, &.{});
    t.seal(a1);
    const a2 = t.push(a, .none, &.{});
    t.seal(a2);
    t.seal(a);
    const b = t.push(root, .none, &.{});
    t.seal(b);
    t.seal(root);
    try testing.expectEqualSlices(u32, &.{ 0, 0, 1, 1, 0 }, t.c.parent[0..5]);
    try testing.expectEqualSlices(u32, &.{ 5, 4, 3, 4, 5 }, t.c.end[0..5]);
    try testing.expectEqualSlices(f32, &.{ 2, 2, 0, 0, 0 }, t.c.nkids[0..5]);
    try t.check();
}

test "find returns the first row with an id or none; rect reads the four rect columns" {
    var fx: Fixture(40) = .{};
    var t = fx.tree();
    const row = Id.from("row");
    for (0..37) |k| _ = t.push(0, row.with(@intCast(k)), &.{});
    _ = t.push(0, row.with(5), &.{}); // a duplicate: the first row wins
    try testing.expectEqual(0, t.find(row.with(0)));
    try testing.expectEqual(5, t.find(row.with(5)));
    try testing.expectEqual(36, t.find(row.with(36)));
    try testing.expectEqual(none, t.find(row.with(99)));
    // Rows past len are ignored even when they hold the id.
    t.len = 30;
    try testing.expectEqual(none, t.find(row.with(31)));

    t.c.rect[0][3] = 1;
    t.c.rect[1][3] = 2;
    t.c.rect[2][3] = 30;
    t.c.rect[3][3] = 40;
    try testing.expectEqual(Rect{ .x0 = 1, .y0 = 2, .x1 = 30, .y1 = 40 }, t.rect(3));
}

test "running out of rows is reported, not fatal" {
    var fx: Fixture(8) = .{};
    var t = fx.tree();
    const root = t.push(0, .none, &.{});
    for (1..8) |_| _ = t.push(root, .none, &.{});
    try testing.expect(!t.overflow);
    try testing.expectEqual(8, t.len);
    // Pushes past cap keep rewriting the last row; len and every write stay in bounds.
    for (0..40) |k| try testing.expectEqual(7, t.push(root, Id.from("n").with(@intCast(k)), &.{}));
    try testing.expect(t.overflow);
    try testing.expectEqual(8, t.len);
    try testing.expectEqual(@backingInt(Id.from("n").with(39)), t.c.id[7]);
    t.reset();
    try testing.expect(!t.overflow);
    try testing.expectEqual(0, t.len);
}

test "check: parent < child and end ranges nest, and each break is named" {
    var fx: Fixture(8) = .{};
    var t = fx.tree();
    try t.check(); // empty
    // root { a { a1 a2 } b }
    const root = t.push(0, .none, &.{});
    const a = t.push(root, .none, &.{});
    t.seal(t.push(a, .none, &.{}));
    t.seal(t.push(a, .none, &.{}));
    t.seal(a);
    t.seal(t.push(root, .none, &.{}));
    t.seal(root);
    try t.check();
    t.validate();

    const parent: [5]u32 = t.c.parent[0..5].*;
    const end: [5]u32 = t.c.end[0..5].*;
    const Case = struct { row: u32, parent: ?u32 = null, end: ?u32 = null, err: Tree.Invalid };
    const cases = [_]Case{
        .{ .row = 0, .parent = 1, .err = error.RootParent },
        .{ .row = 2, .parent = 3, .err = error.ParentNotBefore },
        .{ .row = 2, .parent = 2, .err = error.ParentNotBefore },
        .{ .row = 3, .end = 3, .err = error.EndOutOfRange },
        .{ .row = 0, .end = 6, .err = error.EndOutOfRange },
        // a1 claims a2 as its child while a2 says its parent is a.
        .{ .row = 2, .end = 4, .err = error.RangesCross },
        // a2 says its parent is the root, but a's range still contains it.
        .{ .row = 3, .parent = 0, .err = error.RangesCross },
        // b claims to be inside a, whose range closed before b.
        .{ .row = 4, .parent = 1, .err = error.RangesCross },
        // a's range swallows b, whose parent is the root.
        .{ .row = 1, .end = 5, .err = error.RangesCross },
    };
    for (cases) |k| {
        @memcpy(t.c.parent[0..5], &parent);
        @memcpy(t.c.end[0..5], &end);
        if (k.parent) |v| t.c.parent[k.row] = v;
        if (k.end) |v| t.c.end[k.row] = v;
        try testing.expectError(k.err, t.check());
    }
    @memcpy(t.c.parent[0..5], &parent);
    @memcpy(t.c.end[0..5], &end);
    try t.check();
    t.len = 9;
    try testing.expectError(error.LenOverCap, t.check());
}

test "TreeOf: u32 slices are the runtime tree; a small index type with array storage is the same tree" {
    try testing.expectEqual([]u32, @FieldType(Tree.Columns, "parent"));
    // The comptime probe's 8-node UI indexes with u4.
    const Small = TreeOf(u4, .{ .array = 8 });
    const rows = comptime simd.rows(8);
    try testing.expectEqual([rows]u4, @FieldType(Small.Columns, "parent"));
    try testing.expectEqual([2][rows]f32, @FieldType(Small.Columns, "min"));
    try testing.expectEqual([rows]u32, @FieldType(Small.Columns, "id"));
    try testing.expectEqual(u4, @typeInfo(@TypeOf(Small.push)).@"fn".return_type.?);

    // Build the probe's tree, col { label, row { checkbox, slider }, row { label, slider } },
    // in both forms; every column agrees row for row.
    var small: Small = .empty;
    var fx: Fixture(8) = .{};
    var big = fx.tree();
    const shape = [_]struct { parent: u4, close: u4 }{
        .{ .parent = 0, .close = 0 }, .{ .parent = 0, .close = 1 }, .{ .parent = 0, .close = 0 },
        .{ .parent = 2, .close = 1 }, .{ .parent = 2, .close = 2 }, .{ .parent = 0, .close = 0 },
        .{ .parent = 5, .close = 1 }, .{ .parent = 5, .close = 3 },
    };
    var open: [3]u4 = undefined;
    var depth: usize = 0;
    for (shape, 0..) |n, k| {
        const id = Id.from("n").with(@intCast(k));
        const s: Style = .{ .gap = @floatFromInt(k), .pad = @splat(8) };
        const i = small.push(n.parent, id, &s);
        try testing.expectEqual(@as(u32, i), big.push(n.parent, id, &s));
        open[depth] = i;
        depth += 1;
        for (0..n.close) |_| {
            depth -= 1;
            small.seal(open[depth]);
            big.seal(open[depth]);
        }
    }
    try testing.expectEqual(0, depth);
    try small.check();
    try big.check();
    try testing.expectEqualSlices(u4, &.{ 0, 0, 0, 2, 2, 0, 5, 5 }, small.c.parent[0..8]);
    try testing.expectEqualSlices(u4, &.{ 8, 2, 5, 4, 5, 8, 7, 8 }, small.c.end[0..8]);
    for (0..8) |k| {
        try testing.expectEqual(big.c.parent[k], small.c.parent[k]);
        try testing.expectEqual(big.c.end[k], small.c.end[k]);
        try testing.expectEqual(big.c.gap[k], small.c.gap[k]);
        try testing.expectEqual(big.c.nkids[k], small.c.nkids[k]);
    }
    try testing.expectEqual(4, small.find(Id.from("n").with(4)));
    try testing.expectEqual(none, small.find(Id.from("absent")));
    // Overflow is reported the same way.
    for (0..3) |_| _ = small.push(0, .none, &.{});
    try testing.expect(small.overflow);
    try testing.expectEqual(8, small.len);
}

test "TreeOf: a capacity of maxInt(Index) fits, as Ui().Index = IntFittingRange(0, n) needs" {
    // end[i] is at most cap, so cap == maxInt(Index) is the largest capacity Index can describe.
    var t: TreeOf(u3, .{ .array = 7 }) = .empty;
    const root = t.push(0, .none, &.{});
    for (1..7) |_| _ = t.push(root, .none, &.{});
    t.seal(root);
    try testing.expectEqual(@as(u3, 7), t.c.end[0]);
    try testing.expect(!t.overflow);
}
