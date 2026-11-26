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

/// One row of a tree's paint extras (`Tree.Extras`). Extern: C++ and Rust write a row's first
/// five fields in place (`lcgf_extra`, src/abi/runtime.zig's `CView`).
pub const Extra = extern struct {
    /// `Style.border`. Read by finalize (children clip inside it), inherit and paint.
    border: f32,
    /// `Style.uv`.
    uv: [4]f32,
    /// Corner radii, negative corners already taken from `Style.radius` (row 0 keeps
    /// -1: `radiiOf` with the node's `Look.radius`).
    radii: [4]f32,
    /// `Style.opacity` of this node alone.
    opacity: f32,
    /// `Style.transform` of this node alone, about its centre.
    transform: [6]f32,
    transform_origin: [2]f32 = .{ 0.5, 0.5 },
    paint_reference: u32 = none,
    paint_outset: [4]f32 = .{ 0, 0, 0, 0 },
    /// Prepared RGBA owns border/radius painting; layout still reads the original border.
    prepared_texture: u32 = 0,
    paint_revision: u32 = 0,
    participation: types.Participation = .all,
    active_participation: types.Participation = .all,
    cursor: u8 = 255,
    active_cursor: u8 = 255,
    /// Opacity paint applies: the product of `opacity` over the row's node and its
    /// ancestors. Written by `draw.inherit.opacity`.
    alpha: f32,
    /// Layout space to screen after the node's transform and its ancestors'. Written by
    /// `draw.inherit.transform`.
    world: [6]f32,
    /// Corner radii of the clip the row's node hands its children: a clipping node's
    /// radii less its border, otherwise the parent's. Written by `draw.inherit.clip`.
    clip_radii: [4]f32,

    /// Row 0: what a node without extras paints with.
    pub const defaults: Extra = .{
        .border = 0,
        .uv = .{ 0, 0, 1, 1 },
        .radii = @splat(-1),
        .opacity = 1,
        .transform = .{ 1, 0, 0, 1, 0, 0 },
        .alpha = 1,
        .world = .{ 1, 0, 0, 1, 0, 0 },
        .clip_radii = @splat(0),
    };
};

