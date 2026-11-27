//! The export list: which Zig functions liblcgf exports to C, under which names, and which C
//! name each type that crosses has (docs/plans/bindings-rust.md §6). tools/abi-gen writes the
//! header from it (src/abi/lcgf.h), and fails `zig build test` when a `pub fn` of a listed
//! container is neither exported nor skipped with a reason (the tripwire).
//!
//! A function of container `k` is exported as `lcgf_<k.prefix>_<snake name>`, or
//! `lcgf_<snake name>` when the prefix is empty (the reference widgets). An entry is one of:
//! - `mech(k, "open")`: `k.T.open` itself, wrapped by `abi.Wrap`;
//! - `by(k, "animate", "frameAnimate")`: a function of this file stands in for it, an
//!   instantiation of a generic one or (until A5, `Input` and `Output` in C form) a
//!   seam-specific one over runtime.zig's context;
//! - `loose("lcgf_layout", "layout")`: a function of this file with no Zig counterpart.
//!
//! The seam-specific entries stand in until `Input`, `Limits` and `Output` cross in C form (A5).

const std = @import("std");
const abi = @import("abi.zig");
const words = @import("words.zig");
const plan = @import("plan.zig");
const seam = @import("seam.zig");
const view = @import("view.zig");
const Mono = @import("../text/protocol.zig").Mono;
const abi_canvas = @import("canvas.zig");
const ct = @import("ct.zig");
const types = @import("../core/types.zig");
const tree = @import("../core/tree.zig");
const context = @import("../runtime/context.zig");
const frame_mod = @import("../runtime/frame.zig");
const Frame = frame_mod.Frame;
const base = @import("../widgets/base.zig");
const values = @import("../anim/values.zig");
const Spring = @import("../anim/anims.zig").Spring;
const Ease = @import("../anim/tweens.zig").Ease;
const canvas = @import("../draw/canvas.zig");
const draw_list = @import("../draw/draw_list.zig");
const Input = @import("../core/input.zig").Input;
const Context = context.Context;

/// Types passed as opaque pointers (`lcgf_frame *`). A `value` handle is also held by value
/// in C: storage of its size, which only Zig reads.
pub const handles = .{ Frame, Context, canvas.Instances };
pub const value_handles = .{Frame};

/// The C name of every type that crosses, after `lcgf_`. A struct with no C layout crosses as
/// its words; an extern struct as itself.
pub const names = .{
    .{ Frame, "frame" },
    .{ Context, "context" },
    .{ canvas.Instances, "canvas" },
    .{ types.Response, "response" },
    .{ types.Style, "style" },
    .{ types.Size, "size" },
    .{ types.TextStyle, "text_style" },
    .{ base.Theme, "theme" },
    .{ Spring, "spring" },
    .{ tree.FlatRow, "row" },
    .{ tree.Look, "look" },
    .{ tree.Extra, "extra" },
    .{ view.CView, "view" },
    .{ context.Limits, "limits" },
    .{ Input, "input" },
    .{ Input.Keys, "keys" },
    .{ Input.Appearance, "appearance" },
    .{ Input.Event, "key_event" },
    .{ Input.Contact, "contact" },
    .{ seam.CFrame, "ui_output" },
    .{ seam.CDraw, "draw" },
    .{ draw_list.Quad, "quad" },
    .{ draw_list.TextRun, "text_run" },
    .{ draw_list.CustomDraw, "custom_draw" },
    .{ abi_canvas.COptions, "canvas_options" },
    .{ abi_canvas.CCamera, "camera" },
    .{ canvas.Layer, "canvas_layer" },
    .{ canvas.Range, "canvas_range" },
    .{ canvas.Override, "canvas_override" },
    .{ types.Rect, "rect" },
    .{ types.Sense, "sense" },
    .{ @import("../draw/outline.zig").Outline, "outline" },
    .{ @import("../anim/keyframes.zig").Key, "key" },
    .{ @import("../anim/tweens.zig").Transition, "transition" },
    .{ abi_canvas.CLine, "canvas_line_style" },
    .{ abi_canvas.CBox, "canvas_box_style" },
    .{ abi_canvas.CArc, "canvas_arc_style" },
    .{ abi_canvas.CArea, "canvas_area_style" },
    .{ abi_canvas.CText, "canvas_text_style" },
    .{ ct.CShortcut, "shortcut" },
};

