//! The runtime front end behind the C seam: `Context`, `Frame` and the reference widgets, for
//! C++ (lcgf/runtime.hpp) and Rust (`lcgf::runtime`) programs that build their UI each frame in
//! code, as Zig programs do with `ctx.begin` and `f.open`.
//!
//! The caller owns the memory. `lcgf_rt_bytes` gives the size for some limits, and
//! `lcgf_rt_init` places the context at the start of the caller's buffer. Each builder call is
//! one direct call into the library, which writes the rows into the caller's columns. Styles
//! cross as words, laid out by `plan.put` (src/abi/plan.zig, the tables' own encoding), so the
//! C, C++ and Rust structs are those words in order and no compiler's struct layout is part
//! of the contract.

const std = @import("std");
const plan = @import("plan.zig");
const seam = @import("seam.zig");
const types = @import("../core/types.zig");
const mem = @import("../core/mem.zig");
const base = @import("../widgets/base.zig");
const context = @import("../runtime/context.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Mono = @import("../text/protocol.zig").Mono;
const Style = types.Style;
const Template = @import("../core/tree.zig").Template;
const FlatRow = @import("../core/tree.zig").FlatRow;
const Look = @import("../core/tree.zig").Look;
const Extra = @import("../core/tree.zig").Extra;
const TextStyle = types.TextStyle;
const canvas = @import("../draw/canvas.zig");
const draw_list = @import("../draw/draw_list.zig");
const abi_canvas = @import("canvas.zig");

/// `Limits`' sizes, as C passes them.
pub const CLimits = extern struct {
    nodes: u32 = 4096,
    texts: u32 = 1024,
    customs: u32 = 64,
    strings: u32 = 64 * 1024,
    anims: u32 = 256,
    depth: u32 = 64,

    fn limits(c: *const CLimits) context.Limits {
        return .{ .nodes = c.nodes, .texts = c.texts, .customs = c.customs, .strings = c.strings, .anims = c.anims, .depth = c.depth };
    }
};

pub const style_words = plan.wordsOf(Style);
pub const text_style_words = plan.wordsOf(TextStyle);
pub const theme_words = plan.wordsOf(base.Theme);
pub const row_words = plan.wordsOf(Template);

/// What C++ and Rust must agree on to call the runtime front end: the words of a style, a text
/// style and a row, and the columns they push rows into. lcgf.h carries it as LCGF_RT_LAYOUT;
/// the bindings compare it with `lcgf_rt_layout()` when a context is made.
pub const layout: u32 = plan.layoutHashOf(.{ Style, TextStyle, Template, CView, Look, Extra });

/// The frame's tree as `open` and `leaf` write it: where `Tree.pushRow` and `Frame.enter`
/// store, so C++ and Rust push a row they made with the stores Zig's inlined `leaf` makes,
/// and no call (`lcgf_view` in lcgf.h). Valid from `lcgf_rt_begin` to `lcgf_rt_end`; the
/// counters are pointers because the library's own calls (text, widgets) move them too.
pub const CView = extern struct {
    len: *u32,
    xlen: *u32,
    overflow: *bool,
    depth: *u32,
    /// The context's `Status` byte; `depth_bit` is its overflow flag for `depth`.
    status: *u8,
    cap: u32,
    depth_cap: u32,
    stack: [*]u32,
    id: [*]u32,
    parent: [*]u32,
    end: [*]u32,
    min: [2][*]f32,
    max: [2][*]f32,
    grow: [2][*]f32,
    pct: [2][*]f32,
    pad_lo: [2][*]f32,
    pad_hi: [2][*]f32,
    offset: [2][*]f32,
    scroll: [2][*]f32,
    main: [2][*]f32,
    gap: [*]f32,
    nkids: [*]f32,
    flow: [*]f32,
    shrink: [*]f32,
    align_main: [*]f32,
    align_cross: [*]f32,
    clips: [*]u8,
    sense: [*]u8,
    look: [*]Look,
    role: [*]u8,
    value: [*]f32,
    text: [*]u32,
    custom: [*]u32,
    extra: [*]u32,
    scope: [*]u32,
    x_node: [*]u32,
    x_row: [*]Extra,
};

/// Bit of `CView.status` that `enter` sets when the stack overflows (`Status.depth`).
pub const depth_bit: u5 = @bitOffsetOf(context.Status, "depth");

/// The context, its frame in progress, and the theme and font the widgets use.
pub const Runtime = struct {
    ctx: context.Context,
    frame: Frame = undefined,
    /// The frame's input: `Frame` reads it until `end`, so it lives here, not on cBegin's stack.
    input: @import("../core/input.zig").Input = .{},
    theme: base.Theme = .default,
    font: Mono = .{},
    /// `lcgf_rt_enable_canvas`: the palettes `lcgf_rt_canvas` makes from its options, in two
    /// generations as the canvas rows are (a reused canvas keeps last frame's), and how many
    /// this frame has made.
    palettes: []canvas.Palette = &.{},
    palette_len: u32 = 0,

    fn work(bytes: usize) usize {
        return std.mem.alignForward(usize, @sizeOf(Runtime), mem.column_align) + bytes;
    }
};

fn rt(p: *anyopaque) *Runtime {
    return @ptrCast(@alignCast(p));
}

fn style(words: [*]const u32) Style {
    return plan.get(Style, words[0..style_words]);
}

fn textStyle(words: [*]const u32) TextStyle {
    return plan.get(TextStyle, words[0..text_style_words]);
}

pub fn cLimitsBytes(l: *const CLimits) callconv(.c) usize {
    return Runtime.work(context.Context.requiredBytes(l.limits()));
}

pub fn cInit(buf: [*]u8, len: usize, l: *const CLimits) callconv(.c) c_int {
    if (@intFromPtr(buf) % mem.column_align != 0) return @backingInt(seam.Status.unaligned);
    if (len < cLimitsBytes(l)) return @backingInt(seam.Status.buffer_too_small);
    const off = std.mem.alignForward(usize, @sizeOf(Runtime), mem.column_align);
    const work: []align(mem.column_align) u8 = @alignCast(buf[off..len]);
    const r = rt(buf);
    r.* = .{ .ctx = context.Context.init(work, l.limits()) catch return @backingInt(seam.Status.buffer_too_small) };
    return 0;
}

/// `int`, as lcgf.h declares it: a C `bool` return would leave the caller reading the upper bits.
pub fn cNeedsFrame(p: *anyopaque, in: *const seam.CInput) callconv(.c) c_int {
    const input = in.input();
    return @intFromBool(rt(p).ctx.needsFrame(&input));
}

pub fn cBegin(p: *anyopaque, in: *const seam.CInput) callconv(.c) void {
    const r = rt(p);
    r.input = in.input();
    r.frame = r.ctx.begin(&r.input);
    r.palette_len = 0;
}

/// Bytes `lcgf_rt_enable_canvas` needs for `l`: the context's canvas rows and their palettes,
/// two generations of `customs` each.
pub fn cCanvasBytes(l: *const CLimits) callconv(.c) usize {
    return 2 * @as(usize, l.customs) * (@sizeOf(draw_list.CanvasDraw) + @sizeOf(canvas.Palette));
}

pub fn cEnableCanvas(p: *anyopaque, buf: [*]u8, len: usize) callconv(.c) c_int {
    const r = rt(p);
    const n = 2 * @as(usize, r.ctx.limits.customs);
    if (@intFromPtr(buf) % @alignOf(draw_list.CanvasDraw) != 0) return @backingInt(seam.Status.unaligned);
    if (len < n * (@sizeOf(draw_list.CanvasDraw) + @sizeOf(canvas.Palette))) return @backingInt(seam.Status.buffer_too_small);
    const rows: [*]draw_list.CanvasDraw = @ptrCast(@alignCast(buf));
    r.palettes = @as([*]canvas.Palette, @ptrCast(@alignCast(buf + n * @sizeOf(draw_list.CanvasDraw))))[0..n];
    r.ctx.enableCanvas(rows[0..n]);
    return 0;
}

/// `Frame.canvas`: `shapes` under the options' camera, palette, ranges and overrides, all of
/// them the caller's until the frame is drawn. LCGF_NO_WIDGET past `customs` canvases a frame.
pub fn cCanvas(p: *anyopaque, id: u32, s: [*]const u32, shapes: *const canvas.Instances, o: *const abi_canvas.COptions) callconv(.c) u32 {
    const r = rt(p);
    const n = r.palettes.len / 2;
    if (r.palette_len >= n) return std.math.maxInt(u32);
    const pal = &r.palettes[@as(usize, r.ctx.cur) * n + r.palette_len];
    r.palette_len += 1;
    pal.* = o.palette();
    return r.frame.canvas(@fromBackingInt(id), style(s), shapes, .{ .camera = o.cam(), .palette = pal, .ranges = o.spans(), .overrides = o.marks() }).ix();
}

pub fn cEnd(p: *anyopaque, out: *seam.CFrame) callconv(.c) void {
    const r = rt(p);
    const o = r.frame.end(r.font);
    out.* = .{ .draw = seam.cDraw(o.draw), .widget = seam.none_widget, .value = 0, .focus = seam.none_widget, .wake = o.wake };
}

pub fn cOpen(p: *anyopaque, id: u32, s: [*]const u32) callconv(.c) u32 {
    return rt(p).frame.open(@fromBackingInt(id), style(s)).ix();
}

// The row forms: the caller turned the style into its row (C++ `Row::From`, Rust `Row::from`,
// or `lcgf_row_from_style`), so a constant style costs nothing per call. The row is read in
// place, each word straight into its column (`Tree.pushRow` of a `FlatRow`).
fn cOpenRow(p: *anyopaque, id: u32, r: *const FlatRow) callconv(.c) u32 {
    return rt(p).frame.openRow(@fromBackingInt(id), r).ix();
}

fn cLeafRow(p: *anyopaque, id: u32, r: *const FlatRow) callconv(.c) u32 {
    return rt(p).frame.leafRow(@fromBackingInt(id), r).ix();
}

fn cCustomRow(p: *anyopaque, id: u32, r: *const FlatRow, data: u64) callconv(.c) u32 {
    return rt(p).frame.customRow(@fromBackingInt(id), r, data).ix();
}

pub fn cView(p: *anyopaque, out: *CView) callconv(.c) void {
    const r = rt(p);
    const ctx = &r.ctx;
    const t = r.frame.tree();
    const c = &t.c;
    var v: CView = undefined;
    v.len = &t.len;
    v.xlen = &t.xlen;
    v.overflow = &t.overflow;
    v.depth = &ctx.depth;
    v.status = @ptrCast(&ctx.status);
    v.cap = t.cap;
    v.depth_cap = ctx.limits.depth;
    v.stack = ctx.stack.ptr;
    inline for (@typeInfo(CView).@"struct".field_names) |name| {
        if (comptime @hasField(@TypeOf(c.*), name)) {
            const col = @field(c, name);
            if (@TypeOf(col) == [2][]f32) {
                @field(v, name) = .{ col[0].ptr, col[1].ptr };
            } else @field(v, name) = col.ptr;
        }
    }
    v.x_node = t.x.node.ptr;
    v.x_row = t.x.row.ptr;
    out.* = v;
}

/// `Template.from`: the row of a style, for C callers and for the gate that holds the C++ and
/// Rust ports to it.
pub fn cRowFromStyle(s: [*]const u32, out: [*]u32) callconv(.c) void {
    const st = style(s);
    plan.put(Template, .from(&st), out[0..row_words]);
}

/// An animated number as an integer of [lo, hi] (`values.intOf`): what C++'s `Components` and
/// Rust's `Animatable` return for an integer type.
fn cAnimInt(x: f32, lo: i64, hi: i64) callconv(.c) i64 {
    return @import("../anim/values.zig").intOf(x, lo, hi);
}

fn cLayout() callconv(.c) u32 {
    return layout;
}

pub fn cClose(p: *anyopaque) callconv(.c) void {
    rt(p).frame.close();
}

fn cLeaf(p: *anyopaque, id: u32, s: [*]const u32) callconv(.c) u32 {
    return rt(p).frame.leaf(@fromBackingInt(id), style(s)).ix();
}

fn cText(p: *anyopaque, str: [*]const u8, len: usize, ts: [*]const u32) callconv(.c) u32 {
    return rt(p).frame.text(str[0..len], textStyle(ts)).ix();
}

fn cTextStyled(p: *anyopaque, str: [*]const u8, len: usize, ts: [*]const u32, s: [*]const u32) callconv(.c) u32 {
    return rt(p).frame.textStyled(str[0..len], textStyle(ts), style(s)).ix();
}

fn cCustom(p: *anyopaque, id: u32, s: [*]const u32, data: u64) callconv(.c) u32 {
    return rt(p).frame.custom(@fromBackingInt(id), style(s), data).ix();
}

pub fn cAnimate(p: *anyopaque, id: u32, target: f32, stiffness: f32, damping: f32) callconv(.c) f32 {
    return rt(p).frame.animate(@fromBackingInt(id), target, .{ .stiffness = stiffness, .damping = damping });
}

fn cTween(p: *anyopaque, id: u32, target: f32, seconds: f32, ease: u32) callconv(.c) f32 {
    const e = std.math.cast(u8, ease) orelse 0;
    const Ease = @import("../anim/tweens.zig").Ease;
    const valid = e < @typeInfo(Ease).@"enum".field_names.len;
    return rt(p).frame.tween(@fromBackingInt(id), target, seconds, if (valid) @fromBackingInt(e) else .linear);
}

/// The free end of the frame's strings: `*len` gets its size.
fn cRoom(p: *anyopaque, len: *usize) callconv(.c) [*]u8 {
    const room = rt(p).frame.room();
    len.* = room.len;
    return room.ptr;
}

fn cTextWritten(p: *anyopaque, len: usize, ts: [*]const u32) callconv(.c) u32 {
    return rt(p).frame.textWritten(len, textStyle(ts)).ix();
}

/// `lcgf_rt_label` over the bytes just written at the room.
fn cLabelWritten(p: *anyopaque, len: usize) callconv(.c) u32 {
    const r = rt(p);
    return r.frame.textWritten(len, base.labelText(&r.theme)).ix();
}

fn response(r: types.Response) u8 {
    return @bitCast(r);
}

fn cLabel(p: *anyopaque, str: [*]const u8, len: usize) callconv(.c) u32 {
    const r = rt(p);
    return base.label(&r.frame, &r.theme, str[0..len]).ix();
}

pub fn cButton(p: *anyopaque, id: u32, str: [*]const u8, len: usize) callconv(.c) u8 {
    const r = rt(p);
    return response(base.button(&r.frame, &r.theme, @fromBackingInt(id), str[0..len]));
}

fn cCheckbox(p: *anyopaque, id: u32, value: *bool, str: [*]const u8, len: usize) callconv(.c) u8 {
    const r = rt(p);
    return response(base.checkbox(&r.frame, &r.theme, @fromBackingInt(id), value, str[0..len]));
}

pub fn cSlider(p: *anyopaque, id: u32, value: *f32, lo: f32, hi: f32) callconv(.c) u8 {
    const r = rt(p);
    return response(base.slider(&r.frame, &r.theme, @fromBackingInt(id), value, lo, hi));
}

/// The default theme as words (`base.Theme`'s fields in order).
fn cDefaultTheme(out: [*]u32) callconv(.c) void {
    plan.put(base.Theme, .default, out[0..theme_words]);
}

/// The words of `Style`'s defaults, so a binding's style struct can be checked against them.
fn cDefaultStyle(out: [*]u32) callconv(.c) void {
    plan.put(Style, .{}, out[0..style_words]);
}

/// The C functions, by the names lcgf.h declares. `exportAll` exports them; liblcgf_auto's
/// dispatcher (src/abi/auto.zig) routes the same names to one lane width's copy.
pub const exports = .{
    .{ "lcgf_rt_bytes", &cLimitsBytes },
    .{ "lcgf_rt_init", &cInit },
    .{ "lcgf_rt_needs_frame", &cNeedsFrame },
    .{ "lcgf_rt_begin", &cBegin },
    .{ "lcgf_rt_end", &cEnd },
    .{ "lcgf_rt_open", &cOpen },
    .{ "lcgf_rt_close", &cClose },
    .{ "lcgf_rt_leaf", &cLeaf },
    .{ "lcgf_rt_text", &cText },
    .{ "lcgf_rt_text_styled", &cTextStyled },
    .{ "lcgf_rt_custom", &cCustom },
    .{ "lcgf_rt_animate", &cAnimate },
    .{ "lcgf_rt_tween", &cTween },
    .{ "lcgf_rt_room", &cRoom },
    .{ "lcgf_rt_text_written", &cTextWritten },
    .{ "lcgf_rt_label_written", &cLabelWritten },
    .{ "lcgf_rt_label", &cLabel },
    .{ "lcgf_rt_button", &cButton },
    .{ "lcgf_rt_checkbox", &cCheckbox },
    .{ "lcgf_rt_slider", &cSlider },
    .{ "lcgf_default_theme", &cDefaultTheme },
    .{ "lcgf_default_style", &cDefaultStyle },
    .{ "lcgf_rt_open_row", &cOpenRow },
    .{ "lcgf_rt_leaf_row", &cLeafRow },
    .{ "lcgf_rt_custom_row", &cCustomRow },
    .{ "lcgf_row_from_style", &cRowFromStyle },
    .{ "lcgf_anim_int", &cAnimInt },
    .{ "lcgf_rt_layout", &cLayout },
    .{ "lcgf_rt_view", &cView },
    .{ "lcgf_rt_canvas_bytes", &cCanvasBytes },
    .{ "lcgf_rt_enable_canvas", &cEnableCanvas },
    .{ "lcgf_rt_canvas", &cCanvas },
} ++ abi_canvas.exports;

pub fn exportAll() void {
    inline for (0..exports.len) |k| @export(exports[k][1], .{ .name = exports[k][0] ++ plan.symbol_suffix });
}

test "runtime: the words a binding passes for a style" {
    try std.testing.expectEqual(59, style_words);
    try std.testing.expectEqual(4, text_style_words);
    try std.testing.expectEqual(10, theme_words);
    try std.testing.expectEqual(66, row_words);
}

test "runtime: FlatRow is a Template's words, field for field" {
    try std.testing.expectEqual(row_words * 4, @sizeOf(FlatRow));
    const st: Style = .{ .size = .{ .px(40), .pct(0.5) }, .pad = .{ 1, 2, 3, 4 }, .dir = .x, .cross = .end, .clip = true, .fill = .rgb(1, 2, 3), .border_color = .rgb(4, 5, 6), .radius = 7, .texture = @fromBackingInt(@intCast(9)), .material = @fromBackingInt(@intCast(11)), .params = .{ 12, 13, 14, 15 }, .role = .slider, .value = 0.25, .border = 2, .uv = .{ 0.1, 0.2, 0.3, 0.4 }, .radii = .{ 5, -1, 6, -1 }, .opacity = 0.5, .transform = .{ 2, 0, 0, 2, 3, 4 } };
    const t: Template = .from(&st);
    var flat: FlatRow = undefined;
    plan.put(Template, t, @ptrCast(&flat));
    inline for (@typeInfo(Template).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "look")) {
            inline for (@typeInfo(@TypeOf(t.look)).@"struct".field_names) |g|
                try std.testing.expectEqual(@as(@FieldType(FlatRow, g), @field(t.look, g)), @field(flat, g));
        } else switch (@typeInfo(@FieldType(Template, name))) {
            .int => try std.testing.expectEqual(@as(u32, @field(t, name)), @field(flat, name)),
            .@"struct" => try std.testing.expectEqual(@as(u32, @as(u8, @bitCast(@field(t, name)))), @field(flat, name)),
            else => try std.testing.expectEqual(@field(t, name), @field(flat, name)),
        }
    }
}

