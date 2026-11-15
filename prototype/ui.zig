//! ui.zig: a data-oriented immediate-mode UI core. Targets Zig 0.17.1.
//!
//!     zig test example.zig      usage, and the tests for this file
//!     zig test ui_wgpu.zig      the renderer tier
//!
//! TIERS (each tier is written only in terms of the tiers above it in this list)
//!   0  Plain data and free functions over columns:
//!        simd, mem, Tree, Texts, Customs, layout, hit, paint, fonts, Anims, Signals
//!   1  Context / Frame: owns the columns, sequences the tier-0 passes
//!   2  Conveniences on the public API only: widgets, Cell, Frame.reuse, Frame.animate
//!   Rendering is a separate file (ui_wgpu.zig). Nothing here knows about GPUs,
//!   windows, fonts or allocators.
//!
//! RULES THIS FILE KEEPS
//!   Data-oriented   Per-node properties are columns (struct of arrays), grouped
//!                   by which pass reads them. Fields that are always read
//!                   together (paint, child clip) are one row instead. Nodes,
//!                   text runs and custom draws refer to each other by u32
//!                   index, never by pointer.
//!   SIMD            Column lengths are padded to whole vectors, so batch passes
//!                   have no scalar tail. Passes whose rows are independent
//!                   (scratch reset, reciprocals, pixel snapping, hit testing,
//!                   id lookup, text measuring, springs) are written with
//!                   @Vector rather than left to auto-vectorization. Passes
//!                   that follow parent links are scalar: a child needs its
//!                   parent's result first.
//!   Branchless      No data-dependent branches in per-row loops: selects are
//!                   masks, modes are coefficients or table indices, filtering is
//!                   "write always, advance by a 0/1 count". What remains is
//!                   loop control, and one coarse branch per memoized subtree.
//!   API design      The caller owns memory, the loop and the frame. No callbacks:
//!                   text measurement, platform effects and custom drawing all
//!                   cross the boundary as data. Every one-call shortcut is a few
//!                   lines of the lower tier, shown right next to it.

const std = @import("std");

pub const inf = std.math.inf(f32);
/// "No index" for every u32 link in this file.
pub const none: u32 = 0xffff_ffff;

// ============================================================================
// simd: vector width, column access, branch-free scalar selects
// ============================================================================

pub const simd = struct {
    /// f32/u32 lanes per vector on the build target (8 with AVX2, 4 with SSE2/NEON).
    pub const lanes: comptime_int = std.simd.suggestVectorLength(f32) orelse 4;
    pub const F = @Vector(lanes, f32);
    pub const U = @Vector(lanes, u32);
    pub const B = @Vector(lanes, bool);
    pub const Bytes = @Vector(lanes, u8);
    /// One bit per lane.
    pub const Mask = @Int(.unsigned, lanes);
    pub const iota: U = std.simd.iota(u32, lanes);

    /// Rows are rounded up to whole vectors so batch loops need no scalar tail.
    pub inline fn padded(n: usize) usize {
        return std.mem.alignForward(usize, n, lanes);
    }
    pub inline fn loadF(col: []const f32, i: usize) F {
        return col[i..][0..lanes].*;
    }
    pub inline fn storeF(col: []f32, i: usize, v: F) void {
        col[i..][0..lanes].* = v;
    }
    pub inline fn loadU(col: []const u32, i: usize) U {
        return col[i..][0..lanes].*;
    }
    pub inline fn storeU(col: []u32, i: usize, v: U) void {
        col[i..][0..lanes].* = v;
    }
    pub inline fn f(x: f32) F {
        return @splat(x);
    }
    pub inline fn u(x: u32) U {
        return @splat(x);
    }
    pub inline fn bits(m: B) Mask {
        return @bitCast(m);
    }

    /// `c ? a : b` without a branch.
    pub inline fn selU(c: bool, a: u32, b: u32) u32 {
        const m = -%@as(u32, @intFromBool(c));
        return b ^ ((a ^ b) & m);
    }
    /// `c ? a : b` without a branch. A bit-level select, so inf and NaN pass through.
    pub inline fn selF(c: bool, a: f32, b: f32) f32 {
        return @bitCast(selU(c, @bitCast(a), @bitCast(b)));
    }
    /// 1.0 or 0.0, built from the bit pattern so that it stays a mask
    /// operation instead of becoming a compare-and-jump.
    pub inline fn b2f(c: bool) f32 {
        return @bitCast(-%@as(u32, @intFromBool(c)) & @as(u32, 0x3f80_0000));
    }
    /// `a and b` as one bitwise AND, with no short-circuit jump.
    pub inline fn andB(a: bool, b: bool) bool {
        return (@intFromBool(a) & @intFromBool(b)) != 0;
    }
    /// `a or b` as one bitwise OR.
    pub inline fn orB(a: bool, b: bool) bool {
        return (@intFromBool(a) | @intFromBool(b)) != 0;
    }

    /// First index of `needle` in `col[0..len]`, or `none`.
    /// Compares `lanes` values per step and never exits early.
    pub fn find(col: []const u32, len: u32, needle: u32) u32 {
        var found: u32 = none;
        const n = padded(len);
        var i: usize = 0;
        while (i < n) : (i += lanes) {
            const base: u32 = @intCast(i);
            const in_range = (iota + u(base)) < u(len);
            const m = bits((loadU(col, i) == u(needle)) & in_range);
            const idx = base + @as(u32, @ctz(m));
            found = selU(andB(m != 0, found == none), idx, found);
        }
        return found;
    }

    /// Number of values in `col[0..len]` that are below `bound`.
    /// On a sorted column this is the insertion index.
    pub fn rank(col: []const u32, len: u32, bound: u32) u32 {
        var acc: U = @splat(0);
        const n = padded(len);
        var i: usize = 0;
        while (i < n) : (i += lanes) {
            const in_range = (iota + u(@intCast(i))) < u(len);
            acc += @intFromBool((loadU(col, i) < u(bound)) & in_range);
        }
        return @reduce(.Add, acc);
    }
};

// Short names for the rest of the file.
const W = simd.lanes;
const pickU = simd.selU;
const pickF = simd.selF;
const b01 = simd.b2f;
const both = simd.andB;
const either = simd.orB;

// ============================================================================
// Small value types
// ============================================================================

/// Stable identity of a widget across frames. 0 means "anonymous".
pub const Id = enum(u32) {
    none = 0,
    _,

    /// Compile-time hash of a name: `Id.from("save")`.
    pub fn from(comptime name: []const u8) Id {
        return @fromBackingInt(comptime nonZero(std.hash.Fnv1a_32.hash(name)));
    }
    /// Compile-time hash of a call site: `Id.src(@src())`.
    pub fn src(comptime loc: std.lang.SourceLocation) Id {
        return from(loc.module ++ ":" ++ loc.file ++ ":" ++ std.fmt.comptimePrint("{d}:{d}", .{ loc.line, loc.column }));
    }
    /// Run-time hash, for ids built from data.
    pub fn hash(bytes: []const u8) Id {
        return @fromBackingInt(nonZero(std.hash.Fnv1a_32.hash(bytes)));
    }
    /// Derives a child id, for widgets created in a loop: `row_id.with(i)`.
    pub fn with(self: Id, n: u32) Id {
        var x = @backingInt(self) ^ (n +% 0x9E37_79B9);
        x = (x ^ (x >> 16)) *% 0x85EB_CA6B;
        x = (x ^ (x >> 13)) *% 0xC2B2_AE35;
        return @fromBackingInt(nonZero(x ^ (x >> 16)));
    }
    inline fn nonZero(h: u32) u32 {
        return h + @intFromBool(h == 0);
    }
};

/// Index of a node in the current frame's `Tree`. Valid until the next `begin`.
pub const Node = enum(u32) {
    root = 0,
    none = none,
    _,
    pub inline fn ix(n: Node) u32 {
        return @backingInt(n);
    }
};

pub const Axis = enum(u1) { x = 0, y = 1 };

/// RGBA8, laid out so the bytes in memory are r, g, b, a on little-endian hosts.
pub const Color = bitpack struct(u32) {
    r: u8 = 0,
    g: u8 = 0,
    b: u8 = 0,
    a: u8 = 0,

    pub const transparent: Color = .{};
    pub const white: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 };
    pub const black: Color = .{ .a = 255 };

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = 255 };
    }
    pub fn rgba(r: u8, g: u8, b: u8, a: u8) Color {
        return .{ .r = r, .g = g, .b = b, .a = a };
    }
    /// 0xRRGGBBAA
    pub fn hex(v: u32) Color {
        return .{ .r = @truncate(v >> 24), .g = @truncate(v >> 16), .b = @truncate(v >> 8), .a = @truncate(v) };
    }
    pub inline fn bitsOf(c: Color) u32 {
        return @bitCast(c);
    }
};

pub const Rect = extern struct {
    x0: f32 = 0,
    y0: f32 = 0,
    x1: f32 = 0,
    y1: f32 = 0,

    pub inline fn w(r: Rect) f32 {
        return r.x1 - r.x0;
    }
    pub inline fn h(r: Rect) f32 {
        return r.y1 - r.y0;
    }
    pub inline fn array(r: Rect) [4]f32 {
        return .{ r.x0, r.y0, r.x1, r.y1 };
    }
    /// Stored as (x0, y0, -x1, -y1), the intersection of two rects is one @max.
    pub inline fn intersect(a: Rect, b: Rect) Rect {
        const sign: @Vector(4, f32) = .{ 1, 1, -1, -1 };
        const v = @max(@as(@Vector(4, f32), a.array()) * sign, @as(@Vector(4, f32), b.array()) * sign) * sign;
        return .{ .x0 = v[0], .y0 = v[1], .x1 = v[2], .y1 = v[3] };
    }
    pub inline fn contains(r: Rect, x: f32, y: f32) bool {
        return (@intFromBool(x >= r.x0) & @intFromBool(x < r.x1) & @intFromBool(y >= r.y0) & @intFromBool(y < r.y1)) != 0;
    }
};

