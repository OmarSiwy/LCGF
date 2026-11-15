//! Small value types of the core: identities, indices, colours, rects, sizing and style rows.
//! Tier 0: plain data, no allocator, no I/O. Ported from prototype/ui.zig ("Small value types").

const std = @import("std");

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

test "Id: compile-time and run-time hashes agree and are never none" {
    const save = Id.from("save");
    try std.testing.expectEqual(save, Id.hash("save"));
    // FNV-1a 32 of "save", so ids stay stable across builds and match the prototype.
    try std.testing.expectEqual(std.hash.Fnv1a_32.hash("save"), @backingInt(save));
    try std.testing.expect(Id.from("open") != save);
    try std.testing.expect(Id.hash("") != .none);
    // nonZero maps the one colliding hash to 1.
    try std.testing.expectEqual(@as(u32, 1), Id.nonZero(0));
    try std.testing.expectEqual(@as(u32, 7), Id.nonZero(7));
}

test "Id: call sites differ, the same site is stable" {
    const a = Id.src(@src());
    const b = Id.src(@src());
    try std.testing.expect(a != b);
    try std.testing.expect(a != .none);
    var same: [2]Id = undefined;
    for (&same) |*s| s.* = Id.src(@src());
    try std.testing.expectEqual(same[0], same[1]);
}

test "Id.with: deterministic, distinct per index, never none" {
    const row = Id.from("row");
    try std.testing.expectEqual(row.with(3), row.with(3));
    var seen: [64]Id = undefined;
    for (&seen, 0..) |*s, i| {
        s.* = row.with(@intCast(i));
        try std.testing.expect(s.* != .none);
        try std.testing.expect(s.* != row);
        for (seen[0..i]) |prev| try std.testing.expect(prev != s.*);
    }
    try std.testing.expect(Id.none.with(0) != .none);
}

/// "No index" for every u32 link in the core.
pub const none: u32 = 0xffff_ffff;

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

test "Node: root is row 0, none is the shared no-index value" {
    try std.testing.expectEqual(@as(u32, 0), Node.root.ix());
    try std.testing.expectEqual(none, Node.none.ix());
    const n: Node = @fromBackingInt(42);
    try std.testing.expectEqual(@as(u32, 42), n.ix());
}

test "Axis: one bit, usable as a two-entry index" {
    try std.testing.expectEqual(1, @bitSizeOf(Axis));
    const pair = [2]f32{ 10, 20 };
    try std.testing.expectEqual(@as(f32, 10), pair[@backingInt(Axis.x)]);
    try std.testing.expectEqual(@as(f32, 20), pair[@backingInt(Axis.y)]);
}

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

test "Color: constructors, hex and bit layout" {
    const c = Color.hex(0x11223344);
    try std.testing.expectEqual(Color.rgba(0x11, 0x22, 0x33, 0x44), c);
    try std.testing.expectEqual(Color.rgba(1, 2, 3, 255), Color.rgb(1, 2, 3));
    try std.testing.expectEqual(@as(u32, 0), Color.transparent.bitsOf());
    try std.testing.expectEqual(@as(u32, 0xffff_ffff), Color.white.bitsOf());
    // r is the low byte, so the bytes in memory are r, g, b, a on little-endian hosts.
    try std.testing.expectEqual(@as(u32, 0x4433_2211), c.bitsOf());
    try std.testing.expectEqual(@as(u32, 0xff00_0000), Color.black.bitsOf());
}

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

test "Rect: size, intersection and half-open containment" {
    const a: Rect = .{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 50 };
    const b: Rect = .{ .x0 = 40, .y0 = -10, .x1 = 200, .y1 = 30 };
    try std.testing.expectEqual(@as(f32, 100), a.w());
    try std.testing.expectEqual(@as(f32, 50), a.h());
    try std.testing.expectEqual([4]f32{ 0, 0, 100, 50 }, a.array());
    try std.testing.expectEqual(Rect{ .x0 = 40, .y0 = 0, .x1 = 100, .y1 = 30 }, a.intersect(b));
    try std.testing.expectEqual(a.intersect(b), b.intersect(a));
    try std.testing.expectEqual(a, a.intersect(a));
    // Disjoint rects give an empty (inverted) rect, never a positive area.
    const far: Rect = .{ .x0 = 300, .y0 = 300, .x1 = 400, .y1 = 400 };
    const empty = a.intersect(far);
    try std.testing.expect(empty.w() <= 0 and empty.h() <= 0);
    try std.testing.expect(a.contains(0, 0));
    try std.testing.expect(a.contains(99.5, 49.5));
    try std.testing.expect(!a.contains(100, 10));
    try std.testing.expect(!a.contains(10, 50));
    try std.testing.expect(!a.contains(-0.5, 10));
    try std.testing.expect(!empty.contains(350, 350));
}

