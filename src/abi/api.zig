//! The export list: which Zig functions liblcgf exports to C, under which names, and which C
//! name each type that crosses has (docs/plans/bindings-rust.md §6). tools/abi-gen writes the
//! header from it (src/abi/lcgf_api.h), and fails `zig build test` when a `pub fn` of a listed
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
//! A2: this is today's runtime surface (src/abi/runtime.zig's `lcgf_rt_*`) under these names,
//! exported beside the old ones, which A4 deletes.

const std = @import("std");
const abi = @import("abi.zig");
const words = @import("words.zig");
const plan = @import("plan.zig");
const seam = @import("seam.zig");
const runtime = @import("runtime.zig");
const abi_canvas = @import("canvas.zig");
const types = @import("../core/types.zig");
const tree = @import("../core/tree.zig");
const context = @import("../runtime/context.zig");
const Frame = @import("../runtime/frame.zig").Frame;
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
    .{ runtime.CView, "view" },
    .{ runtime.CLimits, "limits" },
    .{ seam.CInput, "input" },
    .{ Input.Event, "key_event" },
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
};

pub const column_align = @import("../core/mem.zig").column_align;

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
    .{ "outline", later_a7 },
    .{ "textf", "comptime format: C formats into lcgf_frame_room, then lcgf_frame_text_written" },
    .{ "textfStyled", "comptime format: C formats into lcgf_frame_room" },
    .{ "interact", later_a7 },
    .{ "drag", later_a7 },
    .{ "lastRect", later_a7 },
    .{ "heldRect", later_a7 },
    .{ "setFill", later_a7 },
    .{ "setCursor", later_a7 },
    .{ "focusScope", later_a7 },
    .{ "animateLayout", later_a7 },
    .{ "sequence", later_a7 },
    .{ "transition", later_a7 },
    .{ "setFillAnimated", later_a7 },
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
    inline for (exports) |E| {
        const name = E.c ++ plan.symbol_suffix;
        if (comptime isC(E.func)) @export(&E.func, .{ .name = name }) else @export(&abi.Wrap(E.func, handles).c, .{ .name = name });
    }
}

/// A function written for C already (`callconv(.c)`), exported as it is.
pub fn isC(comptime f: anytype) bool {
    return @typeInfo(@TypeOf(f)).@"fn".attrs.@"callconv" != .auto;
}

// ---- the functions that stand in -------------------------------------------------------------

const CtxH = abi.Handle(Context);
const FrameH = abi.Handle(Frame);

fn rt(ctx: *CtxH) *runtime.Runtime {
    return @ptrCast(@alignCast(ctx));
}

/// The context a frame was begun on, and what runtime.zig keeps beside it.
fn rtOf(f: *Frame) *runtime.Runtime {
    return @fieldParentPtr("ctx", f.ctx);
}

/// Bytes a context of `limits` needs, its own included: the buffer `lcgf_context_init` takes.
fn contextBytes(limits: *const runtime.CLimits) callconv(.c) usize {
    return runtime.cLimitsBytes(limits);
}

/// Places a context of `limits` at the start of `buf` (LCGF_CONTEXT_ALIGN-aligned): `buf` is
/// then an `lcgf_context *`. Returns an `lcgf_status`.
fn contextInit(buf: *anyopaque, len: usize, limits: *const runtime.CLimits) callconv(.c) c_int {
    return runtime.cInit(@ptrCast(buf), len, limits);
}

/// Whether `in` needs a frame: 0 when nothing would change, so the host can sleep.
fn contextNeedsFrame(ctx: *CtxH, in: *const seam.CInput) callconv(.c) c_int {
    return runtime.cNeedsFrame(ctx, in);
}

/// Starts a frame on `in`, which the context copies: `frame` is valid until `lcgf_frame_end`.
fn contextBegin(ctx: *CtxH, in: *const seam.CInput, frame_out: *FrameH) callconv(.c) void {
    runtime.cBegin(ctx, in);
    @as(*Frame, @ptrCast(@alignCast(frame_out))).* = rt(ctx).frame;
}

/// Lets frames make canvas nodes (`lcgf_frame_canvas`), in `buf`: `lcgf_context_canvas_bytes`
/// of the caller's memory, pointer-aligned, alive as long as the context.
fn contextEnableCanvas(ctx: *CtxH, buf: *anyopaque, len: usize) callconv(.c) c_int {
    return runtime.cEnableCanvas(ctx, @ptrCast(buf), len);
}