/// The seam's own C functions, exported where they are (the tables UIs, static UIs and the
/// canvas batch): the header declares them too, with their doc comments and parameter names.
/// The lane-named frames are in the hand-written lcgf_lanes.h.
pub const declared = .{
    .{ "src/abi/seam.zig", seam.exports },
    .{ "src/abi/ct.zig", ct.exports },
    .{ "src/abi/canvas.zig", abi_canvas.exports },
};

pub const column_align = @import("../core/mem.zig").column_align;

/// The bindings' own forms of the Zig types a program writes (bindings/cpp/include/lcgf/
/// types.hpp, bindings/rust/lcgf/src/types.rs, by tools/abi-gen): the enums by name, and the
/// structs field for field with Zig's defaults, laid out as their words (`lcgf_style`).
pub const idiom_enums = .{ .{ types.Axis, "Dir" }, .{ types.Align, "Align" }, .{ types.Role, "Role" }, .{ Ease, "Ease" } };
/// The C structs whose defaults the bindings get as constants (`lcgf::input_default`,
/// `sys::LCGF_INPUT_DEFAULT`): Zig's defaults in C form.
pub const defaults = .{ .{ Input, "input" }, .{ context.Limits, "limits" } };
pub const idiom_structs = .{ .{ types.Size, "Size" }, .{ types.Style, "Style" }, .{ types.TextStyle, "TextStyle" }, .{ base.Theme, "Theme" }, .{ Spring, "Spring" } };

/// Field names C, C++ or Rust cannot take, and what they are called there.
pub const renames = .{.{ "float", "floating" }};

/// What C++ and Rust must agree on to call these functions: the words of every type that
/// crosses as words, and the extern structs (`LCGF_LAYOUT`, `lcgf_layout()`).
pub const layout: u32 = blk: {
    var list: []const type = &.{};
    for (names) |n| if (!isHandle(n[0])) {
        list = list ++ &[_]type{n[0]};
    };
    break :blk words.layoutHashOf(list);
};

fn isHandle(comptime T: type) bool {
    inline for (handles) |H| if (H == T) return true;
    return false;
}

/// Where a function is: its file, its container (`null` for the file's top level) and name.
pub const Loc = struct { file: []const u8, decl: ?[]const u8, name: []const u8 };

/// A container whose `pub fn`s the tripwire checks: each is exported or in `skip`, with why.
pub const Container = struct {
    prefix: []const u8,
    T: type,
    file: []const u8,
    decl: ?[]const u8,
    skip: []const [2][]const u8,
};

/// One export: its C name, the function that implements it, the Zig function it is (`api`,
/// whose doc comment the header carries; null for a loose one) and where the implementation is
/// (`impl`, whose parameter names the header carries).
pub fn Export(comptime c_name: []const u8, comptime f: anytype, comptime api_loc: ?Loc, comptime impl_loc: Loc) type {
    return struct {
        pub const c = c_name;
        pub const func = f;
        pub const api = api_loc;
        pub const impl = impl_loc;
    };
}

/// `fooBar` as `foo_bar`.
pub fn snake(comptime name: []const u8) []const u8 {
    comptime var out: []const u8 = "";
    inline for (name) |ch| out = out ++ if (std.ascii.isUpper(ch)) &[_]u8{ '_', std.ascii.toLower(ch) } else &[_]u8{ch};
    return out;
}

pub fn cName(comptime prefix: []const u8, comptime name: []const u8) []const u8 {
    return "lcgf_" ++ (if (prefix.len == 0) "" else prefix ++ "_") ++ snake(name);
}

fn locOf(comptime k: Container, comptime name: []const u8) Loc {
    return .{ .file = k.file, .decl = k.decl, .name = name };
}

fn mech(comptime k: Container, comptime name: []const u8) type {
    return Export(cName(k.prefix, name), @field(k.T, name), locOf(k, name), locOf(k, name));
}

const this_file = "src/abi/api.zig";

fn by(comptime k: Container, comptime name: []const u8, comptime impl: []const u8) type {
    return Export(cName(k.prefix, name), @field(@This(), impl), locOf(k, name), .{ .file = this_file, .decl = null, .name = impl });
}