/// How a node is sized along one axis. Stored as data (kind + value), then
/// turned into coefficients by table lookup, so layout never switches on it.
pub const Size = extern struct {
    kind: Kind = .fit,
    v: f32 = 0,

    pub const Kind = enum(u8) { fit, px, grow, pct };

    /// As large as the content.
    pub const fit: Size = .{};
    /// Take all free space (weight 1).
    pub const fill: Size = .{ .kind = .grow, .v = 1 };
    /// Exactly `v` pixels.
    pub fn px(v: f32) Size {
        return .{ .kind = .px, .v = v };
    }
    /// A share of the parent's free space on its main axis; stretch on its cross axis.
    pub fn grow(weight: f32) Size {
        return .{ .kind = .grow, .v = weight };
    }
    /// A fraction (0..1) of the parent's inner size.
    pub fn pct(fraction: f32) Size {
        return .{ .kind = .pct, .v = fraction };
    }

    // Coefficient tables, indexed by Kind:      fit  px  grow pct
    const k_min = [4]f32{ 0, 1, 0, 0 }; //   min  = v * k_min
    const k_max = [4]f32{ 0, 1, 0, 0 }; //   max  = v * k_max + c_max
    const c_max = [4]f32{ inf, 0, inf, inf };
    const k_grow = [4]f32{ 0, 0, 1, 0 }; //  grow = v * k_grow
    const k_pct = [4]f32{ 0, 0, 0, 1 }; //   pct  = v * k_pct
};

pub const Align = enum(u8) {
    start,
    center,
    end,
    const factor = [3]f32{ 0, 0.5, 1 };
};

/// Handles the renderer gives out. The core only stores and groups by them.
pub const Texture = enum(u16) { white = 0, _ };
pub const Material = enum(u16) { solid = 0, _ };
pub const Font = enum(u16) { default = 0, _ };

/// What kinds of pointer interaction a node takes part in.
pub const Sense = bitpack struct(u8) {
    hover: bool = false,
    click: bool = false,
    drag: bool = false,
    focus: bool = false,
    _: u4 = 0,

    pub const button: Sense = .{ .hover = true, .click = true, .focus = true };
    pub const any: Sense = .{ .hover = true, .click = true, .drag = true, .focus = true };
};

/// Result of `Frame.interact`. A bit set, assembled without branches.
pub const Response = bitpack struct(u8) {
    hovered: bool = false,
    /// Pointer is down and this widget owns it.
    held: bool = false,
    /// Went down this frame.
    pressed: bool = false,
    /// Went up this frame.
    released: bool = false,
    /// Went up this frame over the widget it went down on.
    clicked: bool = false,
    focused: bool = false,
    _: u2 = 0,
};

pub const Role = enum(u8) { none, group, label, button, checkbox, slider, image, text_input };

/// Everything a node can be told at creation. Plain data with defaults.
pub const Style = struct {
    // ---- layout
    /// Axis children are stacked along.
    dir: Axis = .y,
    size: [2]Size = .{ .fit, .fit },
    min: [2]f32 = .{ 0, 0 },
    max: [2]f32 = .{ inf, inf },
    /// left, top, right, bottom
    pad: [4]f32 = .{ 0, 0, 0, 0 },
    gap: f32 = 0,
    /// Where children sit along `dir` when there is space left over.
    main: Align = .start,
    /// Where children sit across `dir`.
    cross: Align = .start,
    /// May become narrower than its content when the parent has no room.
    shrink: bool = false,
    /// Out of flow: placed at the parent's content origin plus `offset`.
    float: bool = false,
    offset: [2]f32 = .{ 0, 0 },
    /// Clip children to this node's rect.
    clip: bool = false,
    /// Subtracted from children's positions (scroll containers).
    scroll: [2]f32 = .{ 0, 0 },
    // ---- paint
    fill: Color = .transparent,
    border_color: Color = .transparent,
    border: f32 = 0,
    radius: f32 = 0,
    texture: Texture = .white,
    material: Material = .solid,
    /// Passed through to the material's shader.
    params: [4]f32 = .{ 0, 0, 0, 0 },
    // ---- semantics
    role: Role = .none,
    value: f32 = 0,
};

pub const TextStyle = struct {
    px: f32 = 14,
    color: Color = .white,
    font: Font = .default,
    wrap: bool = false,
};

// ============================================================================
// mem: columns carved from a caller-owned buffer
// ============================================================================

pub const mem = struct {
    /// Each column starts on its own cache line.
    pub const column_align = 64;

    /// Bump pointer over a caller-owned buffer. With `buf == null` it only
    /// counts, which is how `Context.requiredBytes` and `Context.init` are
    /// guaranteed to agree: they run the same code.
    pub const Carver = struct {
        buf: ?[]align(column_align) u8,
        off: usize = 0,

        pub fn slice(c: *Carver, comptime T: type, n: usize) []T {
            const bytes = std.mem.alignForward(usize, n * @sizeOf(T), column_align);
            const start = c.off;
            c.off += bytes;
            const b = c.buf orelse return &.{};
            std.debug.assert(c.off <= b.len);
            @memset(b[start..c.off], 0);
            const p: [*]T = @ptrCast(@alignCast(b.ptr + start));
            return p[0..n];
        }

        /// Fills a struct whose fields are `[]T` or `[k][]T` with zeroed
        /// columns of `n` rows each.
        pub fn columns(c: *Carver, comptime S: type, n: usize) S {
            var out: S = undefined;
            const info = @typeInfo(S).@"struct";
            inline for (info.field_names, info.field_types) |name, FT| {
                switch (@typeInfo(FT)) {
                    .pointer => |p| @field(out, name) = c.slice(p.child, n),
                    .array => |a| inline for (0..a.len) |k| {
                        @field(out, name)[k] = c.slice(@typeInfo(a.child).pointer.child, n);
                    },
                    else => @compileError("column sets hold only []T and [k][]T fields"),
                }
            }
            return out;
        }
    };

    /// Copies rows [src_at, src_at + n) of every column in `src` to rows
    /// starting at `dst_at` in `dst`.
    pub fn copyRows(comptime S: type, dst: *const S, dst_at: usize, src: *const S, src_at: usize, n: usize) void {
        const info = @typeInfo(S).@"struct";
        inline for (info.field_names, info.field_types) |name, FT| {
            switch (@typeInfo(FT)) {
                .pointer => @memcpy(@field(dst, name)[dst_at..][0..n], @field(src, name)[src_at..][0..n]),
                .array => |a| inline for (0..a.len) |k| {
                    @memcpy(@field(dst, name)[k][dst_at..][0..n], @field(src, name)[k][src_at..][0..n]);
                },
                else => unreachable,
            }
        }
    }
};

// ============================================================================
// Input: one plain struct per frame, filled by the host from any window layer
// ============================================================================

pub const Input = struct {
    /// Seconds since the app started.
    time: f64 = 0,
    /// Seconds since the previous frame.
    dt: f32 = 1.0 / 60.0,
    /// Logical pixels.
    viewport: [2]f32 = .{ 800, 600 },
    /// Physical pixels per logical pixel.
    scale: f32 = 1,
    pointer: [2]f32 = .{ -1, -1 },
    buttons: Buttons = .{},
    wheel: [2]f32 = .{ 0, 0 },
    mods: Mods = .{},
    keys: Keys = .{},
    /// UTF-8 typed this frame. Only read during the frame.
    text: []const u8 = "",

    pub const Buttons = bitpack struct(u8) { left: bool = false, right: bool = false, middle: bool = false, _: u5 = 0 };
    pub const Mods = bitpack struct(u8) { shift: bool = false, ctrl: bool = false, alt: bool = false, cmd: bool = false, _: u4 = 0 };

    /// 256 key states as a bit set. Index with your platform's scancodes.
    pub const Keys = struct {
        bits: [4]u64 = @splat(0),
        pub fn press(k: *Keys, code: u8) void {
            k.bits[code >> 6] |= @as(u64, 1) << @as(u6, @truncate(code));
        }
        pub fn down(k: *const Keys, code: u8) bool {
            return ((k.bits[code >> 6] >> @as(u6, @truncate(code))) & 1) != 0;
        }
    };

    /// Fingerprint of everything except the clock. Equal stamps mean a frame
    /// built from this input would come out identical to the previous one.
    pub fn stamp(in: *const Input) u64 {
        const words = [_]u64{
            @as(u32, @bitCast(in.viewport[0])), @as(u32, @bitCast(in.viewport[1])),
            @as(u32, @bitCast(in.scale)),       @as(u32, @bitCast(in.pointer[0])),
            @as(u32, @bitCast(in.pointer[1])),  @as(u32, @bitCast(in.wheel[0])),
            @as(u32, @bitCast(in.wheel[1])),    @as(u8, @bitCast(in.buttons)),
            @as(u8, @bitCast(in.mods)),         in.keys.bits[0],
            in.keys.bits[1],                    in.keys.bits[2],
            in.keys.bits[3],                    in.text.len,
        };
        var h: u64 = 0xcbf2_9ce4_8422_2325;
        for (words) |w| h = (h ^ w) *% 0x0000_0100_0000_01b3;
        for (in.text) |ch| h = (h ^ ch) *% 0x0000_0100_0000_01b3;
        return h;
    }
};

