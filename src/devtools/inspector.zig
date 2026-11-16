//! The inspector: a debug panel built with the framework itself (dogfooding, after Clay's
//! built-in debug tools). It is a few more nodes in the application's own frame, a floating
//! panel in the bottom-right corner, built from the same `Frame` calls and widgets as any UI.
//! Nothing in the core knows it exists: it reads only plain data the core already exposes.
//!
//! The application builds it last, after its own UI, in the same frame:
//!
//!     app.build(&f, &ev);
//!     insp.build(&f);
//!     const out = f.end(.{});
//!
//! What it shows is last frame's `Output`: `f.prevTree()` is last frame's tree, and the context's
//! draw list still holds last frame's commands until this frame's paint. So the inspector needs
//! no hook after `end` and runs inside `shell.iface.run` unchanged, one frame behind the UI.
//! Its own rows are the last rows of the tree (it builds last), so the rows it inspects are the
//! ones below where it started last frame.
//!
//! F12 shows and hides it. While shown, the panel takes the pointer: clicks on it do not reach
//! the application underneath.

const std = @import("std");
const types = @import("../core/types.zig");
const Frame = @import("../runtime/frame.zig").Frame;
const Tree = @import("../core/tree.zig").Tree;
const w = @import("../widgets/base.zig");
const none = types.none;
const Id = types.Id;
const Color = types.Color;
const Rect = types.Rect;

pub const id_panel = Id.from("devtools.inspector");
/// F12, as a USB HID usage id (the scancodes `Input.keys` and key events carry).
pub const toggle_key: u8 = 0x45;
pub const id_rects = Id.from("devtools.rects");
pub const id_clips = Id.from("devtools.clips");

