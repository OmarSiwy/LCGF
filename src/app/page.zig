//! A page the application composes: a frame of lcgf_app's context built inside a region of a
//! page the application lays out itself (a `ComptimeUi`), the two lists joined by
//! `ct_interop.compose` (docs/plans/window.md, "What an application writes"). In: the App's
//! `page`, `build` and `compose`, and the window's events. Out: the list the window draws, the
//! rows its text runs were measured in, and where the frame's (0, 0) is in the window. Both
//! the software loop (app.zig) and the GPU loop (gpu.zig) take a frame through here.
//!
//! Contents
//!   pub const PageText = ?Shaped
//!   pub const Composed = struct
//!   pub const Paging = struct
//!     pub fn wants(p: *Paging, ctx: *Context, in: *const Input) bool
//!   pub const Built = struct
//!   pub fn composes(comptime App: type) bool
//!   pub fn shaped(tw: anytype) PageText
//!   pub fn build(comptime App: type, app: *App, p: *Paging, ctx, tw, ev) Built

const std = @import("std");
const lcgf = @import("lcgf");
const text = @import("text.zig");
const context = lcgf.context;
const Input = lcgf.input.Input;
const Events = lcgf.shell_iface.Events;
const DrawList = lcgf.draw_list.DrawList;

/// What `App.page` lays its page out with: the text service's stack and baseline rows when it
/// draws the window's text (`ComptimeUi.frameText`), null when the bundled bitmap font does
/// (`ComptimeUi.frame`, which measures with the same `Mono`). The page's runs must then be at
/// most `Options.limits.texts`.
pub const PageText = ?lcgf.widgets_base.Shaped;

/// The list a frame is drawn as, as the application composed it (`App.compose`): the page's
/// list with the frame's in its region (`ct_interop.compose`, which joins their damage).
/// `draw` is the application's, alive until the next frame; the window culls it to its damage.
/// `texts` names, side by side, the rows each run was measured in (`text.Side`): the page's
/// `ui.tables.tx` from run 0, the frame's `out.texts` from the page's `run_len`. The window's
/// text service places every run's glyphs from them, at the run's place in `draw`.
pub const Composed = struct {
    draw: *DrawList,
    texts: []const text.Side,
};

/// What a composing window keeps between frames: the region the frame was built in, and the
/// window's input when it was.
pub const Paging = struct {
    rect: [4]f32 = .{ 0, 0, 0, 0 },
    stamp: u64 = 0,
    built: bool = false,

    /// Whether a frame is due: the context's own reasons in its region (timers, motion, its
    /// widgets), or any change of the window's input, which the page may answer to. An idle
    /// window builds nothing.
    pub fn wants(p: *const Paging, ctx: *context.Context, in: *const Input) bool {
        const region = lcgf.ct_interop.regionInput(in, p.rect);
        std.debug.assert(region.scale == in.scale);
        return !p.built or ctx.needsFrame(&region) or in.stamp() != p.stamp;
    }
};

/// One frame through the application's page.
pub const Built = struct {
    /// The frame `build` made, in its region's coordinates.
    out: context.Output,
    composed: Composed,
    /// The region's corner in the window: where the frame's (0, 0) is drawn.
    origin: [2]f32,
};

/// Whether `App` composes its frames into a page of its own. Both hooks or neither.
pub fn composes(comptime App: type) bool {
    const page = @hasDecl(App, "page");
    if (page != @hasDecl(App, "compose")) @compileError(@typeName(App) ++
        " composes a page with both `pub fn page(*App, *const Input, lcgf_app.PageText) [4]f32`" ++
        " and `pub fn compose(*App, *const lcgf.context.Output) lcgf_app.Composed`");
    return page;
}

/// The stack `App.page` lays its text out with (`PageText`): `tw` is a `text.Window`, or a
/// `text.Bitmap`, which has none.
pub fn shaped(tw: anytype) PageText {
    if (@TypeOf(tw.*) == text.Bitmap or !tw.on()) return null;
    const t = &tw.text.?;
    return .{ .stack = &t.stack, .ascent = t.ascent };
}