// ============================================================================
// Tree: the node columns. Rows are in depth-first order, parents before
// children, so a forward sweep is top-down and a reverse sweep is bottom-up.
// ============================================================================

/// How a node is painted. One row per node in `Tree.Columns.look`.
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
    /// `push` ran out of rows. The last row is overwritten; nothing is written out of bounds.
    overflow: bool = false,
    c: Columns,

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
        return simd.padded(cap) + W;
    }
    pub fn init(carver: *mem.Carver, cap: u32) Tree {
        return .{ .cap = cap, .c = carver.columns(Columns, rows(cap)) };
    }
    pub fn reset(t: *Tree) void {
        t.len = 0;
        t.overflow = false;
    }

    /// Appends a node as the last child of `parent` and returns its row.
    /// One row write per column; no searching, no allocation.
    pub fn push(t: *Tree, parent: u32, id: Id, s: *const Style) u32 {
        const c = &t.c;
        const i = @min(t.len, t.cap - 1);
        t.overflow = either(t.overflow, t.len >= t.cap);
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

    /// Closes node `i`: everything pushed since belongs to its subtree.
    pub fn seal(t: *Tree, i: u32) void {
        t.c.end[i] = t.len;
    }

    pub fn rect(t: *const Tree, i: u32) Rect {
        return .{ .x0 = t.c.rect[0][i], .y0 = t.c.rect[1][i], .x1 = t.c.rect[2][i], .y1 = t.c.rect[3][i] };
    }

    /// Row of the node with `id`, or `none`. SIMD scan of the id column.
    pub fn find(t: *const Tree, id: Id) u32 {
        return simd.find(t.c.id, t.len, @backingInt(id));
    }
};

// ============================================================================
// Side lists: only nodes that have text or a custom draw get a row here
// (existence-based processing instead of a per-node "has text?" branch)
// ============================================================================

pub const Span = struct { start: u32 = 0, bytes: u32 = 0 };

/// Frame-lifetime byte storage for text, so callers may pass temporaries.
pub const Strings = struct {
    buf: []u8,
    len: u32 = 0,
    overflow: bool = false,

    pub fn add(s: *Strings, bytes: []const u8) Span {
        const room = s.buf.len - s.len;
        const n: u32 = @intCast(@min(bytes.len, room));
        s.overflow = either(s.overflow, bytes.len > room);
        @memcpy(s.buf[s.len..][0..n], bytes[0..n]);
        const span: Span = .{ .start = s.len, .bytes = n };
        s.len += n;
        return span;
    }
    pub fn get(s: *const Strings, span: Span) []const u8 {
        return s.buf[span.start..][0..span.bytes];
    }
};

pub const Texts = struct {
    len: u32 = 0,
    cap: u32,
    overflow: bool = false,
    c: Columns,

    pub const Columns = struct {
        node: []u32,
        /// Byte range in the frame's `Strings`.
        start: []u32,
        bytes: []u32,
        px: []f32,
        color: []u32,
        font: []u16,
        /// 1.0 when the run may wrap.
        wrap: []f32,
        /// Written by whoever measures text: extent in pixels.
        w: []f32,
        h: []f32,
        /// Written by `layout.textAvail`: the width layout gave this run.
        avail: []f32,
    };

    pub fn init(carver: *mem.Carver, cap: u32) Texts {
        return .{ .cap = cap, .c = carver.columns(Columns, simd.padded(cap) + W) };
    }
    pub fn reset(tx: *Texts) void {
        tx.len = 0;
        tx.overflow = false;
    }
    pub fn push(tx: *Texts, node: u32, span: Span, ts: *const TextStyle) u32 {
        const k = @min(tx.len, tx.cap - 1);
        tx.overflow = either(tx.overflow, tx.len >= tx.cap);
        tx.len = k + 1;
        tx.c.node[k] = node;
        tx.c.start[k] = span.start;
        tx.c.bytes[k] = span.bytes;
        tx.c.px[k] = ts.px;
        tx.c.color[k] = ts.color.bitsOf();
        tx.c.font[k] = @backingInt(ts.font);
        tx.c.wrap[k] = b01(ts.wrap);
        tx.c.w[k] = 0;
        tx.c.h[k] = 0;
        tx.c.avail[k] = 0;
        return k;
    }
};

pub const Customs = struct {
    len: u32 = 0,
    cap: u32,
    overflow: bool = false,
    c: Columns,

    pub const Columns = struct {
        node: []u32,
        id: []u32,
        /// Opaque to the core; handed back in the draw list.
        data: []u64,
    };

    pub fn init(carver: *mem.Carver, cap: u32) Customs {
        return .{ .cap = cap, .c = carver.columns(Columns, simd.padded(cap) + W) };
    }
    pub fn reset(cu: *Customs) void {
        cu.len = 0;
        cu.overflow = false;
    }
    pub fn push(cu: *Customs, node: u32, id: Id, data: u64) u32 {
        const k = @min(cu.len, cu.cap - 1);
        cu.overflow = either(cu.overflow, cu.len >= cu.cap);
        cu.len = k + 1;
        cu.c.node[k] = node;
        cu.c.id[k] = @backingInt(id);
        cu.c.data[k] = data;
        return k;
    }
};

// ============================================================================
// layout: a fixed sequence of linear passes. No solver, no re-measure loop,
// so the cost is the same every frame and proportional to the node count.
//
//   prepare            SIMD     clear scratch, gap totals
//   applyText(.x)      scatter  text widths into leaves
//   fit(.x)            reverse  natural widths, bottom-up (+ SIMD reciprocals)
//   resolve(.x)        forward  final widths, top-down
//   textAvail          gather   widths for wrapping   (caller re-measures here)
//   applyText/fit/resolve(.y)   the same three for heights
//   place              forward  positions on both axes
//   finalize           SIMD + forward   pixel snap, clip, visibility
// ============================================================================