pub const inf = std.math.inf(f32);

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

    // Coefficient tables, indexed by Kind. Public because layout lives in another file.
    //                                            fit  px  grow pct
    pub const k_min = [4]f32{ 0, 1, 0, 0 }; //   min  = v * k_min
    pub const k_max = [4]f32{ 0, 1, 0, 0 }; //   max  = v * k_max + c_max
    pub const c_max = [4]f32{ inf, 0, inf, inf };
    pub const k_grow = [4]f32{ 0, 0, 1, 0 }; //  grow = v * k_grow
    pub const k_pct = [4]f32{ 0, 0, 0, 1 }; //   pct  = v * k_pct
};

test "Size: constructors store kind and value" {
    try std.testing.expectEqual(Size{ .kind = .fit, .v = 0 }, Size.fit);
    try std.testing.expectEqual(Size{ .kind = .grow, .v = 1 }, Size.fill);
    try std.testing.expectEqual(Size{ .kind = .px, .v = 12 }, Size.px(12));
    try std.testing.expectEqual(Size{ .kind = .grow, .v = 2 }, Size.grow(2));
    try std.testing.expectEqual(Size{ .kind = .pct, .v = 0.25 }, Size.pct(0.25));
}

test "Size: coefficient tables give min, max, grow and pct without a switch" {
    const cases = [_]struct { s: Size, min: f32, max: f32, grow: f32, pct: f32 }{
        .{ .s = .fit, .min = 0, .max = inf, .grow = 0, .pct = 0 },
        .{ .s = .px(30), .min = 30, .max = 30, .grow = 0, .pct = 0 },
        .{ .s = .grow(3), .min = 0, .max = inf, .grow = 3, .pct = 0 },
        .{ .s = .pct(0.5), .min = 0, .max = inf, .grow = 0, .pct = 0.5 },
    };
    for (cases) |c| {
        const k = @backingInt(c.s.kind);
        try std.testing.expectEqual(c.min, c.s.v * Size.k_min[k]);
        try std.testing.expectEqual(c.max, c.s.v * Size.k_max[k] + Size.c_max[k]);
        try std.testing.expectEqual(c.grow, c.s.v * Size.k_grow[k]);
        try std.testing.expectEqual(c.pct, c.s.v * Size.k_pct[k]);
    }
}

pub const Align = enum(u8) {
    start,
    center,
    end,
    /// Share of the leftover space placed before the children, indexed by the tag.
    /// Public because layout lives in another file.
    pub const factor = [3]f32{ 0, 0.5, 1 };
};

test "Align: factor table places leftover space by index" {
    const leftover: f32 = 40;
    try std.testing.expectEqual(@as(f32, 0), leftover * Align.factor[@backingInt(Align.start)]);
    try std.testing.expectEqual(@as(f32, 20), leftover * Align.factor[@backingInt(Align.center)]);
    try std.testing.expectEqual(@as(f32, 40), leftover * Align.factor[@backingInt(Align.end)]);
    try std.testing.expectEqual(@typeInfo(Align).@"enum".field_names.len, Align.factor.len);
}

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

test "Sense: one bit per interaction, presets as bit masks" {
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(Sense{})));
    try std.testing.expectEqual(@as(u8, 0b1011), @as(u8, @bitCast(Sense.button)));
    try std.testing.expectEqual(@as(u8, 0b1111), @as(u8, @bitCast(Sense.any)));
}

test "Response: bits are in declaration order and can be assembled from masks" {
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @bitCast(Response{})));
    const r: Response = @bitCast(@as(u8, 0b10_0001));
    try std.testing.expect(r.hovered and r.focused);
    try std.testing.expect(!r.held and !r.pressed and !r.released and !r.clicked);
    try std.testing.expectEqual(@as(u8, 1 << 4), @as(u8, @bitCast(Response{ .clicked = true })));
}

/// What a node is to assistive technology. One byte per node; the accessibility tree reads it.
pub const Role = enum(u8) { none, group, label, button, checkbox, slider, image, text_input };

test "Role: one byte, none is the zero default" {
    try std.testing.expectEqual(1, @sizeOf(Role));
    try std.testing.expectEqual(@as(u8, 0), @backingInt(Role.none));
    try std.testing.expectEqual(@as(u8, 7), @backingInt(Role.text_input));
}

/// Handles the renderer gives out. The core only stores and groups by them.
pub const Texture = enum(u16) { white = 0, _ };
pub const Material = enum(u16) { solid = 0, _ };
pub const Font = enum(u16) { default = 0, _ };

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
    /// Per-corner radii: top-left, top-right, bottom-right, bottom-left. A negative corner
    /// takes `radius`, so the default is `radius` on all four.
    radii: [4]f32 = .{ -1, -1, -1, -1 },
    /// Opacity of this node and its whole subtree, 0 to 1; nested opacities multiply
    /// (`draw.inherit.opacity`).
    opacity: f32 = 1,
    /// The part of `texture` the quad shows, as u0, v0, u1, v1 (an image's rect in an atlas).
    uv: [4]f32 = .{ 0, 0, 1, 1 },
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