test "runtime: a row pushed through the C calls is the node its style makes" {
    const l: CLimits = .{ .nodes = 64, .texts = 64, .strings = 4096, .anims = 16 };
    const a = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(mem.column_align), cLimitsBytes(&l));
    defer std.testing.allocator.free(a);
    const b = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(mem.column_align), cLimitsBytes(&l));
    defer std.testing.allocator.free(b);
    try std.testing.expectEqual(0, cInit(a.ptr, a.len, &l));
    try std.testing.expectEqual(0, cInit(b.ptr, b.len, &l));
    const in: seam.CInput = .{ .viewport = .{ 300, 200 } };
    const styles = [_]Style{
        .{ .size = .{ .fill, .fill }, .pad = @splat(8), .fill = .rgb(10, 20, 30) },
        .{ .size = .{ .px(40), .pct(0.5) }, .radius = 4, .border = 1, .border_color = .rgb(1, 2, 3), .clip = true },
        .{ .dir = .x, .gap = 3, .opacity = 0.5, .radii = .{ 1, 2, 3, 4 } },
    };
    var words: [style_words]u32 = undefined;
    var rows: FlatRow = undefined;
    var outs: [2]seam.CFrame = undefined;
    for ([_][]align(mem.column_align) u8{ a, b }, &outs, 0..) |buf, *out, k| {
        cBegin(buf.ptr, &in);
        for (styles, 0..) |st, i| {
            plan.put(Style, st, &words);
            cRowFromStyle(&words, @ptrCast(&rows));
            const id: u32 = @intCast(i + 1);
            if (k == 0) {
                _ = cOpen(buf.ptr, id, &words);
                _ = cLeaf(buf.ptr, 100 + id, &words);
                _ = cCustom(buf.ptr, 200 + id, &words, 7);
            } else {
                _ = cOpenRow(buf.ptr, id, &rows);
                _ = cLeafRow(buf.ptr, 100 + id, &rows);
                _ = cCustomRow(buf.ptr, 200 + id, &rows, 7);
            }
        }
        for (styles) |_| cClose(buf.ptr);
        cEnd(buf.ptr, out);
    }
    try std.testing.expectEqualSlices(u8, std.mem.sliceAsBytes(outs[0].draw.quads[0..outs[0].draw.quad_len]), std.mem.sliceAsBytes(outs[1].draw.quads[0..outs[1].draw.quad_len]));
    try std.testing.expectEqual(outs[0].draw.custom_len, outs[1].draw.custom_len);
    try std.testing.expect(outs[0].draw.quad_len > 0);
}