fn loose(comptime c_name: []const u8, comptime impl: []const u8) type {
    return Export(c_name, @field(@This(), impl), null, .{ .file = this_file, .decl = null, .name = impl });
}

const later_a5 = "A5: Input, Limits and Output in C form";
const later_a7 = "A7: the full Frame surface, in batches";
const internal = "internal: the tree, columns and passes a binding reaches through lcgf_frame_view";

pub const frame: Container = .{ .prefix = "frame", .T = Frame, .file = "src/runtime/frame.zig", .decl = "Frame", .skip = &.{
    .{ "tree", internal },
    .{ "texts", internal },
    .{ "prevTree", internal },
    .{ "textf", "comptime format: C formats into lcgf_frame_room, then lcgf_frame_text_written" },
    .{ "textfStyled", "comptime format: C formats into lcgf_frame_room" },
    .{ "layoutWith", later_a7 },
    .{ "endFlex", later_a7 },
    .{ "layoutFlex", later_a7 },
    .{ "endFlexOpts", "comptime FlexOptions: endFlex" },
    .{ "layoutFlexOpts", "comptime FlexOptions: layoutFlex" },
    .{ "endParagraphs", later_a7 },
    .{ "layoutParagraphs", later_a7 },
    .{ "endFlexParagraphs", later_a7 },
    .{ "layoutFlexParagraphs", later_a7 },
    .{ "finishParagraphs", later_a7 },
    .{ "endRounded", later_a7 },
    .{ "layoutRounded", later_a7 },
    .{ "arrangeWith", later_a7 },
    .{ "finalizeLayout", later_a7 },
    .{ "endText", later_a7 },
    .{ "layoutText", later_a7 },
    .{ "endTextRounded", later_a7 },
    .{ "endTextStyled", later_a7 },
    .{ "endGrid", later_a7 },
    .{ "layoutGrid", later_a7 },
    .{ "endSides", later_a7 },
    .{ "layoutSides", later_a7 },
    .{ "layoutSidesOpts", "comptime FlexOptions: layoutSides" },
    .{ "finishSides", later_a7 },
    .{ "layoutTextRounded", later_a7 },
    .{ "arrangeText", later_a7 },
    .{ "finish", later_a7 },
    .{ "timer", later_a7 },
    .{ "reuse", later_a7 },
} };

pub const context_: Container = .{ .prefix = "context", .T = Context, .file = "src/runtime/context.zig", .decl = "Context", .skip = &.{
    .{ "trackDamage", later_a7 },
    .{ "canvasRows", internal },
    .{ "redrawAll", later_a7 },
    .{ "initZeroed", "init's form for zeroed memory: lcgf_context_init" },
    .{ "beginWithHit", "the seam's hit-test override, for tables UIs" },
} };

pub const widgets: Container = .{ .prefix = "", .T = base, .file = "src/widgets/base.zig", .decl = null, .skip = &.{
    .{ "unit", "comptime: a spec's unit" },
    .{ "stateIndex", "comptime: ComptimeUi's state fields" },
    .{ "fieldError", "comptime: ComptimeUi's diagnostics" },
    .{ "ctResponse", "ComptimeUi's internal response" },
    .{ "buttonStyle", later_a7 },
    .{ "buttonFill", later_a7 },
    .{ "checkboxStyle", later_a7 },
    .{ "checkboxBox", later_a7 },
    .{ "sliderTrack", later_a7 },
    .{ "sliderThumb", later_a7 },
    .{ "toggle", later_a7 },
    .{ "slide", later_a7 },
    .{ "fraction", later_a7 },
    .{ "ComptimeUi", "comptime: a type" },
    .{ "ComptimeUiTokens", "comptime: a type" },
    .{ "sameDraw", "a test helper" },
    .{ "expectSameFace", "a test helper" },
    .{ "expectReplayAgrees", "zig-only: a test helper" },
    .{ "Harness", "comptime: a test type" },
    .{ "Semantic", "comptime: a test type" },
    .{ "Reference", "comptime: a test type" },
} };

pub const anim_values: Container = .{ .prefix = "values", .T = values, .file = "src/anim/values.zig", .decl = null, .skip = &.{
    .{ "Of", "comptime: a type" },
    .{ "count", "comptime: a type's components" },
    .{ "flatten", "generic: animate's components, done by lcgf_frame_animate per component" },
    .{ "build", "generic: the inverse of flatten" },
} };