pub const layout = struct {
    /// SIMD. Clears per-frame scratch and derives `gap_total`.
    pub fn prepare(t: *Tree) void {
        const c = &t.c;
        const n = simd.padded(t.len);
        const zero = simd.f(0);
        var i: usize = 0;
        while (i < n) : (i += W) {
            inline for (0..2) |a| {
                simd.storeF(c.fit[a], i, zero);
                simd.storeF(c.grow_sum[a], i, zero);
                simd.storeF(c.used[a], i, zero);
            }
            simd.storeF(c.cursor, i, zero);
            const gaps = @max(simd.loadF(c.nkids, i) - simd.f(1), zero);
            simd.storeF(c.gap_total, i, simd.loadF(c.gap, i) * gaps);
        }
    }

    /// Scatters measured text extents into their leaf nodes for one axis.
    pub fn applyText(t: *Tree, tx: *const Texts, axis: Axis) void {
        const a = @backingInt(axis);
        const extents = [2][]const f32{ tx.c.w, tx.c.h };
        const src = extents[a];
        const dst = t.c.fit[a];
        for (tx.c.node[0..tx.len], src[0..tx.len]) |node, extent| dst[node] = extent;
    }

    /// Bottom-up: natural size of every node on one axis. One reverse sweep.
    pub fn fit(t: *Tree, axis: Axis) void {
        const a = @backingInt(axis);
        if (t.len == 0) return;
        // Column slices are read into locals once, so the loop indexes them
        // directly instead of reloading each slice from the struct.
        const parent = t.c.parent;
        const fit_ = t.c.fit[a];
        const nat_ = t.c.nat[a];
        const main = t.c.main[a];
        const gap_total = t.c.gap_total;
        const lo = t.c.pad_lo[a];
        const hi = t.c.pad_hi[a];
        const min = t.c.min[a];
        const max = t.c.max[a];
        const flow = t.c.flow;
        const grow = t.c.grow[a];
        const grow_sum = t.c.grow_sum[a];

        var i: u32 = t.len;
        while (i > 1) {
            i -= 1;
            // All descendants have larger rows, so fit_[i] is complete here.
            const content = fit_[i] + main[i] * gap_total[i];
            const nat = @min(@max(content + lo[i] + hi[i], min[i]), max[i]);
            nat_[i] = nat;
            // Fold into the parent: a sum along its main axis, a max across it.
            const p = parent[i];
            const contrib = nat * flow[i];
            const sum = fit_[p] + contrib;
            const mx = @max(fit_[p], contrib);
            fit_[p] = mx + main[p] * (sum - mx);
            grow_sum[p] += grow[i] * flow[i];
        }
        // The root has no parent to fold into.
        const content = fit_[0] + main[0] * gap_total[0];
        nat_[0] = @min(@max(content + lo[0] + hi[0], min[0]), max[0]);

        // SIMD: one reciprocal per node, so the top-down sweep has no division
        // on its parent-to-child dependency chain.
        const grow_inv = t.c.grow_inv[a];
        const n = simd.padded(t.len);
        var j: usize = 0;
        while (j < n) : (j += W) {
            simd.storeF(grow_inv, j, simd.f(1) / @max(simd.loadF(grow_sum, j), simd.f(1e-6)));
        }
    }

    /// Top-down: final size of every node on one axis. One forward sweep.
    /// Free space is shared out once by `grow` weight; a child stopped by its
    /// `max` leaves its remainder unused instead of triggering another round.
    pub fn resolve(t: *Tree, axis: Axis, viewport: f32) void {
        const a = @backingInt(axis);
        if (t.len == 0) return;
        const parent = t.c.parent;
        const size = t.c.size[a];
        const nat_ = t.c.nat[a];
        const fit_ = t.c.fit[a];
        const main_ = t.c.main[a];
        const gap_total = t.c.gap_total;
        const lo = t.c.pad_lo[a];
        const hi = t.c.pad_hi[a];
        const min = t.c.min[a];
        const max = t.c.max[a];
        const grow = t.c.grow[a];
        const grow_inv = t.c.grow_inv[a];
        const pct = t.c.pct[a];
        const flow = t.c.flow;
        const shrink = t.c.shrink;
        const used = t.c.used[a];

        size[0] = viewport;
        for (1..t.len) |i| {
            const p = parent[i];
            const nat = nat_[i];
            const inner = @max(size[p] - lo[p] - hi[p], 0);
            const main = main_[p];
            // Along the parent's main axis: natural size plus a share of what is left.
            const taken = fit_[p] + gap_total[p];
            const free = @max(inner - taken, 0);
            const share = free * grow[i] * grow_inv[p];
            // Across it: stretch when the node grows on this axis.
            const stretched = nat + b01(grow[i] > 0) * (inner - nat);
            const flowed = stretched + main * (nat + share - stretched);
            // A percentage replaces both.
            const has_pct = b01(pct[i] > 0);
            const of_parent = pct[i] * inner;
            const in_flow = flowed + has_pct * (of_parent - flowed);
            const floating = nat + has_pct * (of_parent - nat);
            const fl = flow[i];
            var s = floating + fl * (in_flow - floating);
            // Shrinkable nodes give way when the parent has no room for them.
            const room = @max(inner - main * (taken - nat), 0);
            s -= shrink[i] * fl * @max(s - room, 0);
            s = @min(@max(s, min[i]), max[i]);
            size[i] = s;
            used[p] += s * fl;
        }
    }

    /// Gathers the width layout gave each text run. Call after `resolve(.x)`;
    /// the caller then rewrites `h` for runs that wrap.
    pub fn textAvail(t: *const Tree, tx: *Texts) void {
        const c = &t.c;
        for (tx.c.node[0..tx.len], tx.c.avail[0..tx.len]) |node, *avail| {
            avail.* = c.size[0][node] - c.pad_lo[0][node] - c.pad_hi[0][node];
        }
    }

    /// Top-down: position of every node on both axes. One forward sweep.
    pub fn place(t: *Tree) void {
        if (t.len == 0) return;
        const parent = t.c.parent;
        const pos = t.c.pos;
        const size = t.c.size;
        const lo = t.c.pad_lo;
        const hi = t.c.pad_hi;
        const used = t.c.used;
        const main = t.c.main;
        const scroll = t.c.scroll;
        const offset = t.c.offset;
        const gap = t.c.gap;
        const gap_total = t.c.gap_total;
        const cursor = t.c.cursor;
        const flow = t.c.flow;
        const align_main = t.c.align_main;
        const align_cross = t.c.align_cross;

        pos[0][0] = 0;
        pos[1][0] = 0;
        for (1..t.len) |i| {
            const p = parent[i];
            const fl = flow[i];
            inline for (0..2) |a| {
                const inner = size[a][p] - lo[a][p] - hi[a][p];
                const lead = @max(inner - used[a][p] - gap_total[p], 0) * align_main[p];
                const across = @max(inner - size[a][i], 0) * align_cross[p];
                const along = lead + cursor[p];
                const in_flow = across + main[a][p] * (along - across);
                pos[a][i] = pos[a][p] + lo[a][p] - scroll[a][p] + fl * in_flow + offset[a][i];
            }
            // Advance along whichever axis is the parent's main one.
            const step = size[0][i] * main[0][p] + size[1][i] * main[1][p];
            cursor[p] += (step + gap[p]) * fl;
        }
    }

    /// Pixel-snapped rects (SIMD), then clip rects and visibility (one forward
    /// sweep with a 4-lane op per node).
    pub fn finalize(t: *Tree) void {
        const c = &t.c;
        if (t.len == 0) return;
        const n = simd.padded(t.len);
        var j: usize = 0;
        while (j < n) : (j += W) {
            const x = simd.loadF(c.pos[0], j);
            const y = simd.loadF(c.pos[1], j);
            simd.storeF(c.rect[0], j, @round(x));
            simd.storeF(c.rect[1], j, @round(y));
            simd.storeF(c.rect[2], j, @round(x + simd.loadF(c.size[0], j)));
            simd.storeF(c.rect[3], j, @round(y + simd.loadF(c.size[1], j)));
        }
        // Padding rows must never be hit.
        @memset(c.sense[t.len..n], 0);

        const V4 = @Vector(4, f32);
        const sign: V4 = .{ 1, 1, -1, -1 };
        const everything: V4 = @splat(-inf);
        const parent = c.parent;
        const rect = c.rect;
        const vis = c.vis;
        const child_clip = c.child_clip;
        const clips_ = c.clips;
        const visible = c.visible;
        const looks = c.look;
        for (0..t.len) |i| {
            const r = V4{ rect[0][i], rect[1][i], rect[2][i], rect[3][i] } * sign;
            const is_root: @Vector(4, bool) = @splat(i == 0);
            const inherited = @select(f32, is_root, everything, @as(V4, child_clip[parent[i]]));
            const v = @max(r, inherited);
            // Children are clipped to the area inside the border. In the
            // (min, -max) form, insetting all four edges is one add.
            const inner = @max(inherited, r + @as(V4, @splat(looks[i].border)));
            const clips: @Vector(4, bool) = @splat(clips_[i] != 0);
            child_clip[i] = @select(f32, clips, inner, inherited);
            const out = v * sign;
            vis[0][i] = out[0];
            vis[1][i] = out[1];
            vis[2][i] = out[2];
            vis[3][i] = out[3];
            visible[i] = @intFromBool(out[0] < out[2]) & @intFromBool(out[1] < out[3]);
        }
    }

    /// Diagonal: every pass in order, for text that does not wrap (or whose
    /// `w`/`h` the caller has already settled). `Frame.end` is this plus wrapping.
    pub fn run(t: *Tree, tx: *Texts, viewport: [2]f32) void {
        prepare(t);
        applyText(t, tx, .x);
        fit(t, .x);
        resolve(t, .x, viewport[0]);
        textAvail(t, tx);
        applyText(t, tx, .y);
        fit(t, .y);
        resolve(t, .y, viewport[1]);
        place(t);
        finalize(t);
    }
};

// ============================================================================
// hit: which node is under a point
// ============================================================================

pub const hit = struct {
    /// Topmost node under (x, y) that takes part in any interaction in `want`,
    /// or `none`. Tests `lanes` nodes per step and never exits early; later
    /// rows are drawn later, so the highest matching row wins.
    pub fn at(t: *const Tree, x: f32, y: f32, want: Sense) u32 {
        const c = &t.c;
        const px = simd.f(x);
        const py = simd.f(y);
        const wantv: simd.Bytes = @splat(@as(u8, @bitCast(want)));
        const zero: simd.Bytes = @splat(0);
        var found: u32 = none;
        const n = simd.padded(t.len);
        var i: usize = 0;
        while (i < n) : (i += W) {
            const inside = (px >= simd.loadF(c.vis[0], i)) & (px < simd.loadF(c.vis[2], i)) &
                (py >= simd.loadF(c.vis[1], i)) & (py < simd.loadF(c.vis[3], i));
            const senses: simd.Bytes = c.sense[i..][0..W].*;
            const m = simd.bits(inside & ((senses & wantv) != zero));
            // Highest set lane. Wraps when m == 0, and is then discarded.
            const top = @as(u32, W - 1) -% @as(u32, @clz(m));
            found = pickU(m != 0, @as(u32, @intCast(i)) +% top, found);
        }
        return found;
    }
};

// ============================================================================
// Interaction: hover, press, click and focus as one pure step per frame
// ============================================================================

pub const Interaction = struct {
    // Id backing ints; 0 means nothing.
    hot: u32 = 0,
    active: u32 = 0,
    focus: u32 = 0,
    pressed: u32 = 0,
    released: u32 = 0,
    clicked: u32 = 0,
    // Rows in the previous frame's tree, or `none`.
    hot_node: u32 = none,
    active_node: u32 = none,
    pointer: [2]f32 = .{ -1, -1 },
    delta: [2]f32 = .{ 0, 0 },
    buttons: Input.Buttons = .{},

    /// Advances by one frame, from last frame's geometry and this frame's pointer.
    pub fn step(s: *Interaction, prev: *const Tree, in: *const Input) void {
        const node = hit.at(prev, in.pointer[0], in.pointer[1], .any);
        // Clamp instead of branching: the read stays in bounds when nothing is hit.
        const row = @min(node, prev.cap - 1);
        const hot = pickU(node != none, prev.c.id[row], 0);
        const press = both(in.buttons.left, !s.buttons.left);
        const release = both(!in.buttons.left, s.buttons.left);
        const takes_focus = (prev.c.sense[row] & @as(u8, @bitCast(Sense{ .focus = true }))) != 0;

        s.clicked = pickU(both(release, both(s.active == hot, hot != 0)), hot, 0);
        s.released = pickU(release, s.active, 0);
        s.pressed = pickU(press, hot, 0);
        s.focus = pickU(press, pickU(takes_focus, hot, 0), s.focus);
        s.active = pickU(press, hot, pickU(release, 0, s.active));
        s.hot = hot;
        s.hot_node = node;
        s.active_node = pickU(s.active != 0, simd.find(prev.c.id, prev.len, s.active), none);
        s.delta = .{ in.pointer[0] - s.pointer[0], in.pointer[1] - s.pointer[1] };
        s.pointer = in.pointer;
        s.buttons = in.buttons;
    }

    /// What happened to widget `id` this frame.
    pub fn response(s: *const Interaction, id: Id) Response {
        const k = @backingInt(id);
        const valid: u8 = @intFromBool(k != 0);
        // While something is held, only that widget reports hover.
        const unowned: u8 = @intFromBool(s.active == 0) | @intFromBool(s.active == k);
        const hovered: u8 = @intFromBool(k == s.hot) & unowned;
        const held: u8 = @intFromBool(k == s.active);
        const pressed: u8 = @intFromBool(k == s.pressed);
        const released: u8 = @intFromBool(k == s.released);
        const clicked: u8 = @intFromBool(k == s.clicked);
        const focused: u8 = @intFromBool(k == s.focus);
        return @bitCast((hovered | (held << 1) | (pressed << 2) | (released << 3) | (clicked << 4) | (focused << 5)) * valid);
    }
};

