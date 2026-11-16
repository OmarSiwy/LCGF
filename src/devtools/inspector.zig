//! The inspector: a debug panel built with the framework itself (dogfooding, after Clay's
//! built-in debug tools). It is a few more nodes in the application's own frame, a floating
//! panel in the bottom-right corner, built from the same `Frame` calls and widgets as any UI.
//! Nothing in the core knows it exists: it reads only plain data the core already exposes.
//!
//! It lives in the `devtools` module (src/devtools/devtools.zig), not in `lcgr`. The
//! application builds it last, after its own UI, in the same frame:
//!
//!     var insp: devtools.Inspector = .{};   // const devtools = @import("devtools");
//!     ...
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
const types = @import("lcgr").types;
const Frame = @import("lcgr").frame.Frame;
const Tree = @import("lcgr").tree.Tree;
const w = @import("lcgr").widgets_base;
const timing = @import("timing.zig");
const EventLog = @import("log.zig").EventLog;
const batches = @import("batches.zig");
const changes = @import("changes.zig");
const Recorder = @import("record.zig").Recorder;
const DrawList = @import("lcgr").draw_list.DrawList;
const none = types.none;
const Id = types.Id;
const Color = types.Color;
const Rect = types.Rect;

pub const id_panel = Id.from("devtools.inspector");
/// F12, as a USB HID usage id (the scancodes `Input.keys` and key events carry).
pub const toggle_key: u8 = 0x45;
pub const id_rects = Id.from("devtools.rects");
pub const id_clips = Id.from("devtools.clips");
pub const id_overdraw = Id.from("devtools.overdraw");
pub const id_record = Id.from("devtools.record");