pub const containers = .{ frame, context_, widgets, anim_values };

pub const exports = .{
    by(context_, "requiredBytes", "contextBytes"),
    by(context_, "init", "contextInit"),
    by(context_, "needsFrame", "contextNeedsFrame"),
    by(context_, "begin", "contextBegin"),
    by(context_, "enableCanvas", "contextEnableCanvas"),
    loose("lcgf_context_canvas_bytes", "contextCanvasBytes"),
    mech(frame, "open"),
    mech(frame, "close"),
    mech(frame, "leaf"),
    by(frame, "openRow", "frameOpenRow"),
    by(frame, "leafRow", "frameLeafRow"),
    mech(frame, "text"),
    mech(frame, "textStyled"),
    mech(frame, "room"),
    mech(frame, "textWritten"),
    mech(frame, "custom"),
    mech(frame, "outline"),
    mech(frame, "interact"),
    mech(frame, "drag"),
    mech(frame, "lastRect"),
    mech(frame, "heldRect"),
    mech(frame, "setFill"),
    mech(frame, "setCursor"),
    mech(frame, "focusScope"),
    mech(frame, "animateLayout"),
    mech(frame, "sequence"),
    mech(frame, "transition"),
    mech(frame, "setFillAnimated"),
    by(frame, "customRow", "frameCustomRow"),
    by(frame, "canvas", "frameCanvas"),
    by(frame, "animate", "frameAnimate"),
    by(frame, "tween", "frameTween"),
    by(frame, "end", "frameEnd"),
    loose("lcgf_frame_view", "frameView"),
    mech(widgets, "label"),
    mech(widgets, "button"),
    mech(widgets, "checkbox"),
    mech(widgets, "slider"),
    mech(widgets, "labelText"),
    mech(anim_values, "intOf"),
    loose("lcgf_template_from", "templateFrom"),
    loose("lcgf_style_default", "styleDefault"),
    loose("lcgf_theme_default", "themeDefault"),
    loose("lcgf_layout", "layoutHash"),
};

/// The C names, as src/abi/auto.zig's dispatcher reads an export list (`list[k][0]`).
pub const c_names = blk: {
    var out: [exports.len][1][]const u8 = undefined;
    for (exports, &out) |E, *o| o.* = .{E.c};
    break :blk out;
};

pub fn exportAll() void {
    // The canvas batch's own C functions (src/abi/canvas.zig).
    inline for (0..abi_canvas.exports.len) |k| @export(abi_canvas.exports[k][1], .{ .name = abi_canvas.exports[k][0] ++ plan.symbol_suffix });
    inline for (exports) |E| {
        const name = E.c ++ plan.symbol_suffix;
        if (comptime isC(E.func)) @export(&E.func, .{ .name = name }) else @export(&abi.Wrap(E.func, handles).c, .{ .name = name });
    }
}

/// A function written for C already (`callconv(.c)`), exported as it is.
pub fn isC(comptime f: anytype) bool {
    const cc = @typeInfo(@TypeOf(f)).@"fn".attrs.@"callconv";
    // An inlined Zig function (`Frame.open` in a fast build) has no address to export: wrapped.
    return cc != .auto and cc != .@"inline";
}

// ---- the functions that stand in -------------------------------------------------------------

const CtxH = abi.Handle(Context);
const FrameH = abi.Handle(Frame);

const CLimits = abi.Form(context.Limits);
const CInput = abi.Form(Input);

/// What an `lcgf_context` is, at the start of the caller's buffer: the context, the input its
/// frame reads until `lcgf_frame_end` (decoded from the caller's `lcgf_input`, so that may be a
/// temporary), the font the frame is laid out with, and the palettes
/// `lcgf_frame_canvas` makes from its options, in two
/// generations as the canvas rows are (a reused canvas keeps last frame's).
pub const Session = struct {
    ctx: Context,
    input: Input = .{},
    font: Mono = .{},
    palettes: []canvas.Palette = &.{},
    palette_len: u32 = 0,

    fn of(ctx: *CtxH) *Session {
        return @ptrCast(@alignCast(ctx));
    }

    /// The session a frame was begun on.
    fn ofFrame(f: *const Frame) *Session {
        return @fieldParentPtr("ctx", f.ctx);
    }

    fn head() usize {
        return std.mem.alignForward(usize, @sizeOf(Session), column_align);
    }
};