/// How a node is painted. One row per node in `Tree.Columns.look`: paint reads all of these
/// together and layout reads none, so they are one cold row instead of six hot columns.
/// 32 bytes with `params` first, so rows and `params` are 16-byte aligned. The border width is
/// in the tree's `Extras` rows (`Tree.border`): finalize and `draw.inherit.clip` read it alone
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
/// `[2]f32` fields go to the two axis columns. The fields from `own` on are the node's
/// `Extras` row, written only when `own` is 1 (docs/perf/port-perf.md).
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
    role: u8,
    value: f32,
    text: u32 = none,
    custom: u32 = none,
    // ---- the extras row
    /// 1 if the node needs an `Extras` row: a paint extra off its default, or `clip` (the
    /// rounded clip it hands its children is its own).
    own: u32,
    border: f32,
    uv: [4]f32,
    radii: [4]f32,
    opacity: f32,
    transform: [6]f32,
    transform_origin: [2]f32 = .{ 0.5, 0.5 },
    paint_reference: u32 = none,
    paint_outset: [4]f32 = .{ 0, 0, 0, 0 },
    /// Prepared RGBA owns border/radius painting; layout still reads the original border.
    prepared_texture: u32 = 0,
    paint_revision: u32 = 0,
    participation: types.Participation = .all,
    cursor: u8 = 255,

    /// Names of the node-column fields, in column order.
    const node_fields = blk: {
        const all = @typeInfo(Template).@"struct".field_names;
        break :blk all[0..std.meta.fieldIndex(Template, "own").?];
    };

    pub fn from(s: *const Style) Template {
        var r: Template = undefined;
        inline for (0..2) |a| {
            const k = @backingInt(s.size[a].kind);
            const v = s.size[a].v;
            // A select, not @max/@min: on a tie or a NaN it is the style's bound on every
            // target (one maxss/minss on x86), so a row made in C++ or Rust is the same bits.
            const lo = v * Size.k_min[k];
            const hi = v * Size.k_max[k] + Size.c_max[k];
            r.min[a] = if (lo > s.min[a]) lo else s.min[a];
            r.max[a] = if (hi < s.max[a]) hi else s.max[a];
            r.grow[a] = v * Size.k_grow[k];
            r.pct[a] = v * Size.k_pct[k] + Size.c_pct[k];
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
        // The fill tints the texture. A texture with no fill shows its own colours: a white
        // tint, else the quad would multiply to nothing and paint would drop it.
        const untinted = @intFromBool(s.texture != .white) & @intFromBool(s.fill.a == 0);
        r.look = .{
            .fill = s.fill.bitsOf() | (0 -% @as(u32, untinted)),
            .border_color = s.border_color.bitsOf(),
            .radius = s.radius,
            .params = s.params,
            .texture = @backingInt(s.texture),
            .material = @backingInt(s.material),
        };
        r.role = @backingInt(s.role);
        r.value = s.value;
        r.text = none;
        r.custom = none;
        // Off-default tests folded into one 4-lane mask, then one reduce: a 6-lane compare of
        // the transform lowered to a lane-by-lane extract (docs/perf/port-perf.md).
        const d: Style = .{};
        const V4 = @Vector(4, f32);
        const t = s.transform;
        const lanes = (@as(V4, s.uv) != @as(V4, d.uv)) | (corners >= @as(V4, @splat(0))) |
            (V4{ t[0], t[1], t[2], t[3] } != V4{ d.transform[0], d.transform[1], d.transform[2], d.transform[3] }) |
            (V4{ s.border, s.opacity, t[4], t[5] } != V4{ d.border, d.opacity, d.transform[4], d.transform[5] });
        r.own = @intFromBool(@reduce(.Or, lanes | (@as(V4, s.paint_outset) != @as(V4, @splat(0))))) | @intFromBool(s.clip) | @intFromBool(s.cursor != null) | @intFromBool(s.paint_reference != none) | @intFromBool(@as(u8, @bitCast(s.participation)) != @as(u8, @bitCast(types.Participation.all)));
        r.border = s.border;
        r.uv = s.uv;
        r.radii = @select(f32, corners < @as(V4, @splat(0)), @as(V4, @splat(s.radius)), corners);
        r.opacity = s.opacity;
        r.transform = s.transform;
        r.transform_origin = s.transform_origin;
        r.paint_reference = s.paint_reference;
        r.paint_outset = s.paint_outset;
        r.prepared_texture = 0;
        r.paint_revision = 0;
        r.participation = s.participation;
        r.cursor = if (s.cursor) |cursor| @backingInt(cursor) else 255;
        return r;
    }
};

/// A `Template` as the C ABI lays it out (`lcgf_row` in src/abi/lcgf.h): one 32-bit word per
/// field, `look` spelled out. C++ and Rust make these; `Tree.pushRow` reads one in place, field
/// by field, so a row from across the seam is never copied into a `Template` first.
pub const FlatRow = extern struct {
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
    clips: u32,
    sense: u32,
    params: [4]f32,
    fill: u32,
    border_color: u32,
    radius: f32,
    texture: u32,
    material: u32,
    role: u32,
    value: f32,
    text: u32,
    custom: u32,
    own: u32,
    border: f32,
    uv: [4]f32,
    radii: [4]f32,
    opacity: f32,
    transform: [6]f32,
    transform_origin: [2]f32,
    paint_reference: u32,
    paint_outset: [4]f32,
    prepared_texture: u32,
    paint_revision: u32,
    /// `Participation`'s bits.
    participation: u32,
    cursor: u32,
};