pub const Inspector = struct {
    open: bool = true,
    /// Panel size in logical pixels; it sits `margin` from the bottom-right corner.
    size: [2]f32 = .{ 320, 440 },
    margin: f32 = 8,
    text_px: f32 = 12,
    text: Color = .rgb(220, 222, 230),
    dim: Color = .rgb(140, 145, 160),
    panel: Color = .rgba(16, 17, 21, 240),
    border: Color = .rgb(90, 140, 255),
    /// The panel's own widgets (the checkboxes).
    theme: w.Theme = .{ .text_px = 12 },
    /// Rows of the tree listing; the rest are cut.
    max_lines: u32 = 12,
    /// Outline every application node's layout rect (`Tree.Columns.rect`).
    show_rects: bool = false,
    /// Outline the visible part (`Tree.Columns.vis`) of every node its ancestors clip.
    show_clips: bool = false,
    rect_color: Color = .rgb(80, 220, 120),
    clip_color: Color = .rgb(255, 150, 40),
    /// Laid over the node under the pointer, outlined in `border`.
    hover_fill: Color = .rgba(90, 140, 255, 60),

    /// Row where the inspector's own nodes began last frame: rows below it are the application's.
    own_first: u32 = none,
    /// Application rows in the tree being inspected (last frame's).
    rows: u32 = 0,
    /// Topmost application row under the pointer in last frame's tree, or `none`.
    hovered: u32 = none,

    /// Inspects last frame's output and builds the panel. Call last, after the application's UI.
    pub fn build(insp: *Inspector, f: *Frame) void {
        for (f.in.events) |e| insp.open = insp.open != (e.kind == .press and e.code == toggle_key);
        const prev = f.prevTree();
        insp.rows = @min(insp.own_first, prev.len);
        insp.hovered = under(prev, insp.rows, f.in.pointer);
        insp.own_first = f.tree().len;
        if (!insp.open) return;

        insp.outlines(f, prev);
        const vp = f.in.viewport;
        const root = f.open(id_panel, .{
            .float = true,
            .offset = .{ vp[0] - insp.size[0] - insp.margin, vp[1] - insp.size[1] - insp.margin },
            .size = .{ .px(insp.size[0]), .px(insp.size[1]) },
            .pad = @splat(8),
            .gap = 2,
            .clip = true,
            .fill = insp.panel,
            .border = 1,
            .border_color = insp.border,
            .radius = 4,
        });
        // The panel is on top of the application, so it takes the pointer from what is under it.
        _ = f.interact(root, .{ .hover = true, .click = true });
        insp.line(f, insp.text, "Inspector  {d} nodes", .{insp.rows});
        insp.hoveredLine(f, prev);
        _ = f.open(.none, .{ .dir = .x, .gap = 12 });
        _ = w.checkbox(f, &insp.theme, id_rects, &insp.show_rects, "Layout rects");
        _ = w.checkbox(f, &insp.theme, id_clips, &insp.show_clips, "Clip rects");
        f.close();
        insp.treeLines(f, prev);
        f.close();
    }

    /// Boxes over the application, under the panel: layout rects, clip rects and the hovered
    /// node, each a floating, bordered leaf at last frame's rect. They take no input.
    fn outlines(insp: *const Inspector, f: *Frame, prev: *const Tree) void {
        // A zero-size floating group at the root's origin, so a child's offset is its position.
        _ = f.open(.none, .{ .float = true });
        for (0..insp.rows) |k| {
            const i: u32 = @intCast(k);
            const r = prev.rect(i);
            if (insp.show_rects) box(f, r, insp.rect_color, .transparent);
            const v = visRect(prev, i);
            const clipped = !std.meta.eql(v, r) and v.w() > 0 and v.h() > 0;
            if (insp.show_clips and clipped) box(f, v, insp.clip_color, .transparent);
        }
        if (insp.hovered != none) box(f, prev.rect(insp.hovered), insp.border, insp.hover_fill);
        f.close();
    }

    fn hoveredLine(insp: *const Inspector, f: *Frame, prev: *const Tree) void {
        if (insp.hovered == none) return insp.line(f, insp.dim, "hover: nothing", .{});
        const r = prev.rect(insp.hovered);
        insp.line(f, insp.text, "hover: #{d} {s} {d:.0}x{d:.0} at {d:.0},{d:.0}", .{ insp.hovered, roleName(prev, insp.hovered), r.w(), r.h(), r.x0, r.y0 });
    }

    /// Depth-first rows, indented by depth; the hovered row is marked.
    fn treeLines(insp: *const Inspector, f: *Frame, prev: *const Tree) void {
        const n = @min(insp.rows, insp.max_lines);
        for (0..n) |k| {
            const i: u32 = @intCast(k);
            const r = prev.rect(i);
            const pad = "                ";
            const indent = pad[0..@min(2 * depth(prev, i), pad.len)];
            const mark: []const u8 = if (i == insp.hovered) ">" else " ";
            insp.line(f, insp.dim, "{s}{s}{s} {d:.0}x{d:.0}", .{ mark, indent, roleName(prev, i), r.w(), r.h() });
        }
        if (insp.rows > n) insp.line(f, insp.dim, "  ... {d} more", .{insp.rows - n});
    }

    fn line(insp: *const Inspector, f: *Frame, color: Color, comptime fmt: []const u8, args: anytype) void {
        var buf: [96]u8 = undefined;
        _ = f.text(std.fmt.bufPrint(&buf, fmt, args) catch &buf, .{ .px = insp.text_px, .color = color });
    }
};

/// Topmost of rows `0..n` of `t` whose visible rect holds `p`, or `none`. Later rows paint on top.
pub fn under(t: *const Tree, n: u32, p: [2]f32) u32 {
    var found: u32 = none;
    for (0..n) |i| {
        const inside = p[0] >= t.c.vis[0][i] and p[0] < t.c.vis[2][i] and p[1] >= t.c.vis[1][i] and p[1] < t.c.vis[3][i];
        if (inside) found = @intCast(i);
    }
    return found;
}

/// Row `i`'s layout rect cut down to its inherited clip: what is visible and hit-tested.
pub fn visRect(t: *const Tree, i: u32) Rect {
    return .{ .x0 = t.c.vis[0][i], .y0 = t.c.vis[1][i], .x1 = t.c.vis[2][i], .y1 = t.c.vis[3][i] };
}

fn box(f: *Frame, r: Rect, line: Color, fill: Color) void {
    _ = f.leaf(.none, .{ .float = true, .offset = .{ r.x0, r.y0 }, .size = .{ .px(r.w()), .px(r.h()) }, .border = 1, .border_color = line, .fill = fill });
}

/// Parent links to the root: the root is depth 0.
pub fn depth(t: *const Tree, i: u32) u32 {
    var d: u32 = 0;
    var j = i;
    while (j != 0) : (d += 1) j = t.c.parent[j];
    return d;
}