/// Bytes `lcgf_context_enable_canvas` needs for `limits`.
fn contextCanvasBytes(limits: *const runtime.CLimits) callconv(.c) usize {
    return runtime.cCanvasBytes(limits);
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

fn frameCanvas(f: *FrameH, id: u32, style: *const abi.Words(types.Style), shapes: *const abi.Handle(canvas.Instances), options: *const abi_canvas.COptions) callconv(.c) u32 {
    const fr: *Frame = @ptrCast(@alignCast(f));
    return runtime.cCanvas(rtOf(fr), id, &style.w, @ptrCast(@alignCast(shapes)), options);
}

fn frameAnimate(f: *Frame, id: types.Id, target: f32, spring: Spring) f32 {
    return f.animate(id, target, spring);
}

fn frameTween(f: *Frame, id: types.Id, target: f32, seconds: f32, ease: Ease) f32 {
    return f.tween(id, target, seconds, ease);
}

/// Lays the frame out and paints it with the context's font: `out` holds the draw list,
/// valid until the next frame begins.
fn frameEnd(f: *FrameH, out: *seam.CFrame) callconv(.c) void {
    const r = rtOf(@ptrCast(@alignCast(f)));
    r.frame = @as(*Frame, @ptrCast(@alignCast(f))).*;
    runtime.cEnd(r, out);
}

/// Where this frame's rows are, for the bindings' inline push (`lcgf_view`): valid until
/// `lcgf_frame_end`.
fn frameView(f: *FrameH, out: *runtime.CView) callconv(.c) void {
    runtime.cView(rtOf(@ptrCast(@alignCast(f))), out);
}

/// The row the tree stores for `style` (`Template.from`): what the _row calls push as it is.
fn templateFrom(style: *const abi.Words(types.Style), out: *tree.FlatRow) callconv(.c) void {
    runtime.cRowFromStyle(&style.w, @ptrCast(out));
}

/// `Style`'s defaults.
fn styleDefault(out: *abi.Words(types.Style)) callconv(.c) void {
    words.put(types.Style, .{}, &out.w);
}

/// The reference widgets' default theme.
fn themeDefault(out: *abi.Words(base.Theme)) callconv(.c) void {
    words.put(base.Theme, .default, &out.w);
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

test "api: a frame through the new names draws what the old names draw" {
    const l: runtime.CLimits = .{ .nodes = 64, .texts = 64, .strings = 4096, .anims = 16 };
    var outs: [2]seam.CFrame = undefined;
    var bufs: [2][]align(64) u8 = undefined;
    for (&bufs) |*b| b.* = try testing.allocator.alignedAlloc(u8, .fromByteUnits(64), contextBytes(&l));
    defer for (bufs) |b| testing.allocator.free(b);
    const in: seam.CInput = .{ .viewport = .{ 300, 200 }, .pointer = .{ 20, 20 } };
    var s: abi.Words(types.Style) = undefined;
    words.put(types.Style, .{ .size = .{ .fill, .fill }, .pad = @splat(4), .fill = .rgb(10, 20, 30) }, &s.w);
    var th: abi.Words(base.Theme) = undefined;
    themeDefault(&th);
    const open = abi.Wrap(Frame.open, handles).c;
    const close = abi.Wrap(Frame.close, handles).c;
    const button = abi.Wrap(base.button, handles).c;
    const slider = abi.Wrap(base.slider, handles).c;
    const animate = abi.Wrap(frameAnimate, handles).c;
    var sp: abi.Words(Spring) = undefined;
    words.put(Spring, .{}, &sp.w);
    for (bufs, &outs, 0..) |b, *out, k| {
        try testing.expectEqual(0, contextInit(b.ptr, b.len, &l));
        var v: f32 = 0.25;
        if (k == 0) {
            runtime.cBegin(b.ptr, &in);
            _ = runtime.cOpen(b.ptr, 1, &s.w);
            _ = runtime.cButton(b.ptr, 2, "Go", 2);
            _ = runtime.cSlider(b.ptr, 3, &v, 0, 1);
            _ = runtime.cAnimate(b.ptr, 4, 1, 170, 26);
            runtime.cClose(b.ptr);
            runtime.cEnd(b.ptr, out);
        } else {
            var f: Frame = undefined;
            const fh: *FrameH = @ptrCast(&f);
            contextBegin(@ptrCast(b.ptr), &in, fh);
            _ = open(fh, 1, &s);
            _ = button(fh, &th, 2, "Go", 2);
            _ = slider(fh, &th, 3, &v, 0, 1);
            _ = animate(fh, 4, 1, &sp);
            close(fh);
            frameEnd(fh, out);
        }
    }
    try testing.expect(outs[0].draw.quad_len > 0);
    try testing.expectEqual(outs[0].draw.quad_len, outs[1].draw.quad_len);
    try testing.expectEqualSlices(u8, std.mem.sliceAsBytes(outs[0].draw.quads[0..outs[0].draw.quad_len]), std.mem.sliceAsBytes(outs[1].draw.quads[0..outs[1].draw.quad_len]));
    try testing.expectEqual(outs[0].draw.run_len, outs[1].draw.run_len);
}

test "api: C names" {
    try testing.expectEqualStrings("lcgf_frame_text_styled", comptime cName("frame", "textStyled"));
    try testing.expectEqualStrings("lcgf_label_text", comptime cName("", "labelText"));
}

test "api: every export compiles" {
    comptime exportAll();
}
