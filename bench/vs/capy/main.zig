//! The six harness.h scenes through Capy (https://github.com/capy-ui/capy), built with the Zig
//! Capy pins (0.14.1) against its GTK 4 backend, so it runs on the same toolkit as
//! bench/vs/gtk4: Capy's containers lay their children out in Zig and place them in a GtkFixed,
//! and GTK measures, styles and snapshots them. A poll is what bench/vs/gtk4 does, plus the
//! scene's change made through Capy's API: X11 pointer motion, the GLib context pumped through
//! `capy.stepEventLoop`, the root allocated at the viewport and snapshotted. The output count is
//! the number of top-level GSK nodes. Capy lays out only when its root is resized (it listens to
//! the GDK surface, not to GTK's allocation), so a new viewport is handed to the root as the
//! surface handler hands it.
//!
//! What Capy cannot say the same way, and how the harness says it instead:
//! - list: Capy's `List` makes a widget per item, with no recycling, so 100,000 rows would be
//!   300,000 GTK widgets. The harness keeps one screen of rows (34) and rewrites their labels
//!   from the scroll offset, as an application would; it scrolls by whole rows.
//! - text and resize: Capy's labels do not wrap, so each paragraph is one line, and a
//!   `scrollable` around this row snapshots to nothing in Capy 0.4.1 (GTK returns no node), so
//!   the row is not scrolled: what passes the window is cut off.
//! - springs: Capy has no spring; `vs_springs_step` steps them and each bar is a `capy.rect`
//!   whose preferred size is set, then the root container lays out again.
//!
//! Build: bench/vs/capy/build.sh (CAPY_SRC = a Capy checkout). Speaks the protocol of
//! bench/vs/harness.h.
const std = @import("std");
const capy = @import("capy");
pub usingnamespace capy.cross_platform;

/// The GTK, GLib and libc calls the harness makes beside Capy's API, declared here: Capy's module
/// has GTK's include paths, an example's root module does not.
const c = struct {
    const Widget = opaque {};
    const Node = opaque {};
    const Snapshot = opaque {};
    const Opaque = opaque {};
    const Window = c_ulong;
    const orientation_horizontal: c_int = 0;
    const orientation_vertical: c_int = 1;
    const container_node: c_int = 1;
    const io_in: c_uint = 1;
    const io_err: c_uint = 8;
    const io_hup: c_uint = 16;
    extern fn g_main_context_pending(?*Opaque) c_int;
    extern fn g_main_context_iteration(?*Opaque, c_int) c_int;
    extern fn g_unix_fd_add(c_int, c_uint, *const fn (c_int, c_uint, ?*anyopaque) callconv(.C) c_int, ?*anyopaque) c_uint;
    extern fn gtk_window_set_decorated(*Widget, c_int) void;
    extern fn gtk_window_get_child(*Widget) *Widget;
    extern fn gtk_widget_get_mapped(*Widget) c_int;
    extern fn gtk_widget_measure(*Widget, c_int, c_int, ?*c_int, ?*c_int, ?*c_int, ?*c_int) void;
    extern fn gtk_widget_allocate(*Widget, c_int, c_int, c_int, ?*Opaque) void;
    extern fn gtk_widget_snapshot_child(*Widget, *Widget, *Snapshot) void;
    extern fn gtk_snapshot_new() *Snapshot;
    extern fn gtk_snapshot_free_to_node(*Snapshot) ?*Node;
    extern fn gsk_render_node_unref(*Node) void;
    extern fn gsk_render_node_get_node_type(*Node) c_int;
    extern fn gsk_container_node_get_n_children(*Node) c_uint;
    extern fn gtk_native_get_surface(*Widget) *Opaque;
    extern fn gdk_surface_get_display(*Opaque) *Opaque;
    extern fn gdk_x11_display_get_xdisplay(*Opaque) *Opaque;
    extern fn gdk_x11_surface_get_xid(*Opaque) Window;
    extern fn dlsym(?*anyopaque, [*:0]const u8) ?*anyopaque;
    extern fn setenv([*:0]const u8, [*:0]const u8, c_int) c_int;
};

const frames = 3000;
const Scene = enum { form, list, text, springs, resize, idle };