/// Field `name` of a row, `Template` or `FlatRow`, as the column of that name stores it.
inline fn rowField(row: anytype, comptime name: []const u8) @FieldType(Template, name) {
    const T = @FieldType(Template, name);
    if (@TypeOf(row.*) == Template) return @field(row, name);
    if (comptime std.mem.eql(u8, name, "look")) return .{
        .params = row.params,
        .fill = row.fill,
        .border_color = row.border_color,
        .radius = row.radius,
        .texture = @truncate(row.texture),
        .material = @truncate(row.material),
    };
    return switch (@typeInfo(T)) {
        .int => @truncate(@field(row, name)),
        .@"struct" => |st| @bitCast(@as(st.backing_integer.?, @truncate(@field(row, name)))),
        else => @field(row, name),
    };
}

/// Corner radii as paint reads them: a stored row's own, or, for the shared defaults row's
/// negative corners, the node's `Look.radius` on all four.
pub inline fn radiiOf(stored: [4]f32, radius: f32) [4]f32 {
    const v: @Vector(4, f32) = stored;
    return @select(f32, v < @as(@Vector(4, f32), @splat(0)), @as(@Vector(4, f32), @splat(radius)), v);
}

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
        x: Extras,
        /// Rows of `x` in use, row 0 included.
        xlen: u32 = 1,

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
            // ---- semantics, read by the host to build an accessibility tree
            role: Col(u8),
            value: Col(f32),

            // ---- links into the side lists, or `none`
            text: Col(u32),
            /// The node's own `Extras` row, or 0, the shared row of defaults.
            extra: Col(u32),
            /// The `Extras` row whose inherited paint state (`alpha`, `world`) the node takes:
            /// its own, else its parent's `scope`. 0 when no ancestor has a row.
            scope: Col(u32),
            custom: Col(u32),
        };

        /// A column of `Extras`: `cap + 1` rows (row 0 holds the defaults, then at most one
        /// per node), padded like every column.
        fn XCol(comptime T: type) type {
            return switch (storage) {
                .slice => []T,
                .array => |n| [simd.rows(n + 1)]T,
            };
        }

        /// Side table of the paint extras a few nodes set (docs/perf/port-perf.md): one row per
        /// node with a non-default `border`, `uv`, `radii`, `opacity` or `transform`, or with
        /// `clip`, appended by `push` in node order. Row 0 holds the defaults every other node
        /// reads through `Columns.extra`. `node` is a column (reuse ranks it); the rest is one
        /// `Extra` row, since every reader gathers a whole row by index: the few rows a frame
        /// uses then share a page or two instead of one page per column.
        pub const Extras = struct {
            node: XCol(u32),
            row: XCol(Extra),
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
            var t: Self = .{ .cap = cap, .c = carver.columns(Columns, rows(cap)), .x = carver.columns(Extras, rows(cap + 1)) };
            if (t.x.node.len > 0) t.reset();
            return t;
        }

        /// The layout scratch columns: every layout run rewrites them before reading them
        /// (`layout.prepare` zeroes or sets the accumulators, `fit` writes the rest), and nothing
        /// outside a layout run reads them.
        pub const scratch = [_][]const u8{ "fit", "nat", "grow_sum", "grow_inv", "used", "gap_total", "cursor" };

        /// `init`, except the `scratch` columns are `other`'s, not carved: two trees that are
        /// never laid out at the same time (the runtime front end's two generations) share them.
        /// Saves 48 bytes per node of capacity (docs/perf/bytes.md). Slice storage only.
        pub fn initSharing(carver: *mem.Carver, cap: u32, other: *const Self) Self {
            comptime std.debug.assert(storage == .slice);
            std.debug.assert(cap > 0 and cap <= std.math.maxInt(Index) and cap == other.cap);
            var c: Columns = undefined;
            const info = @typeInfo(Columns).@"struct";
            inline for (info.field_names, info.field_types) |name, FT| {
                if (comptime isScratch(name)) {
                    @field(c, name) = @field(other.c, name);
                } else switch (@typeInfo(FT)) {
                    .pointer => |p| @field(c, name) = carver.slice(p.child, rows(cap)),
                    .array => |a| inline for (0..a.len) |k| {
                        @field(c, name)[k] = carver.slice(@typeInfo(a.child).pointer.child, rows(cap));
                    },
                    else => unreachable,
                }
            }
            var t: Self = .{ .cap = cap, .c = c, .x = carver.columns(Extras, rows(cap + 1)) };
            if (t.x.node.len > 0) t.reset();
            return t;
        }
        fn isScratch(comptime name: []const u8) bool {
            for (scratch) |s| if (std.mem.eql(u8, s, name)) return true;
            return false;
        }
        /// An empty tree with zeroed columns. Array storage only: the value holds every row.
        pub const empty = if (storage == .array) blk: {
            @setEvalBranchQuota(100_000);
            var t = Self{ .cap = storage.array, .c = std.mem.zeroes(Columns), .x = std.mem.zeroes(Extras) };
            t.reset();
            break :blk t;
        } else {};
        /// Empties the tree for the next frame. Columns keep their memory and stale rows; every
        /// row is rewritten before it is read again. Row 0 of `x` is set to the defaults.
        pub fn reset(t: *Self) void {
            t.len = 0;
            t.overflow = false;
            t.xlen = 1;
            t.x.node[0] = 0;
            t.x.row[0] = .defaults;
        }

        /// Appends a node as the last child of `parent` and returns its row. One row write
        /// per column, an `Extras` row only for a style that has one; no searching, no
        /// allocation. `s` must not point into the tree (`noalias`: the loads of the extras
        /// then move inside `pushRow`'s one branch).
        pub fn push(t: *Self, parent: Index, id: Id, noalias s: *const Style) Index {
            return t.pushRow(parent, id, &Template.from(s));
        }

        /// `push` from a style already turned into its row (`Template.from`, once per style
        /// rather than once per node): the row is copied as it is, one store per column.
        /// `row` is a `*const Template` or a `*const FlatRow`.
        pub fn pushRow(t: *Self, parent_in: Index, id: Id, row: anytype) Index {
            const c = &t.c;
            const i: Index = @intCast(@min(t.len, t.cap - 1));
            t.overflow = simd.orB(t.overflow, t.len >= t.cap);
            t.len = i + 1;
            // Full, the last row is rewritten, and a child of the node open there would be its
            // own parent. Every pass relies on parent < row (levels.build read a stale depth
            // and indexed past its table), so the parent is clamped to the row before.
            const parent: Index = @min(parent_in, i -| 1);

            c.id[i] = @backingInt(id);
            c.parent[i] = parent;
            c.end[i] = i + 1;
            inline for (Template.node_fields) |name| {
                const v = rowField(row, name);
                if (@TypeOf(@field(c, name)) == [2]Col(f32)) {
                    inline for (0..2) |a| @field(c, name)[a][i] = v[a];
                } else @field(c, name)[i] = v;
            }
            const up = if (i == 0) types.Participation.all else t.x.row[c.scope[parent]].active_participation;
            var active: types.Participation = @bitCast(@as(u8, @bitCast(rowField(row, "participation"))) & @as(u8, @bitCast(up)));
            if (!active.layout) {
                active = .collapsed;
                inline for (0..2) |axis| {
                    c.min[axis][i] = 0;
                    c.max[axis][i] = 0;
                    c.grow[axis][i] = 0;
                    c.pct[axis][i] = -1;
                    c.pad_lo[axis][i] = 0;
                    c.pad_hi[axis][i] = 0;
                }
                c.flow[i] = 0;
                c.gap[i] = 0;
            }
            c.role[i] &= 0 -% @as(u8, @intFromBool(active.semantics));
            c.sense[i] &= 0 -% @as(u8, @intFromBool(active.hit));
            // Count this node in its parent, then clear its own count. The root is its own
            // parent, so the clear also removes its self-count: no `i != 0` test, which
            // Zig 0.18's LLVM turned back into a branch. Every other row has parent < i.
            c.nkids[parent] += c.flow[i];
            c.nkids[i] = 0;

            // The extras row, appended when the style has one. `xlen <= cap + 1` holds while
            // the tree has room; past it the last row is overwritten, as `len` is.
            const own = row.own != 0;
            const r = @min(t.xlen, t.cap);
            t.xlen = r + row.own;
            c.extra[i] = simd.selU(own, r, 0);
            // The root reads its own `scope` as its parent's: 0 first (see `nkids`).
            c.scope[i] = 0;
            c.scope[i] = simd.selU(own, r, c.scope[parent]);
            // One branch, taken by the few nodes with extras (well predicted). Writing every
            // node's extras to a spare row instead, with no branch, measured 156 against
            // 149 us of rows build: `push` (noalias style) computes them only in here
            // (docs/perf/port-perf.md).
            if (!own) return i;
            t.x.node[r] = i;
            const x = &t.x.row[r];
            x.border = row.border;
            x.uv = row.uv;
            x.radii = row.radii;
            x.opacity = row.opacity;
            x.transform = row.transform;
            x.transform_origin = rowField(row, "transform_origin");
            // The paint passes read the source's rect, clip and transform and rely on it being
            // an earlier row: a reference to this row or a later one paints from the node itself.
            const reference = rowField(row, "paint_reference");
            x.paint_reference = if (reference < i) reference else none;
            x.paint_outset = rowField(row, "paint_outset");
            x.prepared_texture = rowField(row, "prepared_texture");
            x.paint_revision = rowField(row, "paint_revision");
            x.participation = rowField(row, "participation");
            x.active_participation = active;
            x.cursor = rowField(row, "cursor");
            x.active_cursor = if (rowField(row, "cursor") != 255) rowField(row, "cursor") else if (i == 0) 255 else t.x.row[c.scope[parent]].active_cursor;
            return i;
        }

        /// Effective pointer shape, available while building without an extra ancestor walk.
        pub fn cursor(t: *const Self, i: u32) ?types.Cursor {
            const value = t.x.row[t.c.scope[i]].active_cursor;
            return if (value == 255) null else @fromBackingInt(value);
        }

        /// Effective subtree participation, available immediately while building.
        pub fn participation(t: *const Self, i: u32) types.Participation {
            return t.x.row[t.c.scope[i]].active_participation;
        }

        /// Border width of node `i` (`Style.border`).
        pub fn border(t: *const Self, i: u32) f32 {
            return t.x.row[t.c.extra[i]].border;
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
    // u32 links (with extra and scope), layout inputs, scratch, outputs, child clip, three u8
    // flags, look, role, value. The paint extras are a side table (`Extras`).
    try testing.expectEqual(4 * 7 + 4 * (9 * 2 + 6) + 4 * (5 * 2 + 2) + 4 * 12 + 16 + 3 + @sizeOf(Look) + 1 + 4, rowBytes(Tree.Columns));
    try testing.expectEqual(4 + 4 + 16 + 16 + 4 + 24 + 8 + 4 + 16 + 8 + 4 + 24 + 16 + 4, rowBytes(Tree.Extras));
    try testing.expectEqual(148, @sizeOf(Extra));
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
    try testing.expectEqual([4]f32{ 4, 4, 4, 4 }, radiiOf(t.x.row[c.extra[a]].radii, c.look[a].radius));
    // Only the clipping root has an extras row; the others read row 0, the defaults.
    try testing.expectEqualSlices(u32, &.{ 1, 0, 0 }, c.extra[0..3]);
    try testing.expectEqualSlices(u32, &.{ 1, 1, 1 }, c.scope[0..3]);
    try testing.expectEqual(2, t.xlen);
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
    try testing.expectEqual(a.xlen, b.xlen);
    inline for (@typeInfo(Tree.Extras).@"struct".field_names) |name|
        try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(@field(a.x, name)[0..a.xlen]), std.mem.sliceAsBytes(@field(b.x, name)[0..a.xlen]));
}