fn frameOf(f: *FrameH) *Frame {
    return @ptrCast(@alignCast(f));
}

/// Bytes a context of `limits` needs, its own included: the buffer `lcgf_context_init` takes.
fn contextBytes(limits: *const CLimits) callconv(.c) usize {
    return Session.head() + Context.requiredBytes(abi.decode(context.Limits, limits));
}

/// Places a context of `limits` at the start of `buf` (LCGF_CONTEXT_ALIGN-aligned): `buf` is
/// then an `lcgf_context *`. Returns an `lcgf_status`.
fn contextInit(buf: *anyopaque, len: usize, limits: *const CLimits) callconv(.c) c_int {
    const bytes: [*]u8 = @ptrCast(buf);
    if (@intFromPtr(bytes) % column_align != 0) return @backingInt(seam.Status.unaligned);
    if (len < contextBytes(limits)) return @backingInt(seam.Status.buffer_too_small);
    const work: []align(column_align) u8 = @alignCast(bytes[Session.head()..len]);
    const s: *Session = @ptrCast(@alignCast(bytes));
    s.* = .{ .ctx = Context.init(work, abi.decode(context.Limits, limits)) catch return @backingInt(seam.Status.buffer_too_small) };
    return 0;
}

/// Whether `in` needs a frame: 0 when nothing would change, so the host can sleep.
fn contextNeedsFrame(ctx: *CtxH, in: *const CInput) callconv(.c) c_int {
    const input = abi.decode(Input, in);
    return @intFromBool(Session.of(ctx).ctx.needsFrame(&input));
}

/// Starts a frame on `in`, which the context copies: `frame` is valid until `lcgf_frame_end`.
fn contextBegin(ctx: *CtxH, in: *const CInput, frame_out: *FrameH) callconv(.c) void {
    const s = Session.of(ctx);
    s.palette_len = 0;
    s.input = abi.decode(Input, in);
    frameOf(frame_out).* = s.ctx.begin(&s.input);
}

/// Lets frames make canvas nodes (`lcgf_frame_canvas`), in `buf`: `lcgf_context_canvas_bytes`
/// of the caller's memory, pointer-aligned, alive as long as the context.
fn contextEnableCanvas(ctx: *CtxH, buf: *anyopaque, len: usize) callconv(.c) c_int {
    const s = Session.of(ctx);
    const bytes: [*]u8 = @ptrCast(buf);
    const n = 2 * @as(usize, s.ctx.limits.customs);
    if (@intFromPtr(bytes) % @alignOf(draw_list.CanvasDraw) != 0) return @backingInt(seam.Status.unaligned);
    if (len < n * (@sizeOf(draw_list.CanvasDraw) + @sizeOf(canvas.Palette))) return @backingInt(seam.Status.buffer_too_small);
    const rows: [*]draw_list.CanvasDraw = @ptrCast(@alignCast(bytes));
    s.palettes = @as([*]canvas.Palette, @ptrCast(@alignCast(bytes + n * @sizeOf(draw_list.CanvasDraw))))[0..n];
    s.ctx.enableCanvas(rows[0..n]);
    return 0;
}

/// Bytes `lcgf_context_enable_canvas` needs for `limits`: the canvas rows and their palettes,
/// two generations of `customs` each.
fn contextCanvasBytes(limits: *const CLimits) callconv(.c) usize {
    return 2 * @as(usize, abi.decode(context.Limits, limits).customs) * (@sizeOf(draw_list.CanvasDraw) + @sizeOf(canvas.Palette));
}

fn frameOpenRow(f: *Frame, id: types.Id, row: *const tree.FlatRow) types.Node {
    return f.openRow(id, row);
}

fn frameLeafRow(f: *Frame, id: types.Id, row: *const tree.FlatRow) types.Node {
    return f.leafRow(id, row);
}

fn frameCustomRow(f: *Frame, id: types.Id, row: *const tree.FlatRow, data: u64) types.Node {
    return f.customRow(id, row, data);
}