test "Style: defaults are a fit-sized, unpainted, vertical group" {
    const s: Style = .{};
    try std.testing.expectEqual(Axis.y, s.dir);
    try std.testing.expectEqual([2]Size{ .fit, .fit }, s.size);
    try std.testing.expectEqual([2]f32{ 0, 0 }, s.min);
    try std.testing.expectEqual([2]f32{ inf, inf }, s.max);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, s.pad);
    try std.testing.expectEqual(@as(f32, 0), s.gap);
    try std.testing.expectEqual(Align.start, s.main);
    try std.testing.expectEqual(Align.start, s.cross);
    try std.testing.expect(!s.shrink and !s.float and !s.clip);
    try std.testing.expectEqual([2]f32{ 0, 0 }, s.offset);
    try std.testing.expectEqual([2]f32{ 0, 0 }, s.scroll);
    try std.testing.expectEqual(Color.transparent, s.fill);
    try std.testing.expectEqual(Color.transparent, s.border_color);
    try std.testing.expectEqual(@as(f32, 0), s.border);
    try std.testing.expectEqual(@as(f32, 0), s.radius);
    try std.testing.expectEqual(Texture.white, s.texture);
    try std.testing.expectEqual(Material.solid, s.material);
    try std.testing.expectEqual([4]f32{ 0, 0, 0, 0 }, s.params);
    try std.testing.expectEqual(Role.none, s.role);
    try std.testing.expectEqual(@as(f32, 0), s.value);
}

test "Style: fields take declaration literals as the prototype's call sites do" {
    const s: Style = .{ .dir = .x, .size = .{ .px(100), .fill }, .pad = @splat(8), .cross = .center, .fill = .rgb(1, 2, 3) };
    try std.testing.expectEqual(Size.px(100), s.size[0]);
    try std.testing.expectEqual(Size.fill, s.size[1]);
    try std.testing.expectEqual([4]f32{ 8, 8, 8, 8 }, s.pad);
    try std.testing.expectEqual(Color.rgb(1, 2, 3), s.fill);
}

test "TextStyle: defaults are 14 px white text in the default font, no wrap" {
    const t: TextStyle = .{};
    try std.testing.expectEqual(@as(f32, 14), t.px);
    try std.testing.expectEqual(Color.white, t.color);
    try std.testing.expectEqual(Font.default, t.font);
    try std.testing.expect(!t.wrap);
}

test "layout: sizes and offsets of every extern and packed type" {
    const expectEqual = std.testing.expectEqual;
    // extern: byte offsets are the C layout other tiers and the GPU rely on.
    try expectEqual(16, @sizeOf(Rect));
    try expectEqual(4, @alignOf(Rect));
    inline for (.{ "x0", "y0", "x1", "y1" }, 0..) |name, i| try expectEqual(4 * i, @offsetOf(Rect, name));
    try expectEqual(8, @sizeOf(Size));
    try expectEqual(0, @offsetOf(Size, "kind"));
    try expectEqual(4, @offsetOf(Size, "v"));
    // packed: bit offsets inside the backing integer.
    try expectEqual(4, @sizeOf(Color));
    inline for (.{ "r", "g", "b", "a" }, 0..) |name, i| try expectEqual(8 * i, @bitOffsetOf(Color, name));
    try expectEqual(1, @sizeOf(Sense));
    inline for (.{ "hover", "click", "drag", "focus" }, 0..) |name, i| try expectEqual(i, @bitOffsetOf(Sense, name));
    try expectEqual(1, @sizeOf(Response));
    inline for (.{ "hovered", "held", "pressed", "released", "clicked", "focused" }, 0..) |name, i|
        try expectEqual(i, @bitOffsetOf(Response, name));
    // Index and handle enums, which become column element types.
    try expectEqual(4, @sizeOf(Id));
    try expectEqual(4, @sizeOf(Node));
    try expectEqual(1, @bitSizeOf(Axis));
    try expectEqual(1, @sizeOf(Size.Kind));
    try expectEqual(1, @sizeOf(Align));
    try expectEqual(1, @sizeOf(Role));
    try expectEqual(2, @sizeOf(Texture));
    try expectEqual(2, @sizeOf(Material));
    try expectEqual(2, @sizeOf(Font));
}

test {
    // Force semantic analysis of every public declaration.
    inline for (.{ @This(), Id, Node, Color, Rect, Size, Align, Sense, Response, Style, TextStyle }) |T|
        std.testing.refAllDecls(T);
}