/// The application's page laid out over the window's input, the frame begun in the region it
/// gives (`ct_interop.regionInput`: the region's size as viewport, the pointer moved by its
/// corner), built, its text ended by `tw`, then composed by the application.
// tidy: allow(too-many-parameters) the loop's own state, passed through from either loop
pub fn build(
    comptime App: type,
    app: *App,
    p: *Paging,
    ctx: *context.Context,
    tw: anytype,
    ev: *const Events,
) Built {
    const rect = app.page(&ev.in, shaped(tw));
    std.debug.assert(rect[0] <= rect[2]);
    var region = ev.*;
    region.in = lcgf.ct_interop.regionInput(&ev.in, rect);
    var f = ctx.begin(&region.in);
    app.build(&f, &region);
    const out = tw.end(&f);
    p.* = .{ .rect = rect, .stamp = ev.in.stamp(), .built = true };
    const composed = app.compose(&out);
    std.debug.assert(composed.texts.len > 0);
    return .{ .out = out, .composed = composed, .origin = .{ rect[0], rect[1] } };
}

// ---- tests -------------------------------------------------------------------------------------

const Color = lcgf.types.Color;
const Id = lcgf.types.Id;
const Damage = lcgf.damage.Damage;
const CanvasDraw = lcgf.draw_list.CanvasDraw;
const mem = lcgf.mem;
const testing = std.testing;