const form_names = [_][:0]const u8{
    "Name", "Email", "Phone", "Street", "City", "Postcode", "Country", "Company", "Title", "Team", "Manager",
    "Website", "Timezone", "Language", "Currency", "Theme", "Font", "Density", "Backup", "Sync", "Alerts",
};
const list_names = [_][]const u8{ "alpha", "bravo", "charlie", "delta", "echo", "foxtrot", "golf" };
const prose = [_][]const u8{
    "Columns of rows replace trees of objects: every pass walks a few dense arrays from start to end, so the cache sees one stream per field and the vector units take eight rows at a time.",
    "A frame is rebuilt from scratch, laid out in a handful of passes and painted into a draw list that a renderer submits as it is. Nothing outlives the frame except what the caller keeps.",
    "Text is measured once per run and wrapped against the width the layout grants; lines break at spaces, and a word wider than the line is broken where it overflows.",
    "Idle costs nothing: when no input arrives and no spring moves, no frame is built, so the process sleeps until the next event and the battery is left alone.",
};

const Input = struct { w: f32 = 800, h: f32 = 600, px: f32 = 0, py: f32 = 0, dt: f32 = 1.0 / 60.0, scroll: u32 = 0, tick: u32 };

/// harness.h `vs_input`.
fn inputOf(scene: Scene, k: u32) Input {
    var in: Input = .{ .tick = k };
    switch (scene) {
        .form => {
            in.px = @floatFromInt(20 + (k * 7) % 760);
            in.py = @floatFromInt(20 + (k * 13) % 560);
        },
        .list => {
            in.w = 1280;
            in.h = 800;
            in.px = 640;
            in.py = @floatFromInt(10 + (k * 13) % 780);
            in.scroll = (k * 997) % (100000 * 24 - 800);
        },
        .text => {
            in.w = 1280;
            in.h = 800;
            in.px = @floatFromInt(20 + (k * 7) % 1240);
            in.py = @floatFromInt(20 + (k * 13) % 760);
        },
        .springs => {
            in.w = 1280;
            in.h = 800;
        },
        .resize => {
            in.w = @floatFromInt(320 + (k * 37) % 1600);
            in.h = @floatFromInt(240 + (k * 53) % 1000);
            in.px = 100;
            in.py = 100;
        },
        .idle => {
            in.px = 400;
            in.py = 300;
        },
    }
    return in;
}

/// harness.h `vs_springs_step`.
const Springs = struct {
    x: [1000]f32 = undefined,
    v: [1000]f32 = undefined,
    started: bool = false,

    fn step(s: *Springs, tick: u32, dt: f32) void {
        const h = @min(dt, 1.0 / 30.0);
        for (0..1000) |i| {
            const t: f32 = if ((tick / 30 + i) % 2 != 0) 40 else 4;
            if (!s.started) {
                s.x[i] = t;
                s.v[i] = 0;
            }
            const acc = 170 * (t - s.x[i]) - 26 * s.v[i];
            s.v[i] += acc * h;
            s.x[i] += s.v[i] * h;
        }
        s.started = true;
    }
};

const accent: capy.Color = .{ .red = 0x5a, .green = 0x8c, .blue = 0xff };
const row_height = 24;
const list_rows = 34;

var window: capy.Window = undefined;
var root: *capy.Container = undefined;
var springs: Springs = .{};
var bars: [1000]*capy.Rect = undefined;
var row_names: [list_rows]*capy.Label = undefined;
var row_kinds: [list_rows]*capy.Label = undefined;
var row_text: [list_rows][24]u8 = undefined;
var first_row: u32 = std.math.maxInt(u32);
var xdisplay: ?*c.Opaque = null;
var xwindow: c.Window = 0;
var warp: *const fn (?*c.Opaque, c.Window, c.Window, c_int, c_int, c_uint, c_uint, c_int, c_int) callconv(.C) c_int = undefined;
var sync: *const fn (?*c.Opaque, c_int) callconv(.C) c_int = undefined;

fn form() !*capy.Container {
    var col = try capy.column(.{ .spacing = 4 }, .{
        capy.label(.{ .text = "Account settings" }),
    });
    for (form_names) |name| {
        try col.add(try capy.row(.{ .spacing = 6 }, .{
            capy.label(.{ .text = name }),
            capy.expanded(capy.textField(.{ .text = name })),
            capy.checkBox(.{ .label = "On" }),
            capy.expanded(capy.slider(.{ .min = 0, .max = 1, .step = 0.01, .value = 0.5 })),
        }));
    }
    try col.add(try capy.alignment(.{ .x = 1 }, capy.row(.{ .spacing = 6 }, .{
        capy.button(.{ .label = "Cancel" }),
        capy.button(.{ .label = "Reset" }),
        capy.button(.{ .label = "Save" }),
    })));
    return capy.margin(capy.Rectangle.init(12, 12, 12, 12), capy.scrollable(col));
}