// ============================================================================
// Draw list: what the renderer consumes. Flat arrays and indices only.
// ============================================================================

/// One instance of the quad pipeline. This is the GPU vertex-buffer layout,
/// so the whole array uploads with a single copy.
pub const Quad = extern struct {
    /// x0, y0, x1, y1 in logical pixels.
    rect: [4]f32,
    /// Clipping is per instance, so a clip change never splits a batch.
    clip: [4]f32,
    /// Material uniforms.
    params: [4]f32,
    /// u0, v0, u1, v1.
    uv: [4]f32,
    fill: u32,
    border_color: u32,
    radius: f32,
    border: f32,
};

pub const TextRun = extern struct {
    /// Content box of the text node.
    rect: [4]f32,
    clip: [4]f32,
    /// Byte range in `DrawList.strings`.
    start: u32,
    bytes: u32,
    px: f32,
    color: u32,
    font: u32,
};

pub const CustomDraw = extern struct {
    rect: [4]f32,
    clip: [4]f32,
    /// Whatever the caller passed to `Frame.custom`.
    data: u64,
    id: u32,
    node: u32,
};

pub const Batch = struct { first: u32, count: u32, texture: Texture, material: Material };

/// One step for the renderer, in paint order.
pub const Cmd = union(DrawList.Kind) {
    /// A run of `quads` sharing one texture and material.
    quads: Batch,
    /// Index into `runs`.
    text: u32,
    /// Index into `customs`: the caller draws this one itself.
    custom: u32,
};

pub const DrawList = struct {
    quads: []Quad,
    quad_len: u32 = 0,
    runs: []TextRun,
    run_len: u32 = 0,
    customs: []CustomDraw,
    custom_len: u32 = 0,
    /// Storage that `TextRun.start` indexes.
    strings: []const u8 = "",
    /// Commands are stored as columns so they can be produced without
    /// branches; `command` gives the tagged-union view.
    cmd: CmdColumns,
    cmd_len: u32 = 0,
    op: OpColumns,

    pub const Kind = enum(u8) { quads, text, custom };
    pub const CmdColumns = struct { kind: []u8, first: []u32, count: []u32, key: []u32 };
    const OpColumns = struct { kind: []u8, key: []u32, ref: []u32 };

    pub fn init(carver: *mem.Carver, nodes: u32, texts: u32, customs: u32) DrawList {
        // One spare row everywhere: emitters write first and advance after.
        const ops = nodes + texts + customs + 4;
        return .{
            .quads = carver.slice(Quad, nodes + 1),
            .runs = carver.slice(TextRun, texts + 1),
            .customs = carver.slice(CustomDraw, customs + 1),
            .cmd = carver.columns(CmdColumns, ops),
            .op = carver.columns(OpColumns, ops),
        };
    }

    pub fn command(d: *const DrawList, i: u32) Cmd {
        const key = d.cmd.key[i];
        return switch (@as(Kind, @fromBackingInt(d.cmd.kind[i]))) {
            .quads => .{ .quads = .{
                .first = d.cmd.first[i],
                .count = d.cmd.count[i],
                .texture = @fromBackingInt(@as(u16, @truncate(key >> 16))),
                .material = @fromBackingInt(@as(u16, @truncate(key))),
            } },
            .text => .{ .text = d.cmd.first[i] },
            .custom => .{ .custom = d.cmd.first[i] },
        };
    }

    /// The instance data, ready for one buffer write.
    pub fn quadBytes(d: *const DrawList) []const u8 {
        return std.mem.sliceAsBytes(d.quads[0..d.quad_len]);
    }
};

pub const paint = struct {
    /// Tree and side lists in, draw list out. Three linear sweeps.
    pub fn emit(t: *const Tree, tx: *const Texts, cu: *const Customs, strings: []const u8, d: *DrawList) void {
        const c = &t.c;
        const V4 = @Vector(4, f32);
        const sign: V4 = .{ 1, 1, -1, -1 };

        // 1. Nodes -> quads and an ordered op stream. Every row writes its
        //    candidate output; the write index advances by 0 or 1.
        const quads = d.quads;
        const op_kind = d.op.kind;
        const op_key = d.op.key;
        const op_ref = d.op.ref;
        const rect = c.rect;
        const parent = c.parent;
        const child_clip = c.child_clip;
        const looks = c.look;
        var q: u32 = 0;
        var o: u32 = 0;
        for (0..t.len) |i| {
            const vis: u32 = c.visible[i];
            const clip: [4]f32 = @as(V4, child_clip[parent[i]]) * sign;
            const look = looks[i];
            quads[q] = .{
                .rect = .{ rect[0][i], rect[1][i], rect[2][i], rect[3][i] },
                .clip = clip,
                .params = look.params,
                .uv = .{ 0, 0, 1, 1 },
                .fill = look.fill,
                .border_color = look.border_color,
                .radius = look.radius,
                .border = look.border,
            };
            // Painted when either colour has alpha.
            const has_quad = vis & @intFromBool(((look.fill | look.border_color) >> 24) != 0);
            op_kind[o] = @backingInt(DrawList.Kind.quads);
            op_key[o] = (@as(u32, look.texture) << 16) | look.material;
            op_ref[o] = q;
            q += has_quad;
            o += has_quad;

            op_kind[o] = @backingInt(DrawList.Kind.text);
            op_key[o] = 0;
            op_ref[o] = c.text[i];
            o += vis & @intFromBool(c.text[i] != none);

            op_kind[o] = @backingInt(DrawList.Kind.custom);
            op_key[o] = 0;
            op_ref[o] = c.custom[i];
            o += vis & @intFromBool(c.custom[i] != none);
        }
        d.quad_len = q;

        // 2. Side lists -> geometry. One row per text run or custom draw that
        //    exists; nodes without either cost nothing here.
        for (0..tx.len) |k| {
            const n = tx.c.node[k];
            d.runs[k] = .{
                .rect = .{
                    c.rect[0][n] + c.pad_lo[0][n], c.rect[1][n] + c.pad_lo[1][n],
                    c.rect[2][n] - c.pad_hi[0][n], c.rect[3][n] - c.pad_hi[1][n],
                },
                .clip = @as(V4, c.child_clip[c.parent[n]]) * sign,
                .start = tx.c.start[k],
                .bytes = tx.c.bytes[k],
                .px = tx.c.px[k],
                .color = tx.c.color[k],
                .font = tx.c.font[k],
            };
        }
        d.run_len = tx.len;
        for (0..cu.len) |k| {
            const n = cu.c.node[k];
            d.customs[k] = .{
                .rect = .{ c.rect[0][n], c.rect[1][n], c.rect[2][n], c.rect[3][n] },
                .clip = @as(V4, c.child_clip[c.parent[n]]) * sign,
                .data = cu.c.data[k],
                .id = cu.c.id[k],
                .node = n,
            };
        }
        d.custom_len = cu.len;
        d.strings = strings;

        // 3. Ops -> commands by run-length encoding. Consecutive quads with the
        //    same texture and material merge; text and custom ops stand alone.
        var n: u32 = 0;
        var prev_kind: u8 = 0xff;
        var prev_key: u32 = 0;
        for (0..o) |j| {
            const kind = d.op.kind[j];
            const key = d.op.key[j];
            const brk: u32 = @intFromBool(kind != 0) | @intFromBool(kind != prev_kind) | @intFromBool(key != prev_key);
            n += brk;
            const k = n - 1; // the first op always breaks, so n >= 1 here
            d.cmd.kind[k] = kind;
            d.cmd.key[k] = key;
            d.cmd.first[k] = pickU(brk != 0, d.op.ref[j], d.cmd.first[k]);
            d.cmd.count[k] = d.cmd.count[k] * (1 - brk) + 1;
            prev_kind = kind;
            prev_key = key;
        }
        d.cmd_len = n;
    }
};

// ============================================================================
// fonts: the measuring protocol, and a fixed-advance font that implements it
//
// The core never calls into a font. After the tree is built the caller fills
// `Texts.w` and `Texts.h`; after widths are resolved it may rewrite `h` for
// runs that wrap. `Mono` below is that protocol for a fixed-advance font, and
// doubles as the reference for plugging in a real shaper.
// ============================================================================