/// `Frame.canvas`: `shapes` under the options' camera, palette, ranges and overrides, all of
/// them the caller's until the frame is drawn. LCGF_NO_WIDGET past `customs` canvases a frame.
fn frameCanvas(f: *FrameH, id: u32, style: *const abi.Words(types.Style), shapes: *const abi.Handle(canvas.Instances), options: *const abi_canvas.COptions) callconv(.c) u32 {
    const fr = frameOf(f);
    const s = Session.ofFrame(fr);
    const n = s.palettes.len / 2;
    if (s.palette_len >= n) return std.math.maxInt(u32);
    const pal = &s.palettes[@as(usize, s.ctx.cur) * n + s.palette_len];
    s.palette_len += 1;
    pal.* = options.palette();
    const o: frame_mod.CanvasOptions = .{ .camera = options.cam(), .palette = pal, .ranges = options.spans(), .overrides = options.marks() };
    return fr.canvas(@fromBackingInt(id), words.get(types.Style, &style.w), @ptrCast(@alignCast(shapes)), o).ix();
}

fn frameAnimate(f: *Frame, id: types.Id, target: f32, spring: *const Spring) f32 {
    return f.animate(id, target, spring.*);
}

fn frameTween(f: *Frame, id: types.Id, target: f32, seconds: f32, ease: Ease) f32 {
    return f.tween(id, target, seconds, ease);
}

/// Lays the frame out and paints it with the context's font: `out` holds the draw list,
/// valid until the next frame begins.
fn frameEnd(f: *FrameH, out: *seam.CFrame) callconv(.c) void {
    const fr = frameOf(f);
    const o = fr.end(Session.ofFrame(fr).font);
    out.* = .{ .draw = seam.cDraw(o.draw), .widget = seam.none_widget, .value = 0, .focus = seam.none_widget, .wake = o.wake };
}

/// Where this frame's rows are, for the bindings' inline push (`lcgf_view`): valid until
/// `lcgf_frame_end`.
fn frameView(f: *FrameH, out: *view.CView) callconv(.c) void {
    out.* = view.of(frameOf(f));
}

/// The row the tree stores for `style` (`Template.from`): what the _row calls push as it is.
fn templateFrom(style: *const abi.Words(types.Style), out: *tree.FlatRow) callconv(.c) void {
    const st = words.get(types.Style, &style.w);
    words.put(tree.Template, .from(&st), @as(*[words.wordsOf(tree.Template)]u32, @ptrCast(out)));
}

/// `Style`'s defaults.
fn styleDefault(out: *abi.Words(types.Style)) callconv(.c) void {
    words.put(types.Style, .{}, &out.w);
}

/// The reference widgets' default theme.
fn themeDefault(out: *base.Theme) callconv(.c) void {
    out.* = .default;
}

/// The layout this library reads (`LCGF_LAYOUT`): compare before making a context.
fn layoutHash() callconv(.c) u32 {
    return layout;
}

comptime {
    // `lcgf_frame` is this many pointers in C (abi-gen spells it so).
    std.debug.assert(@sizeOf(Frame) == 2 * @sizeOf(usize));
}

const testing = std.testing;

fn cOf(comptime T: type, v: T) abi.Form(T) {
    var c: abi.Form(T) = undefined;
    abi.encode(T, v, &c);
    return c;
}