fn list() !*capy.Container {
    var col = try capy.column(.{ .spacing = 0 }, .{});
    for (0..list_rows) |i| {
        row_names[i] = capy.label(.{ .text = "" });
        row_kinds[i] = capy.label(.{ .text = "" });
        try col.add(try capy.row(.{ .spacing = 6 }, .{
            row_names[i],
            row_kinds[i],
            capy.rect(.{ .preferredSize = capy.Size.init(12, 12), .color = accent }),
        }));
    }
    return col;
}

fn showRows(scroll: u32) void {
    const first = scroll / row_height;
    if (first == first_row) return;
    first_row = first;
    for (0..list_rows) |i| {
        const index = first + @as(u32, @intCast(i));
        row_names[i].setText(std.fmt.bufPrint(&row_text[i], "Row {d}", .{index}) catch unreachable);
        row_kinds[i].setText(list_names[index % 7]);
    }
}

fn text() !*capy.Container {
    var chapters = try capy.column(.{ .spacing = 2 }, .{});
    // A label keeps the slice it is given, so its text must outlive it.
    for (1..121) |i| try chapters.add(capy.label(.{ .text = try std.fmt.allocPrint(capy.internal.allocator, "Chapter {d}", .{i}) }));
    var body = try capy.column(.{ .spacing = 8 }, .{});
    for (0..12) |s| {
        try body.add(capy.label(.{ .text = try std.fmt.allocPrint(capy.internal.allocator, "Section {d}", .{s + 1}) }));
        for (0..4) |p| try body.add(capy.label(.{ .text = prose[(s + p) % 4] }));
    }
    return capy.margin(capy.Rectangle.init(12, 12, 12, 12), capy.row(.{ .spacing = 16 }, .{ chapters, capy.expanded(body) }));
}

fn springGrid() !*capy.Container {
    var grid = try capy.column(.{ .spacing = 2 }, .{});
    for (0..40) |y| {
        var r = try capy.row(.{ .spacing = 2 }, .{});
        for (0..25) |x| {
            const bar = capy.rect(.{ .preferredSize = capy.Size.init(4, 16), .color = accent });
            bars[y * 25 + x] = bar;
            try r.add(bar);
        }
        try grid.add(r);
    }
    return capy.margin(capy.Rectangle.init(8, 8, 8, 8), grid);
}

fn pump() void {
    while (c.g_main_context_pending(null) != 0) _ = capy.stepEventLoop(.Asynchronous);
}

fn start(scene: Scene, in: Input) !void {
    try capy.init();
    window = try capy.Window.init();
    root = switch (scene) {
        .list => try list(),
        .springs => try springGrid(),
        .text, .resize => try text(),
        .form, .idle => try form(),
    };
    try window.set(root);
    window.setPreferredSize(@intFromFloat(in.w), @intFromFloat(in.h));
    window.show();
    const gwin: *c.Widget = @ptrCast(window.peer.peer);
    c.gtk_window_set_decorated(gwin, 0);
    while (c.gtk_widget_get_mapped(gwin) == 0) _ = c.g_main_context_iteration(null, 1);
    pump();
    const surface = c.gtk_native_get_surface(gwin);
    xdisplay = c.gdk_x11_display_get_xdisplay(c.gdk_surface_get_display(surface));
    xwindow = c.gdk_x11_surface_get_xid(surface);
    // libX11 is loaded by GTK; it is not linked here.
    warp = @ptrCast(c.dlsym(null, "XWarpPointer") orelse return error.NoX11);
    sync = @ptrCast(c.dlsym(null, "XSync") orelse return error.NoX11);
}

var previous: [2]f32 = .{ -1, -1 };
var size: [2]f32 = .{ 0, 0 };