fn roleName(t: *const Tree, i: u32) []const u8 {
    return @tagName(@as(types.Role, @fromBackingInt(@intCast(t.c.role[i]))));
}

// ---- tests: the inspector inside the example (src/shell/example.zig) -----------------------

const testing = std.testing;
const mem = @import("../core/mem.zig");
const Input = @import("../core/input.zig").Input;
const Quad = @import("../draw/draw_list.zig").Quad;
const context = @import("../runtime/context.zig");
const sw = @import("../render/sw/sw.zig");
const iface = @import("../shell/iface.zig");
const Headless = @import("../shell/headless.zig").Headless;
const example = @import("../shell/example.zig");

/// The example with the inspector built after it: what an application does to get one.
pub const ExampleHost = struct {
    app: example.App = .{},
    insp: Inspector = .{},

    pub fn build(h: *ExampleHost, f: *Frame, ev: *const iface.Events) void {
        h.app.build(f, ev);
        h.insp.build(f);
    }
};

const example_limits: context.Limits = .{ .nodes = 1024, .texts = 256 };
const fb_w = 800;
const fb_h = 600;

const Fixture = struct {
    var ctx_buffer: [context.Context.requiredBytes(example_limits)]u8 align(mem.column_align) = undefined;
    var pixels: [sw.Framebuffer.len(fb_w, fb_h)]u32 = undefined;
    var glyphs: [4096]Quad = undefined;
    var first: [example_limits.texts]u32 = undefined;
    var count: [example_limits.texts]u32 = undefined;
    var text: [64]u8 = undefined;
    var events: [16]Input.Event = undefined;
    var contacts: [4]Input.Contact = undefined;

    fn shell(recording: []const u8) Headless {
        return .init(recording, fb_w, fb_h, .{
            .replay = .{ .text = &text, .events = &events, .contacts = &contacts },
            .pixels = &pixels,
            .glyphs = &glyphs,
            .first = &first,
            .count = &count,
        });
    }
};

/// The frame's text contains `needle`.
fn shows(out: *const context.Output, needle: []const u8) bool {
    return std.mem.indexOf(u8, out.draw.strings, needle) != null;
}

test "inspector runs inside the example: the recording does what it did without it" {
    var ctx = try context.Context.init(&Fixture.ctx_buffer, example_limits);
    var host: ExampleHost = .{};
    var shell = Fixture.shell(@embedFile("../shell/testdata/example.replay"));
    iface.run(&shell, &ctx, &host);
    try testing.expectEqual(null, shell.err);
    // The same results as src/shell/headless.zig's test without the inspector.
    try testing.expectEqual(@as(u32, 15), shell.polls);
    try testing.expectEqual(@as(u32, 13), host.app.builds);
    try testing.expectEqual(@as(u32, 1), host.app.resets);
    try testing.expectEqual(@as(u32, 4), host.app.layers);
    try testing.expectApproxEqAbs(@as(f32, 3), host.app.exposure, 0.01);
    // It inspected the application's rows only: the example's 18 rows with 4 layers (root,
    // toolbar 8, body, sidebar 7, viewport); its own rows (outlines, then the panel) follow.
    try testing.expectEqual(@as(u32, 18), host.insp.rows);
    try testing.expectEqual(host.insp.rows, host.insp.own_first);
    try testing.expect(ctx.trees[ctx.cur].find(id_panel) > host.insp.own_first);
    // Drawn: the panel's border and face in the bottom-right corner, the app's sidebar untouched.
    try testing.expectEqual(host.insp.border, shell.fb.at(fb_w - 8 - 150, fb_h - 9));
    try testing.expectEqual(host.app.theme.panel, shell.fb.at(80, 590));
    // The pointer ended over the viewport (160, 50 .. 800, 600): it is outlined.
    try testing.expectEqual(host.insp.border, shell.fb.at(160, 300));
}