test "push: a row in Extras only for a style with a paint extra or a clip; scope follows it down" {
    var fx: Fixture(8) = .{};
    var t = fx.tree();
    const root = t.push(0, .none, &.{});
    const faded = t.push(root, .none, &.{ .opacity = 0.5, .radii = .{ -1, 2, -1, 3 }, .radius = 4 });
    const kid = t.push(faded, .none, &.{ .radius = 9 });
    const moved = t.push(kid, .none, &.{ .transform = .{ 2, 0, 0, 2, 1, 1 } });
    const plain = t.push(root, .none, &.{ .fill = .rgb(1, 1, 1) });
    const clipped = t.push(root, .none, &.{ .clip = true });
    const c = t.c;
    try testing.expectEqualSlices(u32, &.{ 0, 1, 0, 2, 0, 3 }, &.{ c.extra[root], c.extra[faded], c.extra[kid], c.extra[moved], c.extra[plain], c.extra[clipped] });
    try testing.expectEqualSlices(u32, &.{ 0, 1, 1, 2, 0, 3 }, &.{ c.scope[root], c.scope[faded], c.scope[kid], c.scope[moved], c.scope[plain], c.scope[clipped] });
    try testing.expectEqual(4, t.xlen);
    try testing.expectEqualSlices(u32, &.{ faded, moved, clipped }, t.x.node[1..4]);
    try testing.expectEqual(0.5, t.x.row[1].opacity);
    try testing.expectEqual([4]f32{ 4, 2, 4, 3 }, t.x.row[1].radii);
    try testing.expectEqual([4]f32{ 9, 9, 9, 9 }, radiiOf(t.x.row[c.extra[kid]].radii, c.look[kid].radius));
    try testing.expectEqual([6]f32{ 2, 0, 0, 2, 1, 1 }, t.x.row[2].transform);
    // reset empties the table back to its defaults row.
    t.reset();
    try testing.expectEqual(1, t.xlen);
    try testing.expectEqual(1, t.x.row[0].opacity);
}