test "api: a frame through the C calls draws what Zig draws" {
    const zl: context.Limits = .{ .nodes = 64, .texts = 64, .strings = 4096, .anims = 16 };
    const l = cOf(context.Limits, zl);
    const n = contextBytes(&l);
    const cbuf = try testing.allocator.alignedAlloc(u8, .fromByteUnits(column_align), n);
    defer testing.allocator.free(cbuf);
    const zbuf = try testing.allocator.alignedAlloc(u8, .fromByteUnits(column_align), Context.requiredBytes(zl));
    defer testing.allocator.free(zbuf);
    var in = cOf(Input, .{ .viewport = .{ 300, 200 }, .pointer = .{ 20, 20 } });
    const st: types.Style = .{ .size = .{ .fill, .fill }, .pad = @splat(4), .fill = .rgb(10, 20, 30) };
    var s: abi.Words(types.Style) = undefined;
    words.put(types.Style, st, &s.w);
    var th: base.Theme = undefined;
    themeDefault(&th);
    const sp: Spring = .{};

    // Through the C calls. The context copies the input: changing ours mid-frame changes nothing.
    try testing.expectEqual(0, contextInit(cbuf.ptr, cbuf.len, &l));
    var f: Frame = undefined;
    const fh: *FrameH = @ptrCast(&f);
    contextBegin(@ptrCast(cbuf.ptr), &in, fh);
    in.f.viewport = .{ 1, 1 };
    var v: f32 = 0.25;
    var on = false;
    _ = abi.Wrap(Frame.open, handles).c(fh, 1, &s);
    _ = abi.Wrap(base.button, handles).c(fh, &th, 2, "Go", 2);
    _ = abi.Wrap(base.checkbox, handles).c(fh, &th, 3, &on, "On", 2);
    _ = abi.Wrap(base.slider, handles).c(fh, &th, 4, &v, 0, 1);
    _ = abi.Wrap(frameAnimate, handles).c(fh, 5, 1, &sp);
    abi.Wrap(Frame.close, handles).c(fh);
    var out: seam.CFrame = undefined;
    frameEnd(fh, &out);

    // In Zig.
    var ctx = try Context.init(zbuf, zl);
    const zin: Input = .{ .viewport = .{ 300, 200 }, .pointer = .{ 20, 20 } };
    var zf = ctx.begin(&zin);
    var zv: f32 = 0.25;
    var zon = false;
    _ = zf.open(@fromBackingInt(1), st);
    _ = base.button(&zf, &th, @fromBackingInt(2), "Go");
    _ = base.checkbox(&zf, &th, @fromBackingInt(3), &zon, "On");
    _ = base.slider(&zf, &th, @fromBackingInt(4), &zv, 0, 1);
    _ = zf.animate(@fromBackingInt(5), @as(f32, 1), sp);
    zf.close();
    const zo = zf.end(.{});

    try testing.expect(out.draw.quad_len > 0);
    try testing.expectEqualSlices(f32, &.{ 0, 0, 300, 200 }, &out.draw.quads[0].rect);
    try testing.expectEqual(zo.draw.quad_len, out.draw.quad_len);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(zo.draw.quads[0..zo.draw.quad_len]), std.mem.sliceAsBytes(out.draw.quads[0..out.draw.quad_len]));
    try testing.expectEqual(zo.draw.run_len, out.draw.run_len);
}

test "api: a row pushed through the C calls is the node its style makes" {
    const zl: context.Limits = .{ .nodes = 64, .texts = 64, .strings = 4096, .anims = 16 };
    const l = cOf(context.Limits, zl);
    var bufs: [2][]align(column_align) u8 = undefined;
    for (&bufs) |*b| b.* = try testing.allocator.alignedAlloc(u8, .fromByteUnits(column_align), contextBytes(&l));
    defer for (bufs) |b| testing.allocator.free(b);
    const in = cOf(Input, .{ .viewport = .{ 300, 200 } });
    const styles = [_]types.Style{
        .{ .size = .{ .fill, .fill }, .pad = @splat(8), .fill = .rgb(10, 20, 30) },
        .{ .size = .{ .px(40), .pct(0.5) }, .radius = 4, .border = 1, .border_color = .rgb(1, 2, 3), .clip = true },
        .{ .dir = .x, .gap = 3, .opacity = 0.5, .radii = .{ 1, 2, 3, 4 } },
    };
    var outs: [2]seam.CFrame = undefined;
    for (bufs, &outs, 0..) |b, *out, k| {
        try testing.expectEqual(0, contextInit(b.ptr, b.len, &l));
        var f: Frame = undefined;
        const fh: *FrameH = @ptrCast(&f);
        contextBegin(@ptrCast(b.ptr), &in, fh);
        for (styles, 0..) |st, i| {
            var w: abi.Words(types.Style) = undefined;
            words.put(types.Style, st, &w.w);
            var row: tree.FlatRow = undefined;
            templateFrom(&w, &row);
            const id: u32 = @intCast(i + 1);
            if (k == 0) {
                _ = abi.Wrap(Frame.open, handles).c(fh, id, &w);
                _ = abi.Wrap(Frame.leaf, handles).c(fh, 100 + id, &w);
                _ = abi.Wrap(Frame.custom, handles).c(fh, 200 + id, &w, 7);
            } else {
                _ = abi.Wrap(frameOpenRow, handles).c(fh, id, &row);
                _ = abi.Wrap(frameLeafRow, handles).c(fh, 100 + id, &row);
                _ = abi.Wrap(frameCustomRow, handles).c(fh, 200 + id, &row, 7);
            }
        }
        for (styles) |_| abi.Wrap(Frame.close, handles).c(fh);
        frameEnd(fh, out);
    }
    try testing.expect(outs[0].draw.quad_len > 0);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(outs[0].draw.quads[0..outs[0].draw.quad_len]), std.mem.sliceAsBytes(outs[1].draw.quads[0..outs[1].draw.quad_len]));
    try testing.expectEqual(outs[0].draw.custom_len, outs[1].draw.custom_len);
}