pub const fonts = struct {
    pub const Mono = struct {
        /// Advance per byte, in ems.
        advance: f32 = 0.6,
        /// Line height, in ems.
        line: f32 = 1.25,

        /// SIMD. Single-line extent of every run.
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

        /// SIMD. Re-flows runs flagged `wrap` into `avail` and rewrites `w`, `h`.
        pub fn wrap(font: Mono, tx: *Texts) void {
            const c = &tx.c;
            const n = simd.padded(tx.len);
            const one = simd.f(1);
            var i: usize = 0;
            while (i < n) : (i += W) {
                const px = simd.loadF(c.px, i);
                const adv = @max(px * simd.f(font.advance), simd.f(1e-6));
                const count: simd.F = @floatFromInt(simd.loadU(c.bytes, i));
                const avail = simd.loadF(c.avail, i);
                const wraps = simd.loadF(c.wrap, i) > simd.f(0);
                const per_line = @max(@floor(avail / adv + simd.f(0.5)), one);
                const lines = @max(@ceil(count / per_line), one);
                const w = simd.loadF(c.w, i);
                simd.storeF(c.w, i, @select(f32, wraps, @min(w, avail), w));
                simd.storeF(c.h, i, @select(f32, wraps, lines, one) * px * simd.f(font.line));
            }
        }

        /// Where glyph quads for run k landed in the output of `quads`.
        pub const Glyphs = struct { first: []u32, count: []u32 };

        /// Expands text runs into glyph quads for a 16x16 byte-indexed atlas.
        /// Returns the number of quads written; stops quietly when `out` is full.
        pub fn quads(font: Mono, d: *const DrawList, out: []Quad, glyphs: Glyphs) u32 {
            var n: u32 = 0;
            const last: u32 = @intCast(out.len - 1);
            for (d.runs[0..d.run_len], 0..) |r, k| {
                const adv = @max(r.px * font.advance, 1e-6);
                const line = r.px * font.line;
                const per_line: u32 = @intFromFloat(@min(@max(@floor((r.rect[2] - r.rect[0]) / adv + 0.5), 1), 1e6));
                glyphs.first[k] = n;
                for (d.strings[r.start..][0..r.bytes], 0..) |byte, j| {
                    const col: f32 = @floatFromInt(j % per_line);
                    const row: f32 = @floatFromInt(j / per_line);
                    const u: f32 = @floatFromInt(byte & 15);
                    const v: f32 = @floatFromInt(byte >> 4);
                    const x = r.rect[0] + col * adv;
                    const y = r.rect[1] + row * line;
                    out[n] = .{
                        .rect = .{ x, y, x + adv, y + line },
                        .clip = r.clip,
                        .params = .{ 0, 0, 0, 0 },
                        .uv = .{ u / 16.0, v / 16.0, (u + 1) / 16.0, (v + 1) / 16.0 },
                        .fill = r.color,
                        .border_color = 0,
                        .radius = 0,
                        .border = 0,
                    };
                    n = @min(n + 1, last);
                }
                glyphs.count[k] = n - glyphs.first[k];
            }
            return n;
        }
    };
};

// ============================================================================
// Anims: every spring in the UI, stepped together
// ============================================================================

pub const Spring = struct {
    stiffness: f32 = 170,
    damping: f32 = 26,
};

pub const Anims = struct {
    len: u32 = 0,
    cap: u32,
    c: Columns,

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
        return .{ .cap = cap, .c = carver.columns(Columns, simd.padded(cap) + W) };
    }

    /// Row for `id`, created resting at `initial` on first use. SIMD lookup.
    pub fn slot(a: *Anims, id: Id, initial: f32) u32 {
        const c = &a.c;
        const k = @backingInt(id);
        const found = simd.find(c.id, a.len, k);
        const is_new = found == none;
        const i = pickU(is_new, @min(a.len, a.cap - 1), found);
        a.len = @min(a.len + @intFromBool(is_new), a.cap);
        c.id[i] = k;
        c.x[i] = pickF(is_new, initial, c.x[i]);
        c.v[i] = pickF(is_new, 0, c.v[i]);
        return i;
    }

    /// SIMD. Advances every spring by `dt` seconds. Returns how much is still
    /// moving; 0 means everything is at rest and no further frames are needed.
    pub fn step(a: *Anims, dt: f32) f32 {
        const c = &a.c;
        const h = simd.f(@min(dt, 1.0 / 30.0));
        const zero = simd.f(0);
        var motion = zero;
        const n = simd.padded(a.len);
        var i: usize = 0;
        while (i < n) : (i += W) {
            const x = simd.loadF(c.x, i);
            const v = simd.loadF(c.v, i);
            const target = simd.loadF(c.target, i);
            const acc = simd.loadF(c.stiffness, i) * (target - x) - simd.loadF(c.damping, i) * v;
            const v1 = v + acc * h;
            const x1 = x + v1 * h;
            const left = @abs(target - x1);
            const speed = @abs(v1);
            const rest = (left < simd.f(1e-3)) & (speed < simd.f(1e-2));
            simd.storeF(c.x, i, @select(f32, rest, target, x1));
            simd.storeF(c.v, i, @select(f32, rest, zero, v1));
            motion = @max(motion, @select(f32, rest, zero, left + speed));
        }
        return @reduce(.Max, motion);
    }

    /// Drops springs nobody asked for in frame `frame`. Branch-free stream
    /// compaction: every row is copied to the write cursor, which advances
    /// only for rows that are kept.
    pub fn sweep(a: *Anims, frame: u32) void {
        const c = &a.c;
        const names = @typeInfo(Columns).@"struct".field_names;
        var w: u32 = 0;
        for (0..a.len) |r| {
            const keep = @intFromBool(c.seen[r] == frame);
            inline for (names) |name| @field(c, name)[w] = @field(c, name)[r];
            w += keep;
        }
        // Rows past the end must be inert for `step`.
        inline for (names) |name| @memset(@field(c, name)[w..a.len], 0);
        a.len = w;
    }
};

// ============================================================================
// Signals: change counters. The value lives in your data, not in the library.
// ============================================================================

pub const Signal = enum(u32) { _ };

pub const Signals = struct {
    version: []u32,
    len: u32 = 0,
    cap: u32,
    /// Something changed since the last frame. `Context.needsFrame` reads this.
    dirty: bool = false,

    pub fn init(carver: *mem.Carver, cap: u32) Signals {
        return .{ .cap = cap, .version = carver.slice(u32, cap) };
    }
    pub fn create(s: *Signals) Signal {
        const i = @min(s.len, s.cap - 1);
        s.len = i + 1;
        return @fromBackingInt(i);
    }
    /// Records that the data behind `sig` changed (or did not: `changed` is
    /// folded in arithmetically, so callers need no `if`).
    pub fn bump(s: *Signals, sig: Signal, changed: bool) void {
        s.version[@backingInt(sig)] +%= @intFromBool(changed);
        s.dirty = either(s.dirty, changed);
    }
    pub fn touch(s: *Signals, sig: Signal) void {
        s.bump(sig, true);
    }
    /// Fingerprint of a dependency list at its current versions.
    pub fn stamp(s: *const Signals, deps: []const Signal) u64 {
        var h: u64 = 0xcbf2_9ce4_8422_2325;
        for (deps) |dep| {
            const i = @backingInt(dep);
            h = (h ^ ((@as(u64, i) << 32) | s.version[i])) *% 0x0000_0100_0000_01b3;
        }
        return h;
    }
};

/// A value paired with its signal. Tier 2: nothing here the caller could not
/// write with `Signals.bump`.
pub fn Cell(comptime T: type) type {
    return struct {
        value: T,
        signal: Signal,

        const Self = @This();
        pub fn init(signals: *Signals, value: T) Self {
            return .{ .value = value, .signal = signals.create() };
        }
        pub fn get(self: *const Self) T {
            return self.value;
        }
        pub fn set(self: *Self, signals: *Signals, value: T) void {
            const changed = !std.meta.eql(self.value, value);
            self.value = value;
            signals.bump(self.signal, changed);
        }
    };
}

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
        stamp: []u64,
    };

    pub fn init(carver: *mem.Carver, cap: u32) Memos {
        return .{ .cap = cap, .c = carver.columns(Columns, simd.padded(cap) + W) };
    }
};

// ============================================================================
// Platform output: effects the host should apply, returned as data
// ============================================================================

pub const Cursor = enum(u8) { arrow, pointer, text, grab, resize_h, resize_v };

pub const Platform = struct {
    cursor: Cursor = .arrow,
    /// Show the on-screen keyboard / enable IME, anchored at `ime_rect`.
    wants_text: bool = false,
    ime_rect: Rect = .{},
    /// Non-empty when the UI asks to set the clipboard. Valid until the next `begin`.
    clipboard: []const u8 = "",
};

/// Capacity problems this frame. Nothing is written out of bounds when a
/// limit is hit; the frame is simply incomplete and says so here.
pub const Status = bitpack struct(u8) {
    nodes: bool = false,
    texts: bool = false,
    customs: bool = false,
    strings: bool = false,
    depth: bool = false,
    _: u3 = 0,

    pub fn ok(s: Status) bool {
        return @as(u8, @bitCast(s)) == 0;
    }
};

pub const Output = struct {
    draw: *const DrawList,
    /// Final geometry and semantics (`role`, `value`) for accessibility bridges and tests.
    tree: *const Tree,
    texts: *const Texts,
    platform: Platform,
    status: Status,
    /// Seconds until another frame is needed without new input:
    /// 0 = animate now, inf = sleep until the next event.
    wake: f32,
};

// ============================================================================
// Context and Frame (tier 1): own the columns and run the passes in order
// ============================================================================

pub const Limits = struct {
    nodes: u32 = 4096,
    texts: u32 = 1024,
    customs: u32 = 64,
    /// Bytes of text per frame.
    strings: u32 = 64 * 1024,
    anims: u32 = 256,
    signals: u32 = 256,
    memos: u32 = 128,
    /// Deepest nesting of open nodes.
    depth: u32 = 64,
};

pub const root_id = Id.from("ui.root");