test "push: a paint reference to the node itself or a later row becomes none" {
    var fx: Fixture(8) = .{};
    var t = fx.tree();
    const root = t.push(0, Id.from("root"), &.{});
    const kept = t.push(root, Id.from("kept"), &.{ .paint_reference = root });
    const self = t.push(root, Id.from("self"), &.{ .paint_reference = 2 });
    const later = t.push(root, Id.from("later"), &.{ .paint_reference = 7 });
    try testing.expectEqual(root, t.x.row[t.c.extra[kept]].paint_reference);
    try testing.expectEqual(none, t.x.row[t.c.extra[self]].paint_reference);
    try testing.expectEqual(none, t.x.row[t.c.extra[later]].paint_reference);
}

test "initSharing: a second tree shares the scratch columns and carves the rest" {
    const cap = 10;
    const one = comptime blk: {
        @setEvalBranchQuota(20_000);
        var counter: mem.Carver = .{ .buf = null };
        _ = Tree.init(&counter, cap);
        break :blk counter.off;
    };
    var buf: [2 * one]u8 align(mem.column_align) = undefined;
    var carver: mem.Carver = .{ .buf = &buf };
    const a = Tree.init(&carver, cap);
    const b = Tree.initSharing(&carver, cap, &a);
    // 7 scratch columns, 5 of them per axis: 12 columns of rows(cap) f32 not carved twice.
    try testing.expectEqual(one + one - 12 * std.mem.alignForward(usize, Tree.rows(cap) * 4, mem.column_align), carver.off);
    try testing.expectEqual(a.c.fit[0].ptr, b.c.fit[0].ptr);
    try testing.expectEqual(a.c.cursor.ptr, b.c.cursor.ptr);
    try testing.expect(a.c.rect[0].ptr != b.c.rect[0].ptr);
    try testing.expect(a.c.id.ptr != b.c.id.ptr);
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