test "runtime: a frame built through the C calls is the frame Zig builds" {
    const l: CLimits = .{ .nodes = 64, .texts = 64, .strings = 4096, .anims = 16 };
    const n = cLimitsBytes(&l);
    const buf = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(mem.column_align), n);
    defer std.testing.allocator.free(buf);
    try std.testing.expectEqual(0, cInit(buf.ptr, buf.len, &l));

    // The frame reads its input until `end`, after the caller's copy (and cBegin's stack) is
    // gone, so the input it points at must be the runtime's own.
    var in: seam.CInput = .{ .viewport = .{ 300, 200 } };
    cBegin(buf.ptr, &in);
    try std.testing.expectEqual(&rt(buf.ptr).input, rt(buf.ptr).frame.in);
    in = .{ .viewport = .{ 1, 1 } };
    var s: [style_words]u32 = undefined;
    plan.put(Style, .{ .size = .{ .fill, .fill }, .fill = .rgb(10, 20, 30) }, &s);
    _ = cOpen(buf.ptr, 1, &s);
    var on = false;
    const r = cCheckbox(buf.ptr, 2, &on, "On", 2);
    try std.testing.expectEqual(0, r & 16);
    cClose(buf.ptr);
    var out: seam.CFrame = undefined;
    cEnd(buf.ptr, &out);
    try std.testing.expect(out.draw.quad_len > 0);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 300, 200 }, &out.draw.quads[0].rect);
}

test "runtime: unchanged input needs no frame through the C calls either" {
    const l: CLimits = .{ .nodes = 64, .texts = 64, .strings = 4096, .anims = 16 };
    const buf = try std.testing.allocator.alignedAlloc(u8, .fromByteUnits(mem.column_align), cLimitsBytes(&l));
    defer std.testing.allocator.free(buf);
    try std.testing.expectEqual(0, cInit(buf.ptr, buf.len, &l));
    const in: seam.CInput = .{ .viewport = .{ 300, 200 }, .pointer = .{ 10, 10 } };
    var s: [style_words]u32 = undefined;
    plan.put(Style, .{ .size = .{ .fill, .fill } }, &s);
    var built: u32 = 0;
    for (0..8) |_| {
        if (cNeedsFrame(buf.ptr, &in) == 0) continue;
        built += 1;
        cBegin(buf.ptr, &in);
        _ = cOpen(buf.ptr, 1, &s);
        _ = cButton(buf.ptr, 2, "Go", 2);
        cClose(buf.ptr);
        var out: seam.CFrame = undefined;
        cEnd(buf.ptr, &out);
    }
    try std.testing.expect(built < 8);
}