/// Everything that outlives a frame. Holds no pointers the caller did not
/// hand it: all storage is carved from the buffer passed to `init`.
pub const Context = struct {
    limits: Limits,
    // Two generations. `cur` is being built; the other is last frame's result,
    // which hit testing and `Frame.reuse` read.
    trees: [2]Tree,
    texts: [2]Texts,
    customs: [2]Customs,
    strings: [2]Strings,
    cur: u1 = 0,
    draw: DrawList,
    anims: Anims,
    signals: Signals,
    memos: Memos,
    /// Rows of the currently open nodes.
    stack: []u32,
    depth: u32 = 0,
    inter: Interaction = .{},
    platform: Platform = .{},
    status: Status = .{},
    frame: u32 = 0,
    /// How much the springs are still moving.
    motion: f32 = 0,
    /// Frames still owed after the last input change.
    settle: u32 = 0,
    last_stamp: u64 = 0,

    fn build(carver: *mem.Carver, limits: Limits) Context {
        return .{
            .limits = limits,
            .trees = .{ Tree.init(carver, limits.nodes), Tree.init(carver, limits.nodes) },
            .texts = .{ Texts.init(carver, limits.texts), Texts.init(carver, limits.texts) },
            .customs = .{ Customs.init(carver, limits.customs), Customs.init(carver, limits.customs) },
            .strings = .{ .{ .buf = carver.slice(u8, limits.strings) }, .{ .buf = carver.slice(u8, limits.strings) } },
            .draw = DrawList.init(carver, limits.nodes, limits.texts, limits.customs),
            .anims = Anims.init(carver, limits.anims),
            .signals = Signals.init(carver, limits.signals),
            .memos = Memos.init(carver, limits.memos),
            .stack = carver.slice(u32, limits.depth),
        };
    }

    /// Bytes `init` needs. Callable at comptime, so a static buffer can be
    /// declared as `[Context.requiredBytes(limits)]u8`.
    pub fn requiredBytes(limits: Limits) usize {
        @setEvalBranchQuota(20_000);
        var counter: mem.Carver = .{ .buf = null };
        _ = build(&counter, limits);
        return counter.off;
    }

    /// The buffer is the only memory the library will ever use.
    pub fn init(buffer: []align(mem.column_align) u8, limits: Limits) error{BufferTooSmall}!Context {
        if (buffer.len < requiredBytes(limits)) return error.BufferTooSmall;
        var carver: mem.Carver = .{ .buf = buffer };
        return build(&carver, limits);
    }

    /// False when a frame built from `in` would be identical to the last one.
    /// The host can then sleep until the next event.
    pub fn needsFrame(ctx: *const Context, in: *const Input) bool {
        const changed = either(ctx.frame == 0, in.stamp() != ctx.last_stamp);
        const pending = either(ctx.motion > 0, either(ctx.settle > 0, ctx.signals.dirty));
        return either(changed, pending);
    }

    pub fn begin(ctx: *Context, in: *const Input) Frame {
        // One extra frame after any input change, so state that this frame's
        // events modify is visible without waiting for the next event.
        const stamp = in.stamp();
        ctx.settle = pickU(stamp != ctx.last_stamp, 1, ctx.settle -| 1);
        ctx.last_stamp = stamp;

        ctx.cur ^= 1;
        const t = &ctx.trees[ctx.cur];
        t.reset();
        ctx.texts[ctx.cur].reset();
        ctx.customs[ctx.cur].reset();
        ctx.strings[ctx.cur].len = 0;
        ctx.strings[ctx.cur].overflow = false;
        ctx.platform = .{};
        ctx.status = .{};
        ctx.frame +%= 1;

        ctx.inter.step(&ctx.trees[ctx.cur ^ 1], in);
        ctx.motion = ctx.anims.step(in.dt);

        const root = t.push(0, root_id, &.{ .size = .{ .px(in.viewport[0]), .px(in.viewport[1]) }, .clip = true, .role = .group });
        ctx.stack[0] = root;
        ctx.depth = 1;
        return .{ .ctx = ctx, .in = in };
    }
};

/// One frame under construction. Cheap to copy: two pointers.
pub const Frame = struct {
    ctx: *Context,
    in: *const Input,

    pub fn tree(f: *const Frame) *Tree {
        return &f.ctx.trees[f.ctx.cur];
    }
    pub fn texts(f: *const Frame) *Texts {
        return &f.ctx.texts[f.ctx.cur];
    }
    pub fn prevTree(f: *const Frame) *const Tree {
        return &f.ctx.trees[f.ctx.cur ^ 1];
    }

    // ---- building -----------------------------------------------------------

    /// Starts a node. Everything created until the matching `close` is its child.
    pub fn open(f: *Frame, id: Id, style: Style) Node {
        const ctx = f.ctx;
        const i = f.tree().push(ctx.stack[ctx.depth - 1], id, &style);
        const d = @min(ctx.depth, ctx.limits.depth - 1);
        ctx.status.depth = either(ctx.status.depth, ctx.depth >= ctx.limits.depth);
        ctx.stack[d] = i;
        ctx.depth = d + 1;
        return @fromBackingInt(i);
    }

    pub fn close(f: *Frame) void {
        const ctx = f.ctx;
        // Never pops the root, even if calls are unbalanced.
        const d = @max(ctx.depth, 2) - 1;
        f.tree().seal(ctx.stack[d]);
        ctx.depth = d;
    }

    /// A node with no children. Same as `open` then `close`.
    pub fn leaf(f: *Frame, id: Id, style: Style) Node {
        const n = f.open(id, style);
        f.close();
        return n;
    }

    /// A text leaf. The bytes are copied, so `str` may be a temporary.
    pub fn text(f: *Frame, str: []const u8, ts: TextStyle) Node {
        return f.textStyled(str, ts, .{ .shrink = ts.wrap, .role = .label });
    }

    /// `text` with full control over the leaf (padding, sizing, background).
    pub fn textStyled(f: *Frame, str: []const u8, ts: TextStyle, style: Style) Node {
        const ctx = f.ctx;
        const n = f.leaf(.none, style);
        const span = ctx.strings[ctx.cur].add(str);
        f.tree().c.text[n.ix()] = f.texts().push(n.ix(), span, &ts);
        return n;
    }

    /// Reserves a rect that the caller draws itself. It comes back in the
    /// draw list as `Cmd.custom`, in paint order, with `data` attached.
    pub fn custom(f: *Frame, id: Id, style: Style, data: u64) Node {
        const ctx = f.ctx;
        const n = f.leaf(id, style);
        f.tree().c.custom[n.ix()] = ctx.customs[ctx.cur].push(n.ix(), id, data);
        return n;
    }

    // ---- queries: input is asked for, never delivered ----------------------

    /// Makes `node` interactive and reports what happened to it this frame.
    /// The node must have been created with an id; anonymous nodes report nothing.
    pub fn interact(f: *Frame, node: Node, sense: Sense) Response {
        const c = &f.tree().c;
        c.sense[node.ix()] = @bitCast(sense);
        return f.ctx.inter.response(@fromBackingInt(c.id[node.ix()]));
    }

    /// Pointer movement this frame while `id` is held; zero otherwise.
    pub fn drag(f: *const Frame, id: Id) [2]f32 {
        const s = &f.ctx.inter;
        const k = @backingInt(id);
        const m = b01(both(k != 0, s.active == k));
        return .{ s.delta[0] * m, s.delta[1] * m };
    }

    /// Where `id` was laid out last frame. A zero rect if it did not exist.
    /// Scans the id column (SIMD, O(n)); prefer `heldRect` inside widgets.
    pub fn lastRect(f: *const Frame, id: Id) Rect {
        const prev = f.prevTree();
        const i = simd.find(prev.c.id, prev.len, @backingInt(id));
        const row = @min(i, prev.cap - 1);
        const m = b01(i != none);
        return .{
            .x0 = prev.c.rect[0][row] * m,
            .y0 = prev.c.rect[1][row] * m,
            .x1 = prev.c.rect[2][row] * m,
            .y1 = prev.c.rect[3][row] * m,
        };
    }

    /// Last frame's rect of the widget the pointer is holding. O(1): the
    /// interaction step already knows its row. A zero rect if nothing is held.
    pub fn heldRect(f: *const Frame) Rect {
        const prev = f.prevTree();
        const i = f.ctx.inter.active_node;
        const row = @min(i, prev.cap - 1);
        const m = b01(i != none);
        return .{
            .x0 = prev.c.rect[0][row] * m,
            .y0 = prev.c.rect[1][row] * m,
            .x1 = prev.c.rect[2][row] * m,
            .y1 = prev.c.rect[3][row] * m,
        };
    }

    pub fn setFill(f: *Frame, node: Node, color: Color) void {
        f.tree().c.look[node.ix()].fill = color.bitsOf();
    }

    /// Requests `cursor` if `when` holds. The last request in a frame wins.
    pub fn setCursor(f: *Frame, cursor: Cursor, when: bool) void {
        const p = &f.ctx.platform;
        p.cursor = @fromBackingInt(@as(u8, @truncate(pickU(when, @backingInt(cursor), @backingInt(p.cursor)))));
    }

    // ---- tier 2 conveniences that need retained state ----------------------

    /// A value that eases toward `target` across frames. Keeps the host awake
    /// (see `Output.wake`) until it arrives.
    pub fn animate(f: *Frame, id: Id, target: f32, spring: Spring) f32 {
        const ctx = f.ctx;
        const a = &ctx.anims;
        const i = a.slot(id, target);
        a.c.target[i] = target;
        a.c.stiffness[i] = spring.stiffness;
        a.c.damping[i] = spring.damping;
        a.c.seen[i] = ctx.frame;
        ctx.motion = @max(ctx.motion, @abs(target - a.c.x[i]));
        return a.c.x[i];
    }

    /// Signals-driven skipping. Returns true when the subtree rooted at the
    /// node with `id` was copied from last frame, in which case the caller
    /// must not build it:
    ///
    ///     if (!f.reuse(id, &.{ items.signal })) {
    ///         _ = f.open(id, style);   // the root must carry the same id
    ///         ...
    ///         f.close();
    ///     }
    ///
    /// A subtree is rebuilt when a dependency changed, when the pointer is
    /// over it or holding something in it, and while any spring is moving.
    /// Reuse skips building (your code and the column writes); layout and
    /// paint still run over the copied rows.
    pub fn reuse(f: *Frame, id: Id, deps: []const Signal) bool {
        const ctx = f.ctx;
        const m = &ctx.memos;
        const t = f.tree();
        const prev = f.prevTree();
        const k = @backingInt(id);
        const stamp = ctx.signals.stamp(deps);

        const found = simd.find(m.c.id, m.len, k);
        const is_new = found == none;
        const slot = pickU(is_new, @min(m.len, m.cap - 1), found);
        m.len = @min(m.len + @intFromBool(is_new), m.cap);

        // Candidate source rows in last frame's tree. Clamped so the reads are
        // in bounds even when the memo is new or stale; `ok` decides use.
        const a = @min(m.c.node[slot], prev.cap - 1);
        const b = prev.c.end[a];
        const count = b -% a;
        const ptx = &ctx.texts[ctx.cur ^ 1];
        const pcu = &ctx.customs[ctx.cur ^ 1];
        const k0 = simd.rank(ptx.c.node, ptx.len, a);
        const k1 = simd.rank(ptx.c.node, ptx.len, b);
        const c0 = simd.rank(pcu.c.node, pcu.len, a);
        const c1 = simd.rank(pcu.c.node, pcu.len, b);

        const same_inputs = both(!is_new, m.c.stamp[slot] == stamp);
        const from_last_frame = both(m.c.frame[slot] +% 1 == ctx.frame, both(a < prev.len, prev.c.id[a] == k));
        // Unsigned range tests: (x - a) < count  <=>  a <= x < b.
        const touched = either((ctx.inter.hot_node -% a) < count, (ctx.inter.active_node -% a) < count);
        // Written as "need <= room" so a stale, oversized `count` cannot overflow.
        const fits = both(count <= t.cap - t.len, both(
            (k1 -% k0) <= f.texts().cap - f.texts().len,
            (c1 -% c0) <= ctx.customs[ctx.cur].cap - ctx.customs[ctx.cur].len,
        ));
        const ok = both(both(same_inputs, from_last_frame), both(both(!touched, fits), ctx.motion == 0));

        // The subtree starts at the next row whether it is copied or rebuilt.
        m.c.id[slot] = k;
        m.c.node[slot] = t.len;
        m.c.frame[slot] = ctx.frame;
        // A rebuild caused by the pointer is followed by one more, so hover
        // and press visuals are not frozen into the copy.
        m.c.stamp[slot] = stamp ^ @intFromBool(touched);

        // The one coarse branch: copying and rebuilding are different work.
        if (!ok) return false;
        f.copySubtree(a, b, k0, k1, c0, c1);
        return true;
    }

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
        // Rebase links, `lanes` rows per step. The last vector may run past the
        // subtree into rows that are not in use yet; the next push rewrites them.
        const text_shift = simd.u(tx.len -% k0);
        const custom_shift = simd.u(cu.len -% c0);
        const nil = simd.u(none);
        var i: usize = n;
        while (i < n + count) : (i += W) {
            simd.storeU(t.c.parent, i, simd.loadU(t.c.parent, i) +% simd.u(delta));
            simd.storeU(t.c.end, i, simd.loadU(t.c.end, i) +% simd.u(delta));
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
        for (tx.len..tx.len + tn) |k| {
            tx.c.node[k] +%= delta;
            const span = ctx.strings[ctx.cur].add(old_strings.get(.{ .start = tx.c.start[k], .bytes = tx.c.bytes[k] }));
            tx.c.start[k] = span.start;
            tx.c.bytes[k] = span.bytes;
        }
        tx.len += tn;

        const cn = c1 - c0;
        mem.copyRows(Customs.Columns, &cu.c, cu.len, &pcu.c, c0, cn);
        for (cu.len..cu.len + cn) |k| cu.c.node[k] +%= delta;
        cu.len += cn;
    }

    // ---- finishing ------------------------------------------------------------

    /// Diagonal: measure with `font`, lay out, paint. Each line below is a
    /// public tier-0 call; copy this body to put your own shaper, or your own
    /// pass, between any two of them.
    pub fn end(f: *Frame, font: fonts.Mono) Output {
        const t = f.tree();
        const tx = f.texts();
        t.seal(0);
        font.measure(tx);
        layout.prepare(t);
        layout.applyText(t, tx, .x);
        layout.fit(t, .x);
        layout.resolve(t, .x, f.in.viewport[0]);
        layout.textAvail(t, tx);
        font.wrap(tx);
        layout.applyText(t, tx, .y);
        layout.fit(t, .y);
        layout.resolve(t, .y, f.in.viewport[1]);
        layout.place(t);
        layout.finalize(t);
        return f.finish();
    }

    /// Paint and bookkeeping only, for callers who ran layout themselves.
    pub fn finish(f: *Frame) Output {
        const ctx = f.ctx;
        const t = f.tree();
        const tx = f.texts();
        const cu = &ctx.customs[ctx.cur];
        const strings = &ctx.strings[ctx.cur];
        t.seal(0);
        paint.emit(t, tx, cu, strings.buf[0..strings.len], &ctx.draw);
        ctx.anims.sweep(ctx.frame);
        ctx.signals.dirty = false;
        ctx.status = .{
            .nodes = t.overflow,
            .texts = tx.overflow,
            .customs = cu.overflow,
            .strings = strings.overflow,
            .depth = ctx.status.depth,
        };
        const awake = either(ctx.motion > 0, ctx.settle > 0);
        return .{
            .draw = &ctx.draw,
            .tree = t,
            .texts = tx,
            .platform = ctx.platform,
            .status = ctx.status,
            .wake = pickF(awake, 0, inf),
        };
    }
};