pub const Inspector = struct {
    open: bool = true,
    /// Panel size in logical pixels; it sits `margin` from the bottom-right corner.
    size: [2]f32 = .{ 320, 540 },
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
    /// Tint every application quad, clipped, so overlaps show as deeper colour.
    show_overdraw: bool = false,
    overdraw_fill: Color = .rgba(255, 40, 40, 50),
    /// Batches listed; the rest are counted.
    batch_lines: u32 = 4,
    /// Where a session is recorded, in the caller's buffer (`Recorder.init`); null: no
    /// recording, and no "Rec" checkbox.
    recorder: ?Recorder = null,
    /// Append each frame's input to `recorder`.
    recording: bool = false,
    /// Signals whose version moved since last frame's build.
    signals: changes.SignalWatch = .{},
    /// This frame's `Frame.reuse` decisions; the application asks through `insp.reuses.reuse`.
    reuses: changes.ReuseLog = .{},
    /// Lines of either list shown.
    change_lines: u32 = 4,
    /// The application's draw commands in last frame's draw list.
    draw: batches.Stats = .{},
    rect_color: Color = .rgb(80, 220, 120),
    clip_color: Color = .rgb(255, 150, 40),
    /// Laid over the node under the pointer, outlined in `border`.
    hover_fill: Color = .rgba(90, 140, 255, 60),
    /// Per-pass times of a frame, set by the host (`timing.end`); shown when not all zero.
    timings: timing.Timings = .{},
    /// What reached the UI, newest last on screen.
    log: EventLog = .{},
    /// Lines of the log shown.
    log_lines: u32 = 6,
    /// A pass as long as the longest gets a bar this wide.
    bar_px: f32 = 120,

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
        insp.log.record(f.ctx.frame, f.in, &f.ctx.inter, prev);
        // Paint has not run yet: the context's draw list and last generation are last frame's.
        const ctx = f.ctx;
        insp.draw = batches.stats(&ctx.draw, prev, insp.rows, ctx.texts[ctx.cur ^ 1].c.node, ctx.customs[ctx.cur ^ 1].c.node, f.in.viewport);
        insp.hovered = under(prev, insp.rows, f.in.pointer);
        insp.own_first = f.tree().len;
        insp.signals.diff(&f.ctx.signals);
        if (insp.recorder) |*r| if (insp.recording) r.frame(f.in);
        defer insp.reuses.clear();
        if (!insp.open) return;

        insp.outlines(f, prev, &f.ctx.draw);
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
        _ = w.checkbox(f, &insp.theme, id_rects, &insp.show_rects, "Rects");
        _ = w.checkbox(f, &insp.theme, id_clips, &insp.show_clips, "Clips");
        _ = w.checkbox(f, &insp.theme, id_overdraw, &insp.show_overdraw, "Overdraw");
        if (insp.recorder != null) _ = w.checkbox(f, &insp.theme, id_record, &insp.recording, "Rec");
        f.close();
        if (insp.recorder) |*r| insp.line(f, insp.dim, "rec: {d} frames, {d} bytes{s}", .{ r.frames, r.len, if (r.full) " (full)" else "" });
        insp.drawLines(f, &f.ctx.draw);
        insp.changeLines(f);
        insp.logLines(f);
        insp.timingLines(f);
        insp.treeLines(f, prev);
        f.close();
    }

    /// Command counts, overdraw, and the first batches: quads per draw, texture and material.
    fn drawLines(insp: *const Inspector, f: *Frame, d: *const DrawList) void {
        const s = &insp.draw;
        insp.line(f, insp.text, "draw {d} cmds: {d} batches {d} text {d} custom", .{ s.cmds, s.batches, s.texts, s.customs });
        insp.line(f, insp.dim, "{d} quads, overdraw {d:.2}x", .{ s.quads, s.overdraw });
        var shown: u32 = 0;
        for (0..s.cmds) |k| switch (d.command(@intCast(k))) {
            .quads => |b| {
                if (shown < insp.batch_lines) insp.line(f, insp.dim, "  cmd {d}: {d} quads tex {d} mat {d}", .{ k, b.count, @backingInt(b.texture), @backingInt(b.material) });
                shown += 1;
            },
            else => {},
        };
    }

    /// Signals that changed, and what `reuse` decided for each subtree this frame.
    fn changeLines(insp: *const Inspector, f: *Frame) void {
        const sg = &insp.signals;
        insp.line(f, insp.text, "signals: {d} changed", .{sg.changed_len});
        for (0..@min(sg.changed_len, insp.change_lines)) |k| insp.line(f, insp.dim, "  #{d} now v{d}", .{ sg.changed[k], sg.version[k] });
        const ru = &insp.reuses;
        var kept: u32 = 0;
        for (ru.decision[0..ru.len]) |d| kept += @intFromBool(d == .reused);
        insp.line(f, insp.text, "reuse: {d} of {d} copied", .{ kept, ru.len + ru.dropped });
        for (0..@min(ru.len, insp.change_lines)) |k| insp.line(f, insp.dim, "  {x:0>8} {s}", .{ ru.id[k], @tagName(ru.decision[k]) });
    }

    fn logLines(insp: *const Inspector, f: *Frame) void {
        const n = @min(insp.log.kept(), insp.log_lines);
        insp.line(f, insp.text, "events ({d})", .{insp.log.count});
        for (0..n) |k| insp.line(f, insp.dim, "{s}", .{insp.log.newest(@intCast(n - 1 - k))});
    }

    /// One line per pass: its name, its time, and a bar scaled to the longest pass.
    fn timingLines(insp: *const Inspector, f: *Frame) void {
        const tm = &insp.timings;
        const total = tm.total();
        if (total == 0) return;
        insp.line(f, insp.text, "frame {d:.1} us", .{@as(f32, @floatFromInt(total)) / 1000});
        var longest: u64 = 1;
        for (tm.ns) |n| longest = @max(longest, n);
        for (tm.ns, 0..) |n, k| {
            _ = f.open(.none, .{ .dir = .x, .gap = 6, .cross = .center });
            var buf: [32]u8 = undefined;
            const name = @tagName(@as(timing.Pass, @fromBackingInt(@intCast(k))));
            const str = std.fmt.bufPrint(&buf, "{s:<9}{d:>8.1} us", .{ name, @as(f32, @floatFromInt(n)) / 1000 }) catch &buf;
            _ = f.text(str, .{ .px = insp.text_px, .color = insp.dim });
            const frac = @as(f32, @floatFromInt(n)) / @as(f32, @floatFromInt(longest));
            _ = f.leaf(.none, .{ .size = .{ .px(@max(frac * insp.bar_px, 1)), .px(6) }, .fill = insp.theme.accent });
            f.close();
        }
    }

    /// Boxes over the application, under the panel: layout rects, clip rects and the hovered
    /// node, each a floating, bordered leaf at last frame's rect. They take no input.
    fn outlines(insp: *const Inspector, f: *Frame, prev: *const Tree, d: *const DrawList) void {
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
        if (insp.show_overdraw) for (d.quads[0..insp.draw.quads]) |*q| {
            const r = batches.clipped(q);
            box(f, .{ .x0 = r[0], .y0 = r[1], .x1 = r[2], .y1 = r[3] }, .transparent, insp.overdraw_fill);
        };
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
const mem = @import("lcgr").mem;
const Input = @import("lcgr").input.Input;
const Quad = @import("lcgr").draw_list.Quad;
const context = @import("lcgr").context;
const sw = @import("lcgr").render_sw;
const iface = @import("lcgr").shell_iface;
const Headless = @import("lcgr").shell_headless.Headless;
const example = @import("lcgr").shell_example;

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
    var ctx_buffer2: [context.Context.requiredBytes(example_limits)]u8 align(mem.column_align) = undefined;
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
    var shell = Fixture.shell(@embedFile("example.replay"));
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
    var shell = Fixture.shell(@embedFile("example.replay"));
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

test "timing.end: the same frames as Frame.end, with every pass timed" {
    var plain = try context.Context.init(&Fixture.ctx_buffer, example_limits);
    var timed = try context.Context.init(&Fixture.ctx_buffer2, example_limits);
    var app_a: example.App = .{};
    var app_b: example.App = .{};
    var shell = Fixture.shell(@embedFile("example.replay"));
    var ev: iface.Events = .{};
    var tm: timing.Timings = .{};
    while (shell.poll(&ev)) {
        if (!plain.needsFrame(&ev.in)) continue;
        var f = plain.begin(&ev.in);
        app_a.build(&f, &ev);
        const a = f.end(.{});
        var clock: timing.Clock = .start(testing.io);
        var g = timed.begin(&ev.in);
        clock.lap(&tm, .begin);
        app_b.build(&g, &ev);
        clock.lap(&tm, .build);
        const b = timing.end(&g, .{}, &clock, &tm);
        try testing.expect(w.sameDraw(a.draw, b.draw));
        try testing.expectEqual(a.wake, b.wake);
    }
    try testing.expectEqual(@as(u32, 13), app_b.builds);
    try testing.expect(tm.total() > 0);
}

test "inspector runs inside the example with per-pass times shown" {
    var ctx = try context.Context.init(&Fixture.ctx_buffer, example_limits);
    var host: ExampleHost = .{};
    var shell = Fixture.shell(@embedFile("example.replay"));
    var ev: iface.Events = .{};
    var last: ?context.Output = null;
    // `iface.run`'s loop written out, with the clock between the passes.
    while (shell.poll(&ev)) {
        if (ctx.needsFrame(&ev.in)) {
            var tm: timing.Timings = .{};
            var clock: timing.Clock = .start(testing.io);
            var f = ctx.begin(&ev.in);
            clock.lap(&tm, .begin);
            host.build(&f, &ev);
            clock.lap(&tm, .build);
            const out = timing.end(&f, .{}, &clock, &tm);
            host.insp.timings = tm;
            shell.apply(&out.platform);
            shell.present(&out);
            last = out;
        }
    }
    try testing.expectEqual(null, shell.err);
    try testing.expectEqual(@as(u32, 1), host.app.resets);
    try testing.expectEqual(@as(u32, 4), host.app.layers);
    try testing.expectApproxEqAbs(@as(f32, 3), host.app.exposure, 0.01);
    const out = last.?;
    try testing.expect(shows(&out, "frame "));
    inline for (@typeInfo(timing.Pass).@"enum".field_names) |name| try testing.expect(shows(&out, name ++ " "));
    try testing.expect(out.status.ok());
}

test "inspector runs inside the example and logs what reached it" {
    var ctx = try context.Context.init(&Fixture.ctx_buffer, example_limits);
    var host: ExampleHost = .{};
    var shell = Fixture.shell(@embedFile("example.replay"));
    iface.run(&shell, &ctx, &host);
    try testing.expectEqual(@as(u32, 1), host.app.resets);
    try testing.expectEqual(@as(u32, 4), host.app.layers);
    // Frames are numbered as built: the two idle polls built nothing and are not in the log.
    const log = &host.insp.log;
    var all: [EventLog.cap * (EventLog.width + 1)]u8 = undefined;
    var n: usize = 0;
    var k = log.kept();
    while (k > 0) {
        k -= 1;
        const l = log.newest(k);
        @memcpy(all[n..][0..l.len], l);
        all[n + l.len] = '\n';
        n += l.len + 1;
    }
    try testing.expectEqualStrings(
        \\1 viewport 800x600
        \\3 hover #2 button
        \\4 press left at 37,25
        \\5 release left at 37,25
        \\5 click #2 button
        \\6 hover #11 button
        \\7 press left at 54,74
        \\8 release left at 54,74
        \\8 click #11 button
        \\9 hover #7 slider
        \\10 press left at 639,25
        \\11 release left at 639,25
        \\11 click #7 slider
        \\12 hover nothing
        \\
    , all[0..n]);
}

test "inspector runs inside the example and counts its draw batches and overdraw" {
    // The example alone: the draw list the inspector should describe.
    var alone = try context.Context.init(&Fixture.ctx_buffer2, example_limits);
    var app: example.App = .{};
    var shell = Fixture.shell(@embedFile("example.replay"));
    iface.run(&shell, &alone, &app);
    const d = &alone.draw;
    var area: f32 = 0;
    for (d.quads[0..d.quad_len]) |*q| {
        const r = batches.clipped(q);
        area += (r[2] - r[0]) * (r[3] - r[1]);
    }

    var ctx = try context.Context.init(&Fixture.ctx_buffer, example_limits);
    var host: ExampleHost = .{ .insp = .{ .show_overdraw = true } };
    shell = Fixture.shell(@embedFile("example.replay"));
    iface.run(&shell, &ctx, &host);
    try testing.expectEqual(@as(u32, 1), host.app.resets);
    try testing.expectEqual(@as(u32, 4), host.app.layers);
    const s = host.insp.draw;
    // Its share of a frame with the inspector in it is the frame without it.
    try testing.expectEqual(d.quad_len, s.quads);
    try testing.expectEqual(d.cmd_len, s.cmds);
    try testing.expectEqual(d.run_len, s.texts);
    try testing.expectEqual(d.custom_len, s.customs);
    try testing.expectEqual(d.cmd_len - d.run_len - d.custom_len, s.batches);
    try testing.expectApproxEqAbs(area / (800 * 600), s.overdraw, 1e-6);
    try testing.expect(s.overdraw > 0.2);
    // The overdraw tint is over the sidebar's panel.
    const tinted = shell.fb.at(80, 590);
    try testing.expect(tinted.r > host.app.theme.panel.r);
    try testing.expectEqual(@as(f32, 1), ctx.trees[ctx.cur].c.value[ctx.trees[ctx.cur].find(id_overdraw)]);
}

/// The example with a reused subtree, as the prototype's example reuses its sidebar: a badge
/// showing the layer count, rebuilt only when the `layers` signal moves.
const ReuseHost = struct {
    app: example.App = .{},
    insp: Inspector = .{},
    layers: ?@import("lcgr").runtime_signals.Signal = null,
    shown: u32 = 0,
    /// This frame's decision for the badge, kept before the inspector clears its log.
    decided: changes.Decision = .other,

    pub fn build(h: *ReuseHost, f: *Frame, ev: *const iface.Events) void {
        h.app.build(f, ev);
        const sig = h.layers orelse f.ctx.signals.create();
        h.layers = sig;
        f.ctx.signals.bump(sig, h.app.layers != h.shown);
        h.shown = h.app.layers;
        const id = Id.from("badge");
        if (!h.insp.reuses.reuse(f, id, &.{sig})) {
            _ = f.open(id, .{ .float = true, .offset = .{ 170, 60 }, .pad = @splat(4), .fill = .rgb(60, 60, 60) });
            var buf: [16]u8 = undefined;
            _ = f.text(std.fmt.bufPrint(&buf, "{d} layers", .{h.app.layers}) catch "?", .{});
            f.close();
        }
        h.decided = h.insp.reuses.decision[h.insp.reuses.len - 1];
        h.insp.build(f);
    }
};

test "inspector runs inside the example and shows signal changes and reuse decisions" {
    var ctx = try context.Context.init(&Fixture.ctx_buffer, example_limits);
    var host: ReuseHost = .{};
    var shell = Fixture.shell(@embedFile("example.replay"));
    var ev: iface.Events = .{};
    var seen: [16][2]u32 = undefined;
    var decided: [16]changes.Decision = undefined;
    var n: usize = 0;
    var last: ?context.Output = null;
    while (shell.poll(&ev)) {
        if (!ctx.needsFrame(&ev.in)) continue;
        var f = ctx.begin(&ev.in);
        host.build(&f, &ev);
        const out = f.end(.{});
        seen[n] = .{ host.insp.signals.changed_len, host.app.layers };
        decided[n] = host.decided;
        try testing.expect(shows(&out, @tagName(host.decided)));
        n += 1;
        last = out;
    }
    try testing.expectEqual(@as(u32, 4), host.app.layers);
    try testing.expectEqual(@as(usize, 13), n);
    // Frame 1 builds the badge new. Clicking Add layer (frames 7-8) moves the signal once, and
    // that frame rebuilds it for the signal; frames with the pointer elsewhere copy it.
    try testing.expectEqual(changes.Decision.new, decided[0]);
    try testing.expectEqual(changes.Decision.reused, decided[1]);
    var signal_frames: u32 = 0;
    for (seen[0..n], decided[0..n], 0..) |s, d, k| {
        if (k > 0 and s[0] > 0) {
            signal_frames += 1;
            try testing.expectEqual(changes.Decision.signals, d);
            try testing.expectEqual(@as(u32, 4), s[1]);
        }
    }
    try testing.expectEqual(@as(u32, 1), signal_frames);
    try testing.expect(shows(&last.?, "4 layers"));
}

test "inspector runs inside the example, records the session, and the recording replays it" {
    const Run = struct {
        host: ExampleHost = .{},
        polls: u32 = 0,
        fb_hash: u64 = 0,

        fn go(run: *@This(), recording: []const u8, into: []u8) !void {
            var ctx = try context.Context.init(&Fixture.ctx_buffer, example_limits);
            run.host.insp.recorder = .init(into);
            run.host.insp.recording = true;
            var shell = Fixture.shell(recording);
            iface.run(&shell, &ctx, &run.host);
            try testing.expectEqual(null, shell.err);
            run.polls = shell.polls;
            run.fb_hash = std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(shell.fb.pixels));
        }
    };
    var first_text: [4096]u8 = undefined;
    var second_text: [4096]u8 = undefined;
    var first: Run = .{};
    try first.go(@embedFile("example.replay"), &first_text);
    const recorded = first.host.insp.recorder.?;
    try testing.expect(!recorded.full);
    // Built frames are recorded; the two idle polls built nothing.
    try testing.expectEqual(@as(u32, 13), recorded.frames);

    var second: Run = .{};
    try second.go(recorded.text(), &second_text);
    // The replay rebuilds every recorded frame and ends where the session ended.
    try testing.expectEqual(@as(u32, 13), second.polls);
    try testing.expectEqual(@as(u32, 13), second.host.app.builds);
    try testing.expectEqual(first.host.app.resets, second.host.app.resets);
    try testing.expectEqual(first.host.app.layers, second.host.app.layers);
    try testing.expectEqual(first.host.app.exposure, second.host.app.exposure);
    try testing.expectEqual(first.host.insp.log.count, second.host.insp.log.count);
    // Recording the replay gives the same recording, and the same picture.
    try testing.expectEqualStrings(recorded.text(), second.host.insp.recorder.?.text());
    try testing.expectEqual(first.fb_hash, second.fb_hash);
}