fn frame(scene: Scene, k: u32) !u64 {
    const in = inputOf(scene, k);
    if (k == 0) try start(scene, in);
    if (scene == .idle and k != 0) {
        pump();
        return 0;
    }
    if (k == 0 or in.px != previous[0] or in.py != previous[1]) {
        _ = warp(xdisplay, 0, xwindow, 0, 0, 0, 0, @intFromFloat(in.px), @intFromFloat(in.py));
        _ = sync(xdisplay, 0);
        previous = .{ in.px, in.py };
    }
    pump();
    switch (scene) {
        .list => showRows(in.scroll),
        .springs => {
            springs.step(in.tick, in.dt);
            for (bars, springs.x) |bar, x| bar.preferredSize.set(capy.Size.init(@round(x), 16));
            root.relayout();
        },
        else => {},
    }
    // A new viewport reaches Capy as a surface resize does (its GTK backend's `gtkLayout`): the
    // root container's resize handler lays the tree out in Zig and sizes each GTK child.
    if (in.w != size[0] or in.h != size[1]) {
        size = .{ in.w, in.h };
        const peer = root.peer.?;
        peer.resize(peer.peer, @intFromFloat(in.w), @intFromFloat(in.h));
    }
    // Then GTK measures, allocates and snapshots the window's child, as bench/vs/gtk4 does.
    const gwin: *c.Widget = @ptrCast(window.peer.peer);
    const child = c.gtk_window_get_child(gwin);
    var minimum: c_int = 0;
    c.gtk_widget_measure(child, c.orientation_horizontal, -1, &minimum, null, null, null);
    c.gtk_widget_measure(child, c.orientation_vertical, @intFromFloat(in.w), &minimum, null, null, null);
    c.gtk_widget_allocate(child, @intFromFloat(in.w), @intFromFloat(in.h), -1, null);
    const snapshot = c.gtk_snapshot_new();
    c.gtk_widget_snapshot_child(gwin, child, snapshot);
    const node = c.gtk_snapshot_free_to_node(snapshot) orelse {
        std.debug.print("empty snapshot at poll {d}\n", .{k});
        return error.EmptySnapshot;
    };
    defer c.gsk_render_node_unref(node);
    return if (c.gsk_render_node_get_node_type(node) == c.container_node) c.gsk_container_node_get_n_children(node) else 1;
}

fn stdinReady(fd: c_int, condition: c_uint, _: ?*anyopaque) callconv(.C) c_int {
    var byte: [1]u8 = undefined;
    if (condition & (c.io_hup | c.io_err) != 0 or std.posix.read(@intCast(fd), &byte) catch 0 == 0) {
        window.close();
        return 0;
    }
    return 1;
}

pub fn main() !void {
    _ = c.setenv("GDK_BACKEND", "x11", 1);
    _ = c.setenv("GSK_RENDERER", "cairo", 1);
    _ = c.setenv("GDK_DISABLE", "gl,vulkan", 1);
    var args = std.process.args();
    _ = args.next();
    var scene: Scene = .form;
    var idle = false;
    while (args.next()) |a| {
        if (std.mem.eql(u8, a, "--idle")) {
            idle = true;
            scene = .idle;
        } else if (std.mem.eql(u8, a, "--scene")) {
            const name = args.next() orelse return error.Usage;
            scene = std.meta.stringToEnum(Scene, name) orelse return error.UnknownScene;
        } else return error.Usage;
    }
    const out = std.io.getStdOut().writer();
    const name = "capy-0.4.1";
    if (idle) {
        const n = try frame(.idle, 0);
        try out.print("ready framework={s} out={d}\n", .{ name, n });
        _ = c.g_unix_fd_add(0, c.io_in | c.io_hup | c.io_err, stdinReady, null);
        capy.runEventLoop();
        return;
    }
    var samples: [frames]u64 = undefined;
    var sink: u64 = 0;
    var last: u64 = 0;
    var built: u64 = 0;
    for (0..frames) |k| {
        const t0 = std.time.nanoTimestamp();
        last = try frame(scene, @intCast(k));
        samples[k] = @intCast(std.time.nanoTimestamp() - t0);
        sink += last;
        built += @intFromBool(last != 0);
    }
    std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
    try out.print("framework={s} scene={s} frames={d} polls={d} out={d} sink={d}\n", .{ name, @tagName(scene), built, frames, last, sink });
    try out.print("{s:<10} {s:>9} {s:>9}\n", .{ "pass", "median us", "p99 us" });
    const us = struct {
        fn f(ns: u64) f64 {
            return @as(f64, @floatFromInt(ns)) / 1000.0;
        }
    }.f;
    try out.print("{s:<10} {d:>9.1} {d:>9.1}\n", .{ "frame", us(samples[frames / 2]), us(samples[frames * 99 / 100]) });
}