// ============================================================================
// widgets (tier 2): written against the public API above and nothing else.
// Each is a handful of lines; copy and change one rather than configuring it.
// ============================================================================

pub const Theme = struct {
    text: Color = Color.rgb(230, 230, 235),
    text_px: f32 = 14,
    panel: Color = Color.rgb(30, 31, 36),
    control: Color = Color.rgb(58, 60, 70),
    control_hot: Color = Color.rgb(74, 77, 90),
    control_held: Color = Color.rgb(44, 46, 54),
    accent: Color = Color.rgb(90, 140, 255),
    radius: f32 = 4,
    pad: f32 = 8,
    gap: f32 = 6,
};

pub const widgets = struct {
    inline fn unit(x: f32) f32 {
        return @min(@max(x, 0), 1);
    }

    pub fn label(f: *Frame, th: *const Theme, str: []const u8) Node {
        return f.text(str, .{ .px = th.text_px, .color = th.text });
    }

    pub fn button(f: *Frame, th: *const Theme, id: Id, str: []const u8) Response {
        const node = f.open(id, .{
            .dir = .x,
            .pad = @splat(th.pad),
            .radius = th.radius,
            .main = .center,
            .cross = .center,
            .role = .button,
        });
        const r = f.interact(node, .button);
        // State selects the colour by table index.
        const fills = [4]Color{ th.control, th.control_hot, th.control_held, th.control_held };
        f.setFill(node, fills[@as(u8, @intFromBool(r.hovered)) | (@as(u8, @intFromBool(r.held)) << 1)]);
        f.setCursor(.pointer, r.hovered);
        _ = label(f, th, str);
        f.close();
        return r;
    }

    pub fn checkbox(f: *Frame, th: *const Theme, id: Id, value: *bool, str: []const u8) Response {
        const row = f.open(id, .{ .dir = .x, .gap = th.gap, .cross = .center, .role = .checkbox });
        const r = f.interact(row, .button);
        // Toggling is an xor with "clicked".
        value.* = value.* != r.clicked;
        const marks = [2]Color{ th.control, th.accent };
        _ = f.leaf(.none, .{
            .size = .{ .px(16), .px(16) },
            .radius = 3,
            .fill = marks[@intFromBool(value.*)],
            .border = 1,
            .border_color = th.control_hot,
        });
        _ = label(f, th, str);
        f.close();
        f.tree().c.value[row.ix()] = b01(value.*);
        return r;
    }

    pub fn slider(f: *Frame, th: *const Theme, id: Id, value: *f32, lo: f32, hi: f32) Response {
        const track = f.open(id, .{
            .dir = .x,
            .size = .{ .fill, .px(8) },
            .min = .{ 40, 0 },
            .radius = 4,
            .fill = th.control,
            .role = .slider,
        });
        const r = f.interact(track, .{ .hover = true, .click = true, .drag = true, .focus = true });
        // While held, the value follows the pointer across last frame's rect.
        // `heldRect` is this slider's rect exactly when `r.held` is set.
        const rect = f.heldRect();
        const along = unit((f.in.pointer[0] - rect.x0) / @max(rect.w(), 1));
        value.* = pickF(r.held, lo + along * (hi - lo), value.*);
        const frac = unit((value.* - lo) / @max(hi - lo, 1e-6));
        _ = f.leaf(.none, .{ .size = .{ .pct(frac), .fill }, .radius = 4, .fill = th.accent });
        f.close();
        f.tree().c.value[track.ix()] = value.*;
        return r;
    }
};

test {
    // Force semantic analysis of every public declaration.
    inline for (.{
        @This(),   simd,        mem,        mem.Carver, Id,      Node,       Color,   Rect,
        Size,      Input,       Input.Keys, Tree,       Strings, Texts,      Customs, layout,
        hit,       Interaction, DrawList,   paint,      fonts,   fonts.Mono, Anims,   Signals,
        Cell(u32), Memos,       Status,     Context,    Frame,   widgets,
    }) |T| std.testing.refAllDecls(T);
}