/// Schemify's window in small, for the tests of both loops: a compiled header (a checkbox and
/// an alpha-only icon tinted by its node's fill) over a region whose frame holds a line of
/// text and a canvas, composed every frame.
pub const TestApp = struct {
    const w = lcgf.widgets_base;
    const th: w.Theme = .default;
    pub const page_fill = Color.rgb(40, 40, 50);
    pub const region_fill = Color.rgb(20, 30, 20);
    pub const canvas_fill = Color.rgb(10, 20, 30);
    pub const red = Color.rgb(220, 0, 0);
    pub const tint = Color.rgb(0, 160, 255);
    /// Where the icon is in the window.
    pub const icon_at = [2]f32{ 250, 8 };
    const Header = struct { grid: bool = true, grid_text: []const u8 = "Grid" };
    const icon_style: lcgf.types.Style = .{
        .float = true,
        .offset = icon_at,
        .size = .{ .px(16), .px(16) },
        .fill = tint,
        .texture = @fromBackingInt(1),
    };
    const spec = lcgf.spec.col(.{ .size = .{ .fill, .fill } }, .{
        lcgf.spec.row(.{ .size = .{ .fill, .px(36) }, .pad = @splat(6), .fill = page_fill }, .{
            w.ct.checkbox(th, .grid_box, .grid, .grid_text),
            lcgf.spec.row(icon_style, .{}),
        }),
        lcgf.ct_interop.region(.view, .{ .size = .{ .fill, .fill } }),
    });
    pub const Ui = w.ComptimeUi(Header, spec, th);
    const view_id = Id.from("view");
    const dm_bytes = blk: {
        var counter: mem.Carver = .{ .buf = null };
        _ = Damage.init(&counter, Ui.nodes);
        break :blk counter.off;
    };
    const list_bytes = blk: {
        var counter: mem.Carver = .{ .buf = null };
        _ = DrawList.init(&counter, 64, 16, 8);
        break :blk counter.off;
    };
    const shapes_bytes = lcgf.canvas.Instances.requiredBytes(32, 0, 1, .{});
    const AppImage = @import("app.zig").Image;
    var dm_buf: [dm_bytes]u8 align(mem.column_align) = undefined;
    var list_buf: [list_bytes]u8 align(mem.column_align) = undefined;
    var shapes_buf: [shapes_bytes]u8 align(mem.column_align) = undefined;

    ui: Ui = .{},
    dm: Damage = undefined,
    list: DrawList = undefined,
    strings: [1024]u8 = undefined,
    canvases: [8]CanvasDraw = undefined,
    top: *const DrawList = undefined,
    texts: [2]text.Side = undefined,
    rows: [2 * 64]CanvasDraw = undefined,
    shapes: lcgf.canvas.Instances = undefined,
    layers: [1]lcgf.canvas.Layer = .{.of(.{ .stroke = red, .fill = red })},
    palette: lcgf.canvas.Palette = undefined,
    ranges: [1]lcgf.canvas.Range = undefined,
    camera: lcgf.canvas.Camera = .{ .offset = .{ 10, 10 } },
    icon: [16 * 16]u8 = @splat(255),
    image: [1]AppImage = undefined,
    /// The canvas node's rect in the window, as the last frame laid it out.
    canvas_rect: [4]f32 = .{ 0, 0, 0, 0 },
    /// Canvas labels, when the test gives them (`lcgf_app.Labels`): a label in the canvas
    /// beside its square, made once.
    labels: text.labels.Handle = .{},
    labelled: bool = false,
    builds: u32 = 0,
    ready: bool = false,

    pub fn page(a: *TestApp, in: *const Input, t: PageText) [4]f32 {
        if (!a.ready) a.init();
        const top = if (t) |s| a.ui.frameText(in, s) else a.ui.frame(in);
        a.ui.recordDamage(&a.dm);
        a.top = top.draw;
        const r = top.tree.rect(top.tree.find(view_id));
        return .{ r.x0, r.y0, r.x1, r.y1 };
    }

    pub fn build(a: *TestApp, f: *lcgf.frame.Frame, _: *const Events) void {
        std.debug.assert(a.ready);
        a.builds += 1;
        f.ctx.enableCanvas(&a.rows);
        if (a.labels.available() and !a.labelled) {
            const o: text.labels.Label = .{ .origin = .{ 20, 30 }, .px = 15 };
            _ = a.labels.label(&a.shapes, "R1 10k", o) catch
                @panic("TestApp: no room for the label");
            a.ranges = .{a.shapes.since(0)};
            a.labelled = true;
        }
        const root: lcgf.types.Style = .{
            .dir = .y,
            .size = .{ .fill, .fill },
            .pad = @splat(6),
            .gap = 6,
            .fill = region_fill,
        };
        _ = f.open(.none, root);
        _ = f.textStyled("Wave office", .{ .px = 15, .color = .white }, .{});
        const plot: lcgf.types.Style = .{ .size = .{ .px(200), .px(60) }, .fill = canvas_fill };
        _ = f.canvas(.from("plot"), plot, &a.shapes, .{
            .camera = a.camera,
            .palette = &a.palette,
            .ranges = &a.ranges,
        });
        f.close();
    }

    pub fn compose(a: *TestApp, out: *const context.Output) Composed {
        const region = @backingInt(view_id);
        lcgf.ct_interop.compose(&a.list, a.top, out.draw, region, &a.strings) catch
            @panic("TestApp: the page lost its region, or the list is too small");
        a.texts = .{
            .{ .tx = &a.ui.tables.tx, .strings = a.top.strings },
            .{ .tx = out.texts, .strings = out.draw.strings, .first_run = a.top.run_len },
        };
        const r = out.tree.rect(out.tree.find(.from("plot")));
        const o = a.ui.tables.t.rect(a.ui.tables.t.find(view_id));
        a.canvas_rect = .{ r.x0 + o.x0, r.y0 + o.y0, r.x1 + o.x0, r.y1 + o.y0 };
        return .{ .draw = &a.list, .texts = &a.texts };
    }

    pub fn images(a: *TestApp) []const AppImage {
        a.image = .{.{ .alpha = &a.icon, .size = .{ 16, 16 } }};
        return &a.image;
    }

    /// The checkbox's rect in the window, as the last frame laid it out.
    pub fn widgetRect(a: *const TestApp) [4]f32 {
        const k = comptime Ui.Events.slot(.grid_box);
        const r = a.ui.rects.c;
        return .{ r[0][k], r[1][k], r[2][k], r[3][k] };
    }

    fn init(a: *TestApp) void {
        var dm_carver: mem.Carver = .{ .buf = &dm_buf };
        a.dm = .init(&dm_carver, Ui.nodes);
        var list_carver: mem.Carver = .{ .buf = &list_buf };
        a.list = .init(&list_carver, 64, 16, 8);
        a.list.canvases = &a.canvases;
        var carver: mem.Carver = .{ .buf = &shapes_buf };
        a.shapes = .init(&carver, 32, 0, 1, .{});
        _ = a.shapes.rect(.{ 0, 0 }, .{ 10, 10 }, .{});
        a.ranges = .{a.shapes.since(0)};
        a.palette = .{ .layers = &a.layers };
        a.ready = true;
    }
};