test "api: unchanged input needs no frame through the C calls" {
    const zl: context.Limits = .{ .nodes = 64, .texts = 64, .strings = 4096, .anims = 16 };
    const l = cOf(context.Limits, zl);
    const buf = try testing.allocator.alignedAlloc(u8, .fromByteUnits(column_align), contextBytes(&l));
    defer testing.allocator.free(buf);
    try testing.expectEqual(0, contextInit(buf.ptr, buf.len, &l));
    const in = cOf(Input, .{ .viewport = .{ 300, 200 }, .pointer = .{ 10, 10 } });
    var th: base.Theme = undefined;
    themeDefault(&th);
    var built: u32 = 0;
    for (0..8) |_| {
        if (contextNeedsFrame(@ptrCast(buf.ptr), &in) == 0) continue;
        built += 1;
        var f: Frame = undefined;
        const fh: *FrameH = @ptrCast(&f);
        contextBegin(@ptrCast(buf.ptr), &in, fh);
        _ = abi.Wrap(base.button, handles).c(fh, &th, 2, "Go", 2);
        var out: seam.CFrame = undefined;
        frameEnd(fh, &out);
    }
    try testing.expect(built < 8);
}

test "api: the words a binding passes" {
    try testing.expectEqual(59, words.wordsOf(types.Style));
    try testing.expectEqual(4, words.wordsOf(types.TextStyle));
    try testing.expectEqual(66, words.wordsOf(tree.Template));
    try testing.expectEqual(66 * 4, @sizeOf(tree.FlatRow));
}

test "api: FlatRow is a Template's words, field for field" {
    try std.testing.expectEqual(words.wordsOf(tree.Template) * 4, @sizeOf(tree.FlatRow));
    const st: types.Style = .{ .size = .{ .px(40), .pct(0.5) }, .pad = .{ 1, 2, 3, 4 }, .dir = .x, .cross = .end, .clip = true, .fill = .rgb(1, 2, 3), .border_color = .rgb(4, 5, 6), .radius = 7, .texture = @fromBackingInt(@intCast(9)), .material = @fromBackingInt(@intCast(11)), .params = .{ 12, 13, 14, 15 }, .role = .slider, .value = 0.25, .border = 2, .uv = .{ 0.1, 0.2, 0.3, 0.4 }, .radii = .{ 5, -1, 6, -1 }, .opacity = 0.5, .transform = .{ 2, 0, 0, 2, 3, 4 } };
    const t: tree.Template = .from(&st);
    var flat: tree.FlatRow = undefined;
    words.put(tree.Template, t, @ptrCast(&flat));
    inline for (@typeInfo(tree.Template).@"struct".field_names) |name| {
        if (comptime std.mem.eql(u8, name, "look")) {
            inline for (@typeInfo(@TypeOf(t.look)).@"struct".field_names) |g|
                try std.testing.expectEqual(@as(@FieldType(tree.FlatRow, g), @field(t.look, g)), @field(flat, g));
        } else switch (@typeInfo(@FieldType(tree.Template, name))) {
            .int => try std.testing.expectEqual(@as(u32, @field(t, name)), @field(flat, name)),
            .@"struct" => try std.testing.expectEqual(@as(u32, @as(u8, @bitCast(@field(t, name)))), @field(flat, name)),
            else => try std.testing.expectEqual(@field(t, name), @field(flat, name)),
        }
    }
}

test "api: C names" {
    try testing.expectEqualStrings("lcgf_frame_text_styled", comptime cName("frame", "textStyled"));
    try testing.expectEqualStrings("lcgf_label_text", comptime cName("", "labelText"));
}

test "api: every export compiles" {
    comptime exportAll();
}