test "inspector runs inside the example with layout and clip rects drawn" {
    var ctx = try context.Context.init(&Fixture.ctx_buffer, example_limits);
    var host: ExampleHost = .{ .insp = .{ .show_rects = true, .show_clips = true } };
    var shell = Fixture.shell(@embedFile("../shell/testdata/example.replay"));
    iface.run(&shell, &ctx, &host);
    try testing.expectEqual(null, shell.err);
    try testing.expectEqual(@as(u32, 13), host.app.builds);
    try testing.expectEqual(@as(u32, 1), host.app.resets);
    try testing.expectEqual(@as(u32, 4), host.app.layers);
    try testing.expectApproxEqAbs(@as(f32, 3), host.app.exposure, 0.01);
    // The Reset button (8, 8 .. 66, 42) is outlined; inside it is its face.
    try testing.expectEqual(host.insp.rect_color, shell.fb.at(8, 30));
    try testing.expectEqual(host.app.theme.control, shell.fb.at(10, 30));
    // The checkboxes in the panel show what is on.
    const t = &ctx.trees[ctx.cur];
    try testing.expectEqual(@as(f32, 1), t.c.value[t.find(id_rects)]);
    try testing.expectEqual(@as(f32, 1), t.c.value[t.find(id_clips)]);
}

/// A 100 x 100 clipping box holding a 200 x 50 child: the child is cut at x = 100.
const ClipApp = struct {
    pub fn build(_: *ClipApp, f: *Frame, _: *const iface.Events) void {
        _ = f.open(.from("clipper"), .{ .size = .{ .px(100), .px(100) }, .clip = true });
        _ = f.leaf(.from("wide"), .{ .size = .{ .px(200), .px(50) } });
        f.close();
    }
};

test "inspector: a clipped node shows its layout rect and its visible rect" {
    var ctx = try context.Context.init(&Fixture.ctx_buffer, example_limits);
    var host: struct {
        app: ClipApp = .{},
        insp: Inspector = .{ .show_rects = true, .show_clips = true },
        pub fn build(h: anytype, f: *Frame, ev: *const iface.Events) void {
            h.app.build(f, ev);
            h.insp.build(f);
        }
    } = .{};
    var shell = Fixture.shell("frame\nviewport 800 600\nframe\n");
    iface.run(&shell, &ctx, &host);
    try testing.expectEqual(@as(u32, 2), shell.presents);
    const prev = &ctx.trees[ctx.cur ^ 1];
    const wide = prev.find(.from("wide"));
    try testing.expectEqual(Rect{ .x0 = 0, .y0 = 0, .x1 = 200, .y1 = 50 }, prev.rect(wide));
    try testing.expectEqual(Rect{ .x0 = 0, .y0 = 0, .x1 = 100, .y1 = 50 }, visRect(prev, wide));
    // The layout rect's right edge past the clip, the visible rect's right edge at it.
    try testing.expectEqual(host.insp.rect_color, shell.fb.at(199, 25));
    try testing.expectEqual(host.insp.clip_color, shell.fb.at(99, 25));
    try testing.expectEqual(shell.background, shell.fb.at(150, 75));
}

test "inspector: names the node under the pointer, takes the pointer, hides on F12" {
    var ctx = try context.Context.init(&Fixture.ctx_buffer, example_limits);
    var host: ExampleHost = .{};
    var in: Input = .{ .viewport = .{ 800, 600 }, .pointer = .{ 80, 400 } };
    var f = ctx.begin(&in);
    host.build(&f, &.{ .in = in });
    _ = f.end(.{});
    f = ctx.begin(&in);
    host.build(&f, &.{ .in = in });
    var out = f.end(.{});
    // The sidebar: a 160 x 550 node at (0, 50), row 10 of the example's tree (it has no role).
    const sidebar = out.tree.find(example.id_sidebar);
    try testing.expectEqual(sidebar, host.insp.hovered);
    try testing.expect(shows(&out, "hover: #10 none 160x550 at 0,50"));
    try testing.expect(shows(&out, ">    none 160x550"));
    try testing.expect(shows(&out, "Inspector  17 nodes"));

    // Over the panel the pointer belongs to the panel, not the viewport under it.
    in.pointer = .{ 700, 500 };
    f = ctx.begin(&in);
    host.build(&f, &.{ .in = in });
    out = f.end(.{});
    try testing.expectEqual(@backingInt(id_panel), ctx.inter.hot);

    // F12 hides it: no panel rows, and the application's rows are all there is.
    const press = [_]Input.Event{.{ .kind = .press, .code = toggle_key }};
    in.events = &press;
    f = ctx.begin(&in);
    host.build(&f, &.{ .in = in });
    out = f.end(.{});
    try testing.expectEqual(none, out.tree.find(id_panel));
    try testing.expectEqual(out.tree.len, host.insp.own_first);
}