/// The canvas node of `app`, label and square, as the software back end draws it headless:
/// every pixel of its rect in window `w` within 2 of it, at scale 1.
// tidy: allow-fn(large-generic-function) a test helper over the X11 window, one instance
pub fn expectCanvas(w: anytype, app: *const TestApp) !void {
    const x11 = @import("x11");
    const Buf = struct {
        var px: [lcgf.render_sw.Framebuffer.len(200, 60)]u32 = undefined;
    };
    const r = app.canvas_rect;
    var fb = lcgf.render_sw.Framebuffer.init(&Buf.px, 200, 60, .rgba8);
    const atlas = &app.labels.labels.?.atlas;
    const look: text.labels.CanvasLook = .{
        .ground = TestApp.canvas_fill,
        .palette = &app.palette,
    };
    text.labels.drawCanvas(&fb, &app.shapes, app.camera, atlas, look);
    var bad: u32 = 0;
    var lit: u32 = 0;
    for (0..60) |y| for (0..200) |x| {
        const want = fb.at(@intCast(x), @intCast(y));
        const fx: f32 = @floatFromInt(x);
        const fy: f32 = @floatFromInt(y);
        const got = try x11.pixel(w, @intFromFloat(r[0] + fx), @intFromFloat(r[1] + fy));
        lit += @intFromBool(want.r > 128);
        const off = @abs(@as(i32, got.r) - want.r) > 2 or @abs(@as(i32, got.g) - want.g) > 2;
        bad += @intFromBool(off);
    };
    errdefer std.debug.print("page canvas: {d} bad pixels, {d} lit\n", .{ bad, lit });
    try testing.expectEqual(0, bad);
    // The square's 100 pixels and the label's.
    try testing.expect(lit > 150);
}

/// Pixel `dx`, `dy` from `box`'s corner of window `w`.
pub fn pixelIn(w: anytype, box: [4]f32, dx: f32, dy: f32) !Color {
    const x11 = @import("x11");
    return x11.pixel(w, @intFromFloat(box[0] + dx), @intFromFloat(box[1] + dy));
}

/// Every run of the composed list `app` last drew, rasterised straight from the face
/// (text.zig's golden reference) over its side's ground: each pixel of the run's rect within
/// 2 of it in the window, at scale 1.
// tidy: allow-fn(large-generic-function) a test helper over the X11 window, one instance
pub fn expectPageText(w: anytype, app: *const TestApp, t: *text.Text) !void {
    const x11 = @import("x11");
    const Img = struct {
        var img: [300 * 200]u8 = undefined;
    };
    const pw: u32 = w.width;
    const d = &app.list;
    const img = Img.img[0 .. @as(usize, pw) * w.height];
    @memset(img, 0);
    _ = try text.drawReferenceOf(t, d, &app.texts, 1, img, pw);
    var bad: u32 = 0;
    var ink: u32 = 0;
    for (d.runs[0..d.run_len], 0..) |r, k| {
        const ground = if (k < app.top.run_len) TestApp.page_fill else TestApp.region_fill;
        const color: Color = @bitCast(r.color);
        const box: [4]u32 = .{
            @intFromFloat(@max(r.rect[0], r.clip[0])),
            @intFromFloat(@max(r.rect[1], r.clip[1])),
            @intFromFloat(@min(r.rect[2], r.clip[2])),
            @intFromFloat(@min(r.rect[3], r.clip[3])),
        };
        for (box[1]..box[3]) |y| for (box[0]..box[2]) |x| {
            const cov: i32 = img[y * pw + x];
            const g: i32 = ground.r;
            const want = g + @divTrunc(cov * (@as(i32, color.r) - g) + 127, 255);
            const got = try x11.pixel(w, @intCast(x), @intCast(y));
            ink += @intFromBool(cov > 0);
            bad += @intFromBool(@abs(@as(i32, got.r) - want) > 2);
        };
    }
    errdefer std.debug.print("{d} bad pixels of {d} inked\n", .{ bad, ink });
    try testing.expectEqual(0, bad);
    try testing.expect(ink > 100);
}
