//! lcgf_app on the GPU: an X11 window drawn with Vulkan (src/shell/x11/gpu.zig and
//! `vk.setup.Window`), and the application's own GPU drawing in it (`Surface`, `draw`). In:
//! the application's `build`, `draw` and images, and the X window's events. Out: frames
//! presented, each drawing again only what changed (docs/plans/window.md, "The contract"):
//!
//!   - a built frame (a widget changed) uploads its rows and redraws its `DrawList.damage`;
//!   - a dirty surface (`Surface.redraw`, or its size) calls `draw` and redraws the surface's
//!     rectangle from the rows already on the GPU: no build, no upload of rows;
//!   - nothing changed: no frame.
//!
//! FIFO paces the frames in `vk.setup.Window.begin`, so the loop waits on no timer of its own.
//! A frame the presentation engine does not take (a hidden, minimised or blanked window:
//! error.NotShown) is not drawn: the loop then owes the whole window and tries again on the
//! next event or after `retry_seconds`, asleep in between.
//!
//! Texture handles, as `Style.texture` sees them: 0 white, k + 1 image k of `App.images`,
//! then the bundled font, the text service's atlas, the canvas label atlas and the surfaces.
//!
//! Contents
//!   pub const gpu
//!   pub const Surface = struct
//!     pub fn node(s: *Surface, f: *Frame, id: Id, style: Style) Node
//!     pub fn live(s: *const Surface) bool
//!     pub fn redraw(s: *Surface) void
//!   pub const GpuFrame = struct
//!     pub fn encoder(g: *GpuFrame) gpu.Encoder
//!   pub const Stats = struct
//!   pub const Window = struct
//!     pub fn open(gw: *Window, w: *x11.Window, display: []const u8, o: Open) !void
//!     pub fn close(gw: *Window) void
//!   pub fn loop(comptime App: type, app: *App, gw: *Window, run: Run, clock: anytype) !void

const std = @import("std");
const lcgf = @import("lcgf");
const vk = @import("vk");
const x11 = @import("x11");
const x11_gpu = @import("x11_gpu");
const text = @import("text.zig");
const page = @import("page.zig");
const context = lcgf.context;
const scheduler = lcgf.scheduler;
const font = lcgf.render_sw_font;
const Region = lcgf.damage.Region;
const Events = lcgf.shell_iface.Events;
const Glyphs = lcgf.render_iface.Glyphs;
const DrawList = lcgf.draw_list.DrawList;
const Texture = lcgf.types.Texture;
const Quad = lcgf.draw_list.Quad;
const Frame = lcgf.frame.Frame;
const Style = lcgf.types.Style;
const c = vk.c;
const Device = vk.device.Device;
const Image = vk.device.Image;

/// `lcgf_render.gpu` on this build's back end: what `draw` renders a surface with.
pub const gpu = vk.gpu;

/// Surfaces one window shows.
pub const surfaces_max = 16;
/// Images an application may give (app.zig `images_max`).
pub const images_max = 64;
/// Seconds between attempts to draw a window the presentation engine is not showing.
pub const retry_seconds: f32 = 0.5;

const handle_font = images_max + 1;
const handle_text = images_max + 2;
const handle_labels = images_max + 3;
const handle_surface = images_max + 4;
const handles = handle_surface + surfaces_max;
comptime {
    std.debug.assert(handles <= vk.renderer.CanvasRenderer.max_textures);
}

/// A rectangle of the window this program draws itself, through `gpu`: a texture of its own,
/// shown as an ordinary quad at its node's place in paint order (`Style.texture`), so widgets
/// over it cover it and its node's clip, radius and opacity apply. Lives in the application's
/// state, as a `<canvas>` lives in a page:
///
///     const node = s.plot.node(f, .from("plot"), .{ .size = .{ .fill, .fill } });
///     if (f.interact(node, .{ .drag = true }).dragged) s.plot.redraw();
///
/// The texture follows the node's size in physical pixels, growing in steps of `step_px` so a
/// resize does not make one a pixel; `size` is the part in use, its top left.
pub const Surface = struct {
    /// What `draw` renders into: `format`, render attachment, sampled by the UI. Valid in
    /// `draw` once `size` is not zero; a new texture when the node outgrows it.
    texture: gpu.Texture = undefined,
    /// Physical pixels of `texture` the node shows, from the last layout; zero before it.
    size: [2]u32 = .{ 0, 0 },
    /// `draw` must draw it this frame: new, resized, or `redraw` was called before the frame.
    dirty: bool = true,
    /// `redraw` was called: dirty in the next frame (a call in `draw` is for the next one).
    requested: bool = false,
    /// The node's rectangle in logical pixels, from the last layout.
    rect: [4]f32 = .{ 0, 0, 0, 0 },
    /// Where the window keeps it (set by `node`), its node, and what wakes the loop.
    slot: ?u8 = null,
    node_ix: u32 = 0,
    image: ?Image = null,

    pub const format: gpu.TextureFormat = .rgba8_unorm;
    pub const step_px = 256;

    /// The node that shows the surface: `style` with the surface as its texture, its fill white
    /// unless it has one (a fill tints the texture). Registers the surface with the window.
    /// Panics past `surfaces_max` surfaces. Not `live`: `style` as it is, its fill painted.
    pub fn node(s: *Surface, f: *Frame, id: lcgf.types.Id, style: Style) lcgf.types.Node {
        if (!s.live()) return f.leaf(id, style);
        const slot = s.slot orelse registry.add(s);
        registry.built[slot] = true;
        var st = style;
        st.texture = @fromBackingInt(handle_surface + @as(u16, slot));
        if (st.fill.a == 0) st.fill = .white;
        if (s.image != null) st.uv = .{
            0,
            0,
            @as(f32, @floatFromInt(s.size[0])) / @as(f32, @floatFromInt(s.texture.width)),
            @as(f32, @floatFromInt(s.size[1])) / @as(f32, @floatFromInt(s.texture.height)),
        };
        const n = f.leaf(id, st);
        s.node_ix = n.ix();
        return n;
    }

    /// Whether the window draws its surfaces: it is on the GPU. Not in the software window a GPU
    /// build falls back to (`LCGF_RENDER=sw`, no display or no Vulkan device), where `draw` is
    /// never called and the node paints its style's fill: show something else in its place.
    pub fn live(s: *const Surface) bool {
        _ = s;
        return registry.shell != null;
    }

    /// Asks for a frame that calls `draw` and shows the surface's new pixels, with no `build`:
    /// it wakes the window's loop, not the context. On the UI thread (in `build` or `draw`,
    /// or between frames); another thread wakes the shell itself.
    pub fn redraw(s: *Surface) void {
        s.requested = true;
        if (registry.shell) |w| w.wake();
    }
};

/// What the application's `pub fn draw(*App, *GpuFrame) !void` draws with. It is called in a
/// frame in which a surface is dirty (`Surface.dirty`), never because a widget changed.
pub const GpuFrame = struct {
    device: gpu.Device,
    /// Device-local memory for the application's buffers, textures and bind groups
    /// (`Options.gpu_bytes`), kept while the device lives.
    arena: *gpu.Arena,
    /// The device is new (the first `draw`): make the pipelines and resources in `arena`.
    fresh: bool,
    /// The frame's one upload phase (`writeBuffer`, `writeTexture`).
    upload: gpu.Upload,
    finished: ?gpu.Encoder = null,

    /// Ends the upload phase and gives the frame's encoder, for the application's passes. The
    /// loop ends the phase itself when `draw` never calls this.
    pub fn encoder(g: *GpuFrame) gpu.Encoder {
        if (g.finished) |e| return e;
        g.finished = g.upload.finish();
        return g.finished.?;
    }
};

/// What a window did, for tests and measurements.
pub const Stats = struct {
    builds: u32 = 0,
    draws: u32 = 0,
    presents: u32 = 0,
    not_shown: u32 = 0,
    /// Bytes of UI rows (quads and glyph quads) uploaded.
    row_bytes: u64 = 0,
    /// Bytes of the canvas label atlas uploaded.
    label_bytes: u64 = 0,
    /// Bytes of canvas rows, vertices and uniforms uploaded.
    canvas_bytes: u64 = 0,
    /// The damage of the last frame presented, logical pixels.
    damage: Region = .empty,
    /// Frames presented that drew the whole window.
    whole: u32 = 0,
};

/// What `loop` runs with: made once by app.zig's `run`.
pub const Run = struct {
    w: *x11.Window,
    ctx: *context.Context,
    tw: *text.Window,
    /// Rows for the frame's glyph quads in the bundled font.
    quads: []Quad,
    first: []u32,
    count: []u32,
};

/// The program's surfaces by slot, registered by `Surface.node`.
// ponytail: module state, as app.zig's buffers are: one window a program.
const registry = struct {
    var list: [surfaces_max]?*Surface = @splat(null);
    /// The window whose loop `Surface.redraw` wakes.
    var shell: ?*x11.Window = null;
    /// The surface's node was in the last frame built.
    var built: [surfaces_max]bool = @splat(false);

    fn add(s: *Surface) u8 {
        for (&list, 0..) |*l, k| if (l.* == null) {
            l.* = s;
            s.slot = @intCast(k);
            return @intCast(k);
        };
        @panic("lcgf_app: more than surfaces_max surfaces in one window");
    }
};

/// A window's GPU objects: Vulkan over the X window, the application's memory, the textures
/// the UI samples and the frame's state. Filled in place (the renderer points at its device).
// tidy: allow(bool-heavy-struct) one flag per texture the loop keeps, read where it is written
pub const Window = struct {
    x: x11_gpu.Gpu,
    arena: gpu.Arena,
    staging_arena: gpu.Arena,
    /// The application's staging, a frame slot each.
    staging: [2]gpu.Staging,
    /// Mapped buffers the loop's own texture writes go through, a frame slot each: the
    /// images' and the text atlas's apart, as both are copied when the frame runs.
    writes: [2]vk.device.Buffer,
    text_writes: [2]vk.device.Buffer,
    label_writes: [2]vk.device.Buffer,
    images: [images_max]?Image,
    generations: [images_max]u32,
    sizes: [images_max][2]u32,
    image_len: u32,
    images_known: bool,
    font: Image,
    text: ?Image,
    /// The text service's atlas has to be written whole (new, or a frame not shown).
    text_whole: bool,
    /// The canvas label atlas (`text.Window.labels`), and whether it has to be written whole.
    labels: ?Image,
    labels_whole: bool,
    text_dirty: ?text.Frame,
    /// Damage not yet presented, the rows of the last frame built when not yet uploaded.
    owed: Region,
    rows: ?vk.setup.Window.Rows,
    stats: Stats,
    /// The context of the loop running in the window, which a surface's new size rebuilds.
    ctx: ?*context.Context,
    /// Frames to give up on as error.NotShown before acquiring: what a hidden window does, for
    /// a test on a server that shows every window.
    refuse: u32,
    /// A composing application's region and the input its last frame was built from.
    paging: page.Paging,

    pub const Open = struct {
        /// Device-local bytes `draw` places its resources in, and staging bytes per frame.
        gpu_bytes: u64 = 64 << 20,
        staging_bytes: u64 = 8 << 20,
        canvas_rows: u32 = 4096,
        canvas_verts: u32 = 4096,
    };

    /// Vulkan over X window `w` of `display`, every texture handle registered (white until
    /// used) and the bundled font written. Fails as `x11_gpu.Gpu.open` does (no libxcb,
    /// loader or device), leaving nothing open.
    pub fn open(gw: *Window, w: *const x11.Window, display: []const u8, o: Open) !void {
        std.debug.assert(w.width > 0);
        const canvas: vk.Setup.Canvas = .{ .rows = o.canvas_rows, .verts = o.canvas_verts };
        try gw.x.open(display, w.id, w.width, w.height, canvas);
        errdefer gw.x.close();
        const g = &gw.x.setup;
        const d = &g.device;
        const dev: gpu.Device = .wrap(d);
        gw.arena = try .init(dev, .{ .bytes = o.gpu_bytes });
        errdefer gw.arena.deinit();
        const staging_bytes = 2 * o.staging_bytes + (1 << 16);
        gw.staging_arena = try .init(dev, .{ .bytes = staging_bytes, .memory = .host });
        errdefer gw.staging_arena.deinit();
        for (&gw.staging) |*s| s.* = try .init(dev, &gw.staging_arena, o.staging_bytes);
        while (g.gfx.texture_count < handles) _ = try g.gfx.addTexture(d, g.white.view, g.sampler);
        gw.font = try coverage(d, font.width, font.height);
        errdefer d.destroyImage(&gw.font);
        try writeOnce(g, &gw.font, font.image.alpha8);
        g.gfx.setTexture(d, @fromBackingInt(handle_font), gw.font.view, g.sampler);
        gw.writes = .{ .{ .size = 0 }, .{ .size = 0 } };
        gw.text_writes = gw.writes;
        gw.label_writes = gw.writes;
        gw.images = @splat(null);
        gw.generations = @splat(0);
        gw.sizes = @splat(.{ 0, 0 });
        gw.image_len = 0;
        gw.images_known = false;
        gw.text = null;
        gw.text_whole = true;
        gw.labels = null;
        gw.labels_whole = true;
        gw.text_dirty = null;
        gw.owed = .everything;
        gw.rows = null;
        gw.stats = .{};
        gw.ctx = null;
        gw.refuse = 0;
        gw.paging = .{};
    }

    /// Waits for the device, then lets go of everything `open` and the frames made, the
    /// surfaces' textures too (a surface shown again later gets a new one).
    pub fn close(gw: *Window) void {
        const g = &gw.x.setup;
        std.debug.assert(g.gfx.texture_count >= handles);
        const d = &g.device;
        _ = d.fns.vkDeviceWaitIdle.?(d.handle);
        for (&registry.list) |*l| if (l.*) |s| {
            if (s.image) |*img| d.destroyImage(img);
            s.* = .{};
            l.* = null;
        };
        registry.built = @splat(false);
        registry.shell = null;
        for (&gw.images) |*img| if (img.*) |*i| d.destroyImage(i);
        if (gw.text) |*t| d.destroyImage(t);
        if (gw.labels) |*t| d.destroyImage(t);
        for (&gw.label_writes) |*b| if (b.handle != null) d.destroyBuffer(b);
        d.destroyImage(&gw.font);
        for (&gw.writes) |*b| if (b.handle != null) d.destroyBuffer(b);
        for (&gw.text_writes) |*b| if (b.handle != null) d.destroyBuffer(b);
        for (gw.staging) |s| s.deinit(.wrap(d));
        gw.staging_arena.deinit();
        gw.arena.deinit();
        gw.x.close();
    }

    /// Room for `bytes` in `b`: made again larger when short (its frame slot's last frame
    /// is done: `begin` waited for it).
    fn room(gw: *Window, b: *vk.device.Buffer, bytes: u64) ![]u8 {
        const d = &gw.x.setup.device;
        if (b.size < bytes) {
            if (b.handle != null) d.destroyBuffer(b);
            const source = c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT;
            b.* = try d.createBuffer(@max(bytes, 1 << 20), source, true);
        }
        return b.mapped[0..@intCast(bytes)];
    }
};

/// The window's frames until it closes or `clock.left()` is not above 0: the contract's
/// three rows.
// tidy: allow-fn(large-generic-function) one instance per App
// tidy: allow-fn(function-too-long) the loop's steps in order, each a few lines
pub fn loop(comptime App: type, app: *App, gw: *Window, run: Run, clock: anytype) !void {
    std.debug.assert(run.first.len == run.count.len);
    const w = run.w;
    const ctx = run.ctx;
    const follows = @hasField(App, "theme") and @FieldType(App, "theme") == lcgf.widgets_base.Theme;
    var styled: ?lcgf.input.Input.Appearance = null;
    var ev: Events = .{};
    var waiting_since_not_shown = false;
    gw.ctx = ctx;
    registry.shell = w;
    // tidy: allow(unbounded-loop) the event loop: it ends when the window closes or `clock` says
    while (true) {
        // An Expose: the server lost the window's pixels, which the picture still has.
        w.conn.pump() catch break;
        const exposed = w.damaged;
        if (!w.poll(&ev)) break;
        if (follows and !std.meta.eql(styled, ev.in.appearance)) {
            styled = ev.in.appearance;
            app.theme = lcgf.theme.widgets(&lcgf.theme.forAppearance(ev.in.appearance));
            w.background = app.theme.panel;
        }
        if (comptime page.composes(App)) {
            if (gw.paging.wants(ctx, &ev.in)) buildPage(App, app, gw, run, &ev);
        } else if (ctx.needsFrame(&ev.in)) build(App, app, gw, run, &ev);
        const due = gw.rows != null or anyDirty() or exposed or waiting_since_not_shown;
        if (due and (gw.x.setup.gfx.list != null or gw.rows != null)) {
            if (present(App, app, gw, w)) |_| {
                waiting_since_not_shown = false;
            } else |e| switch (e) {
                error.NotShown => {
                    gw.stats.not_shown += 1;
                    gw.owed = .everything;
                    gw.text_whole = true;
                    gw.labels_whole = true;
                    waiting_since_not_shown = true;
                },
                else => return e,
            }
        }
        const left = clock.left();
        if (!(left > 0)) break;
        if (anyDirty() and !waiting_since_not_shown) continue; // FIFO paces the next frame
        var s = @min(scheduler.wake(ctx, &ev.in), left);
        if (waiting_since_not_shown) s = @min(s, retry_seconds);
        // `.display` would add the shell's refresh timer: `begin` paces instead.
        const pace = scheduler.pace(ctx);
        w.wait(s, if (pace == .display) .once else pace);
    }
}

// ---- private ----

/// One built frame: the application's `build`, layout and paint, the glyphs placed, the
/// surfaces' rectangles from the layout, and the damage and rows owed.
// tidy: allow-fn(large-generic-function) one instance per App
fn build(comptime App: type, app: *App, gw: *Window, run: Run, ev: *const Events) void {
    std.debug.assert(ev.in.scale > 0);
    const ctx = run.ctx;
    var f = ctx.begin(&ev.in);
    registry.built = @splat(false);
    app.build(&f, ev);
    const out = run.tw.end(&f);
    run.w.apply(&out.platform);
    gw.stats.builds += 1;
    const placed: ?text.Frame = if (run.tw.on()) run.tw.glyphs(ctx, &out, ev.in.scale) else null;
    owe(gw, run, &out, out.draw, textGlyphs(gw, run, out.draw, placed), .{ 0, 0 }, &ev.in);
    oweImages(App, app, gw, out.draw);
}

/// `build` for an App that composes its frames into a page (src/app/page.zig): the frame is
/// built in the page's region, and the window draws the application's list.
// tidy: allow-fn(large-generic-function) one instance per App
// tidy: allow(too-many-parameters) the loop's state, passed through
fn buildPage(comptime App: type, app: *App, gw: *Window, run: Run, ev: *const Events) void {
    std.debug.assert(ev.in.scale > 0);
    const ctx = run.ctx;
    registry.built = @splat(false);
    const b = page.build(App, app, &gw.paging, ctx, run.tw, ev);
    run.w.apply(&b.out.platform);
    gw.stats.builds += 1;
    const list = b.composed.draw;
    const scale = ev.in.scale;
    const sides = b.composed.texts;
    const placed: ?text.Frame = if (run.tw.on()) run.tw.glyphsOf(ctx, list, sides, scale) else null;
    owe(gw, run, &b.out, list, textGlyphs(gw, run, list, placed), b.origin, &ev.in);
    oweImages(App, app, gw, list);
}

/// The quads of `list` that show an image whose generation moved since it was last written,
/// owed: the image's pixels changed, which no node's hash sees. A new count of images, a new
/// size or a first image owes the whole window.
// tidy: allow-fn(large-generic-function) one instance per App
fn oweImages(comptime App: type, app: *App, gw: *Window, list: *const DrawList) void {
    if (!@hasDecl(App, "images")) return;
    const images = app.images();
    std.debug.assert(images.len <= images_max);
    if (!gw.images_known or images.len != gw.image_len) {
        gw.owed = .everything;
        return;
    }
    var moved: u128 = 0;
    for (images, 0..) |img, k| {
        if (gw.images[k] == null or !std.mem.eql(u32, &gw.sizes[k], &img.size)) {
            gw.owed = .everything;
            return;
        }
        const bit = @as(u128, @intFromBool(gw.generations[k] != img.generation)) << @intCast(k + 1);
        moved |= bit;
    }
    lcgf.damage.addTextures(list, moved, &gw.owed);
}

/// The glyphs of `list` with the handles they sample: the service's `placed`, its atlas owed an
/// upload, or the bundled font's.
fn textGlyphs(gw: *Window, run: Run, list: *const DrawList, placed: ?text.Frame) Glyphs {
    if (placed) |p| {
        var glyphs = p.glyphs;
        glyphs.texture = @fromBackingInt(handle_text);
        // Canvas glyphs sample the label atlas when the App has one, else the font's cells.
        glyphs.canvas = @fromBackingInt(if (p.labels != null) handle_labels else handle_font);
        gw.text_dirty = p;
        return glyphs;
    }
    var glyphs = font.glyphs(list, run.quads, run.first, run.count);
    glyphs.texture = @fromBackingInt(handle_font);
    return glyphs;
}

/// The rows of `list` to draw, its damage owed, and the surfaces of frame `out` placed: their
/// nodes' rects moved by `origin`, the frame's (0, 0) in the window.
// tidy: allow(too-many-parameters) one frame's parts, from either build
fn owe(
    gw: *Window,
    run: Run,
    out: *const context.Output,
    list: *const lcgf.draw_list.DrawList,
    glyphs: Glyphs,
    origin: [2]f32,
    in: *const lcgf.input.Input,
) void {
    std.debug.assert(in.scale > 0);
    @import("app.zig").sayCustom(list);
    gw.rows = .{
        .list = list,
        .glyphs = glyphs,
        .viewport = in.viewport,
        .scale = in.scale,
    };
    unite(&gw.owed, &list.damage);
    for (registry.list, registry.built) |l, built| if (l) |s| if (built) {
        const r = out.tree.rect(s.node_ix);
        s.rect = .{ r.x0 + origin[0], r.y0 + origin[1], r.x1 + origin[0], r.y1 + origin[1] };
        const size: [2]u32 = .{
            @intFromFloat(@round(@max(r.x1 - r.x0, 0) * in.scale)),
            @intFromFloat(@round(@max(r.y1 - r.y0, 0) * in.scale)),
        };
        if (std.mem.eql(u32, &size, &s.size)) continue;
        s.size = size;
        s.dirty = true;
        // The node's `uv` came from the old size: one more frame shows the new one.
        run.ctx.waker.post();
    };
}

/// Marks every canvas `list` drew clean once its rows are uploaded, as `Instances.clearDirty`
/// asks of the host. The rows are the application's, given as `*const` to `Frame.canvas`;
/// only their dirty ranges change.
fn clearCanvases(list: *const DrawList) void {
    std.debug.assert(list.cmd_len <= list.cmd.kind.len);
    for (0..list.cmd_len) |i| {
        if (list.cmd.kind[i] != @backingInt(DrawList.Kind.canvas)) continue;
        @constCast(list.canvases[list.cmd.first[i]].instances).clearDirty();
    }
}

/// Draws and presents the frame owed: textures written, `draw` for dirty surfaces, the UI
/// inside the damage and the surfaces' rectangles. error.NotShown: nothing drawn or consumed.
// tidy: allow-fn(large-generic-function) one instance per App
fn present(comptime App: type, app: *App, gw: *Window, w: *x11.Window) !void {
    std.debug.assert(w.width > 0);
    const g = &gw.x.setup;
    const d = &g.device;
    const win = &gw.x.target;
    if (gw.refuse > 0) {
        gw.refuse -= 1;
        return error.NotShown;
    }
    var f = try win.begin(g, .{ .width = w.width, .height = w.height });
    const slot = f.acquired.slot;
    if (@hasDecl(App, "images")) {
        // A frame built since the last present owed the images' quads (`oweImages`); a
        // change with no frame built (a surface's frame) is drawn whole.
        const built = gw.rows != null;
        if (try writeImages(gw, f.cmd, slot, app.images()) and !built) gw.owed = .everything;
    }
    if (gw.text_dirty) |placed| {
        try writeText(gw, f.cmd, slot, placed);
        if (placed.labels) |l| try writeLabels(gw, f.cmd, slot, l, placed.labels_dirty);
    }
    for (registry.list) |l| if (l) |s| {
        s.dirty = s.dirty or s.requested;
        s.requested = false;
    };
    if (anyDirty()) {
        gw.staging[slot].rewind();
        var gf: GpuFrame = .{
            .device = .wrap(d),
            .arena = &gw.arena,
            .fresh = gw.stats.draws == 0,
            .upload = .beginStaged(.wrap(d), f.cmd, &gw.staging[slot]),
        };
        for (registry.list, registry.built) |l, built| if (l) |s| if (built and s.dirty) {
            try fitSurface(gw, s, &gf.upload);
        };
        if (@hasDecl(App, "draw")) {
            try app.draw(&gf);
            gw.stats.draws += 1;
        }
        _ = gf.encoder();
        for (registry.list, registry.built) |l, built| if (l) |s| if (built and s.dirty) {
            s.dirty = false;
            gw.owed.add(s.rect);
        };
    }
    if (gw.rows) |r| {
        gw.stats.row_bytes += r.list.quadBytes().len + r.glyphs.quads.len * @sizeOf(Quad);
    }
    const bg = w.background;
    const clear: [4]f32 = .{ unit(bg.r), unit(bg.g), unit(bg.b), 1 };
    try win.present(g, &f, .{ .rows = gw.rows, .damage = gw.owed, .clear = clear });
    // `prepare` ran with the rows: what it wrote is this frame's, and the rows it uploaded
    // are clean (the canvas's contract: the host clears them after `prepare`).
    if (gw.rows) |r| if (g.gfx.canvas) |*cv| {
        gw.stats.canvas_bytes += cv.uploaded;
        clearCanvases(r.list);
    };
    gw.stats.presents += 1;
    gw.stats.damage = gw.owed;
    gw.stats.whole += @intFromBool(std.meta.eql(gw.owed, Region.everything));
    gw.owed = .empty;
    gw.rows = null;
    gw.text_dirty = null;
}

fn unit(v: u8) f32 {
    return @as(f32, @floatFromInt(v)) / 255;
}

fn anyDirty() bool {
    for (registry.list, registry.built) |l, built| if (l) |s| {
        if (built and (s.dirty or s.requested)) return true;
    };
    return false;
}

/// Every rect of `from` added to `to`.
fn unite(to: *Region, from: *const Region) void {
    for (0..lcgf.damage.max_rects) |k| to.add(from.rect(@intCast(k)));
}

/// A sampled R8 image read as white with its byte as alpha, as `sw.Image.alpha8` is.
fn coverage(d: *const Device, width: u32, height: u32) !Image {
    std.debug.assert(width > 0);
    std.debug.assert(height > 0);
    const one = c.VK_COMPONENT_SWIZZLE_ONE;
    return d.createImage(.{
        .width = width,
        .height = height,
        .format = c.VK_FORMAT_R8_UNORM,
        .usage = c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
        .components = .{ .r = one, .g = one, .b = one, .a = c.VK_COMPONENT_SWIZZLE_R },
    });
}

/// Writes all of `img` from `pixels` in a submission of its own: for what `open` makes once.
fn writeOnce(g: *vk.Setup, img: *Image, pixels: []const u8) !void {
    const d = &g.device;
    std.debug.assert(pixels.len > 0);
    var staging = try d.createBuffer(pixels.len, c.VK_BUFFER_USAGE_TRANSFER_SRC_BIT, true);
    defer d.destroyBuffer(&staging);
    @memcpy(staging.mapped[0..pixels.len], pixels);
    const cmd = try g.once.begin(d);
    const region: vk.host.Rect = .{ .w = img.extent.width, .h = img.extent.height };
    const from = c.VK_IMAGE_LAYOUT_UNDEFINED;
    vk.host.uploadRegion(d, cmd, img.handle, staging.handle, 0, from, region);
    try g.once.submit(d);
}

/// The application's images whose generation, size or count changed, written in frame slot
/// `slot` and registered. True when any did, never on the first frame (drawn whole anyway).
// tidy: allow-fn(large-generic-function) one instance per App's image type
fn writeImages(gw: *Window, cmd: c.VkCommandBuffer, slot: u32, images: anytype) !bool {
    std.debug.assert(images.len <= images_max);
    const g = &gw.x.setup;
    const d = &g.device;
    var changed = false;
    var bytes: u64 = 0;
    for (images, 0..) |img, k| {
        if (gw.images[k] != null and gw.generations[k] == img.generation and
            std.mem.eql(u32, &gw.sizes[k], &img.size)) continue;
        bytes += @as(u64, img.size[0]) * img.size[1] * texelBytes(img);
    }
    if (bytes == 0 and images.len == gw.image_len and gw.images_known) return false;
    const staged = try gw.room(&gw.writes[slot], @max(bytes, 4));
    var at: u64 = 0;
    for (images, 0..) |img, k| {
        const same_size = std.mem.eql(u32, &gw.sizes[k], &img.size);
        if (gw.images[k] != null and gw.generations[k] == img.generation and same_size) continue;
        changed = true;
        if (gw.images[k] == null or !same_size) {
            // Frames in flight may sample the old image.
            _ = d.fns.vkDeviceWaitIdle.?(d.handle);
            if (gw.images[k]) |*old| d.destroyImage(old);
            gw.images[k] = if (texelBytes(img) == 1)
                try coverage(d, img.size[0], img.size[1])
            else
                try d.createImage(.{
                    .width = img.size[0],
                    .height = img.size[1],
                    .usage = c.VK_IMAGE_USAGE_SAMPLED_BIT | c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
                });
            const handle: Texture = @fromBackingInt(@as(u16, @intCast(k + 1)));
            g.gfx.setTexture(d, handle, gw.images[k].?.view, g.sampler);
        }
        const texels = @as(usize, img.size[0]) * img.size[1];
        const n = texels * texelBytes(img);
        const rgba = std.mem.sliceAsBytes(img.pixels);
        const src = if (n == texels) alphaOf(img)[0..texels] else rgba[0..n];
        @memcpy(staged[@intCast(at)..][0..n], src);
        const region: vk.host.Rect = .{ .w = img.size[0], .h = img.size[1] };
        const image = gw.images[k].?.handle;
        const fresh = c.VK_IMAGE_LAYOUT_UNDEFINED;
        vk.host.uploadRegion(d, cmd, image, gw.writes[slot].handle, at, fresh, region);
        at += n;
        gw.generations[k] = img.generation;
        gw.sizes[k] = img.size;
    }
    const first = !gw.images_known;
    changed = changed or images.len != gw.image_len;
    gw.image_len = @intCast(images.len);
    gw.images_known = true;
    return changed and !first;
}

/// Bytes of a texel of `img`: 1 for an alpha-only image (`Image.alpha`), else 4.
fn texelBytes(img: anytype) u32 {
    const a = alphaOf(img);
    std.debug.assert(a.len == 0 or img.pixels.len == 0);
    return if (a.len != 0) 1 else 4;
}

/// `img.alpha`, empty for an image type without it.
fn alphaOf(img: anytype) []const u8 {
    return if (@hasField(@TypeOf(img), "alpha")) img.alpha else &.{};
}

/// The text service's atlas: made on its first frame, its changed rectangle written (all of
/// it when `text_whole`). A new generation owes the whole window.
fn writeText(gw: *Window, cmd: c.VkCommandBuffer, slot: u32, placed: text.Frame) !void {
    const at: GpuAtlas = .{
        .image = &gw.text,
        .whole = &gw.text_whole,
        .writes = &gw.text_writes[slot],
        .handle = handle_text,
    };
    _ = try writeAtlas(gw, cmd, placed.atlas, placed.dirty, at);
}

/// The canvas label atlas, as `writeText` writes the text's.
fn writeLabels(
    gw: *Window,
    cmd: c.VkCommandBuffer,
    slot: u32,
    a: *const CoverageAtlas,
    dirty: ?CoverageAtlas.Upload,
) !void {
    const at: GpuAtlas = .{
        .image = &gw.labels,
        .whole = &gw.labels_whole,
        .writes = &gw.label_writes[slot],
        .handle = handle_labels,
    };
    gw.stats.label_bytes += try writeAtlas(gw, cmd, a, dirty, at);
}

/// Where a coverage atlas lives on the GPU: its image, whether it has to be written whole,
/// the frame slot's mapped buffer and its texture handle.
const CoverageAtlas = lcgf.raster_atlas.Atlas;

const GpuAtlas = struct { image: *?Image, whole: *bool, writes: *vk.device.Buffer, handle: u16 };

/// Atlas `a`'s image made the first time, then its changed rectangle `dirty` written (all of
/// it when `at.whole`), in the frame's upload phase. Returns the bytes written.
fn writeAtlas(
    gw: *Window,
    cmd: c.VkCommandBuffer,
    a: *const CoverageAtlas,
    dirty: ?CoverageAtlas.Upload,
    at: GpuAtlas,
) !u64 {
    const g = &gw.x.setup;
    const d = &g.device;
    if (at.image.* == null) {
        at.image.* = try coverage(d, a.w, a.h);
        g.gfx.setTexture(d, @fromBackingInt(at.handle), at.image.*.?.view, g.sampler);
        at.whole.* = true;
    }
    std.debug.assert(g.gfx.texture_count >= handles);
    const whole: Region2 = .{ .w = a.w, .h = a.h };
    const changed: ?Region2 = if (dirty) |v| .{ .x = v.x, .y = v.y, .w = v.w, .h = v.h } else null;
    const r: Region2 = if (at.whole.*) whole else changed orelse return 0;
    if (r.w == 0 or r.h == 0) return 0;
    const bytes = @as(u64, r.w) * r.h;
    const staged = try gw.room(at.writes, bytes);
    for (0..r.h) |y| {
        const src = a.pixels[(r.y + y) * a.w + r.x ..][0..r.w];
        @memcpy(staged[y * r.w ..][0..r.w], src);
    }
    const sampled = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL;
    const from: c.VkImageLayout = if (at.whole.*) c.VK_IMAGE_LAYOUT_UNDEFINED else sampled;
    const region: vk.host.Rect = .{ .x = @intCast(r.x), .y = @intCast(r.y), .w = r.w, .h = r.h };
    vk.host.uploadRegion(d, cmd, at.image.*.?.handle, at.writes.handle, 0, from, region);
    at.whole.* = false;
    return bytes;
}

const Region2 = struct { x: u32 = 0, y: u32 = 0, w: u32, h: u32 };

/// Gives `s` a texture at least its size, in steps of `Surface.step_px`, ready to sample
/// (through `upload`, the frame's upload phase) and registered.
fn fitSurface(gw: *Window, s: *Surface, upload: *gpu.Upload) !void {
    std.debug.assert(s.slot != null);
    if (s.size[0] == 0 or s.size[1] == 0) return;
    if (s.image) |img| if (img.extent.width >= s.size[0] and img.extent.height >= s.size[1]) return;
    const g = &gw.x.setup;
    const d = &g.device;
    // Frames in flight may sample the old texture.
    _ = d.fns.vkDeviceWaitIdle.?(d.handle);
    if (s.image) |*old| d.destroyImage(old);
    const step = Surface.step_px;
    const width = std.mem.alignForward(u32, s.size[0], step);
    const height = std.mem.alignForward(u32, s.size[1], step);
    s.image = try d.createImage(.{
        .width = width,
        .height = height,
        .usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_SAMPLED_BIT,
    });
    const img = s.image.?;
    s.texture = .{
        .image = img.handle,
        .view = img.view,
        .format = Surface.format,
        .width = width,
        .height = height,
        .samples = 1,
        .resting = c.VK_IMAGE_LAYOUT_SHADER_READ_ONLY_OPTIMAL,
    };
    upload.prepare(s.texture);
    g.gfx.setTexture(d, @fromBackingInt(handle_surface + @as(u16, s.slot.?)), img.view, g.sampler);
    // The node's `uv` was for the old texture.
    if (gw.ctx) |ctx| ctx.waker.post();
}

const testing = std.testing;
const Color = lcgf.types.Color;

/// A window on the test's server with Vulkan over it and a context, the text in the bundled
/// font. Filled in place; its buffers are static, one fixture at a time.
const Fixture = struct {
    conn: x11.Connection,
    w: x11.Window,
    gw: Window,
    ctx: context.Context,
    tw: text.Window,

    const limits: context.Limits = .{ .nodes = 1024, .texts = 8, .customs = 4, .damage = true };
    const ctx_bytes = context.Context.requiredBytes(limits);
    var ctx_buffer: [ctx_bytes]u8 align(lcgf.mem.column_align) = @splat(0);
    var quads: [256]Quad = undefined;
    var first: [limits.texts]u32 = undefined;
    var count: [limits.texts]u32 = undefined;
    var canvas_rows: [2 * limits.customs]lcgf.draw_list.CanvasDraw = undefined;
    const text_options: text.Options = .{
        .atlas = .{ 256, 256 },
        .images = 256,
        .quads = 256,
        .texts = limits.texts,
        .run_glyphs = 64,
        .run_lines = 4,
        .shape_slots = 16,
    };
    var service: [text.Text.requiredBytes(text_options)]u8 align(lcgf.mem.column_align) = undefined;
    const face = [_]text.File{.{ .bytes = @embedFile("layout.ttf") }};
    /// A label atlas, as `lcgf_app.run` gives an App with labels.
    const label_options: text.labels.Options = .{
        .atlas = .{ 256, 128 },
        .images = 64,
        .label_glyphs = 32,
    };
    const label_n = text.labels.Labels.requiredBytes(label_options);
    var label_bytes: [label_n]u8 align(lcgf.mem.column_align) = undefined;
    var label_atlas: text.labels.Labels = undefined;

    fn open(fx: *Fixture, display: []const u8, width: u16, height: u16) !void {
        try fx.openWith(display, width, height, &.{});
    }

    /// With the text service over `files` (none: the bundled font).
    fn openWith(fx: *Fixture, display: []const u8, w: u16, h: u16, files: []const text.File) !void {
        const room: Window.Open = .{ .gpu_bytes = 8 << 20, .staging_bytes = 1 << 20 };
        try fx.openRoom(display, .{ w, h }, files, room);
    }

    /// With the GPU window's room `o` (what app.zig makes of `Options.canvas`).
    // tidy: allow(too-many-parameters) the window's display, size, faces and room
    fn openRoom(
        fx: *Fixture,
        display: []const u8,
        size: [2]u16,
        files: []const text.File,
        o: Window.Open,
    ) !void {
        const w, const h = size;
        std.debug.assert(w > 0);
        fx.conn = .{};
        try fx.conn.open(display, "");
        errdefer fx.conn.close();
        fx.conn.overrideScale(1);
        const bufs: x11.Window.Buffers = .{
            .pixels = &.{},
            .glyphs = &quads,
            .first = &first,
            .count = &count,
        };
        try fx.w.open(&fx.conn, w, h, "lcgf app gpu", bufs);
        errdefer fx.w.close();
        try fx.gw.open(&fx.w, display, o);
        errdefer fx.gw.close();
        fx.ctx = try .init(&ctx_buffer, limits);
        fx.ctx.trackDamageWhole();
        fx.ctx.enableCanvas(&canvas_rows);
        const gpa = testing.allocator;
        fx.tw = try text.Window.open(&service, text_options, files, false, gpa, testing.io);
    }

    fn close(fx: *Fixture) void {
        fx.tw.close();
        fx.gw.close();
        fx.w.close();
        fx.conn.close();
    }

    /// Runs `app` until `clock` says stop.
    fn run(fx: *Fixture, app: anytype, clock: anytype) !void {
        const r: Run = .{
            .w = &fx.w,
            .ctx = &fx.ctx,
            .tw = &fx.tw,
            .quads = &quads,
            .first = &first,
            .count = &count,
        };
        try loop(@TypeOf(app.*), app, &fx.gw, r, clock);
    }
};

/// Stops after `seconds`, or once `done` says so.
fn Clock(comptime Done: type) type {
    return struct {
        t0: std.Io.Timestamp,
        seconds: f32,
        done: Done,

        pub fn left(k: @This()) f32 {
            if (k.done.stop()) return 0;
            const ns = k.t0.durationTo(std.Io.Timestamp.now(testing.io, .awake)).toNanoseconds();
            return k.seconds - @as(f32, @floatFromInt(ns)) / std.time.ns_per_s;
        }
    };
}

const Never = struct {
    fn stop(_: Never) bool {
        return false;
    }
};

fn seconds(s: f32) Clock(Never) {
    return .{ .t0 = .now(testing.io, .awake), .seconds = s, .done = .{} };
}

/// A button-like box beside a surface the application paints one colour at a time: `paints`
/// more frames of it, each a new colour, while `hot` toggling makes widget frames.
const SurfaceApp = struct {
    plot: Surface = .{},
    builds: u32 = 0,
    draws: u32 = 0,
    /// Surface frames still to make, and widget frames still to make.
    paints: u32 = 0,
    toggles: u32 = 0,
    hot: bool = false,
    shade: u8 = 0,

    const ground: Color = .rgb(30, 30, 30);
    const plot_rect: [4]f32 = .{ 100, 20, 180, 80 };

    pub fn build(a: *SurfaceApp, f: *lcgf.frame.Frame, _: *const Events) void {
        a.builds += 1;
        // Toggled before it is drawn: the frame that toggles shows it.
        if (a.toggles > 0) {
            a.toggles -= 1;
            a.hot = !a.hot;
            f.ctx.waker.post();
        }
        _ = f.open(.none, .{ .size = .{ .fill, .fill }, .fill = ground });
        const box: Color = if (a.hot) .rgb(250, 250, 250) else .rgb(0, 0, 200);
        const button: [2]lcgf.types.Size = .{ .px(60), .px(30) };
        _ = f.leaf(.none, .{ .float = true, .offset = .{ 10, 20 }, .size = button, .fill = box });
        const plot: [2]lcgf.types.Size = .{ .px(80), .px(60) };
        _ = a.plot.node(f, .from("plot"), .{ .float = true, .offset = .{ 100, 20 }, .size = plot });
        f.close();
    }

    pub fn draw(a: *SurfaceApp, g: *GpuFrame) !void {
        a.draws += 1;
        const v: f64 = @as(f64, @floatFromInt(a.shade)) / 255;
        const enc = g.encoder();
        var pass = enc.beginRenderPass(.{ .color_attachments = &.{.{
            .view = a.plot.texture.createView(),
            .clear_value = .{ .r = v, .g = 1 - v, .b = 0, .a = 1 },
        }} });
        pass.end();
        if (a.paints > 0) {
            a.paints -= 1;
            a.shade +%= 2;
            a.plot.redraw();
        }
    }
};

/// Pixel (x, y) of the window once it is `want`, or as it is after a second: the Vulkan
/// implementation presents over its own connection, in its own time.
fn shown(w: *x11.Window, x: i16, y: i16, want: Color) !Color {
    var got = try x11.pixel(w, x, y);
    for (0..200) |_| {
        if (std.meta.eql(got, want)) break;
        w.conn.waitReadable(0.005);
        got = try x11.pixel(w, x, y);
    }
    return got;
}

fn displayOrSkip() ![]const u8 {
    return testing.environ.getPosix("LCGF_X11_TEST_DISPLAY") orelse error.SkipZigTest;
}

/// The window's pixels in `box` (x0, y0, x1, y1), row by row, into `out`.
fn readPixels(w: *x11.Window, box: [4]i16, out: []Color) !void {
    var k: usize = 0;
    var y = box[1];
    while (y < box[3]) : (y += 1) {
        var x = box[0];
        while (x < box[2]) : (x += 1) {
            out[k] = try x11.pixel(w, x, y);
            k += 1;
        }
    }
}

test "T2: surface frames under an idle UI build nothing, upload no rows, redraw only the surface" {
    var fx: Fixture = undefined;
    try fx.open(try displayOrSkip(), 200, 100);
    defer fx.close();
    var app: SurfaceApp = .{};
    try fx.run(&app, seconds(0.3));
    try testing.expect(app.draws >= 1);
    const builds = app.builds;
    const rows = fx.gw.stats.row_bytes;
    var before: [200 * 20]Color = undefined;
    try readPixels(&fx.w, .{ 0, 0, 200, 20 }, &before);
    const outside = try x11.pixel(&fx.w, 30, 30);

    const Done = struct {
        a: *const SurfaceApp,
        fn stop(d: @This()) bool {
            return d.a.paints == 0;
        }
    };
    const draws = app.draws;
    app.paints = 100;
    app.plot.redraw();
    try fx.run(&app, Clock(Done){ .t0 = .now(testing.io, .awake), .seconds = 30, .done = .{
        .a = &app,
    } });
    try testing.expect(app.draws - draws >= 100);
    try testing.expectEqual(builds, app.builds);
    try testing.expectEqual(rows, fx.gw.stats.row_bytes);
    // The picture's pass was scissored to the surface's rectangle, and only it.
    try testing.expectEqual(SurfaceApp.plot_rect, fx.gw.stats.damage.bounds());
    try testing.expectEqual(@as(u32, 1), fx.gw.stats.damage.count());
    // Shown: outside the same bytes, inside the last colour.
    try fx.run(&app, seconds(0.2));
    var after: [200 * 20]Color = undefined;
    try readPixels(&fx.w, .{ 0, 0, 200, 20 }, &after);
    try testing.expectEqualSlices(Color, &before, &after);
    try testing.expectEqual(outside, try x11.pixel(&fx.w, 30, 30));
    const inside = try x11.pixel(&fx.w, 140, 50);
    try testing.expectEqual(@as(u8, app.shade), inside.r);
    try testing.expectEqual(@as(u8, 255 - app.shade), inside.g);
}

test "T3: widget frames beside a surface never call draw" {
    var fx: Fixture = undefined;
    try fx.open(try displayOrSkip(), 200, 100);
    defer fx.close();
    var app: SurfaceApp = .{};
    try fx.run(&app, seconds(0.3));
    const draws = app.draws;
    const builds = app.builds;
    const Done = struct {
        a: *const SurfaceApp,
        fn stop(d: @This()) bool {
            return d.a.toggles == 0;
        }
    };
    app.toggles = 100;
    fx.ctx.waker.post();
    try fx.run(&app, Clock(Done){ .t0 = .now(testing.io, .awake), .seconds = 30, .done = .{
        .a = &app,
    } });
    try testing.expect(app.builds - builds >= 100);
    try testing.expectEqual(draws, app.draws);
}

test "T4: an idle second presents nothing" {
    var fx: Fixture = undefined;
    try fx.open(try displayOrSkip(), 200, 100);
    defer fx.close();
    var app: SurfaceApp = .{};
    try fx.run(&app, seconds(0.3));
    const presents = fx.gw.stats.presents;
    const builds = app.builds;
    try fx.run(&app, seconds(1));
    try testing.expectEqual(presents, fx.gw.stats.presents);
    try testing.expectEqual(builds, app.builds);
}

test "not shown: a frame the window does not take owes the whole window, drawn when it is" {
    var fx: Fixture = undefined;
    try fx.open(try displayOrSkip(), 200, 100);
    defer fx.close();
    var app: SurfaceApp = .{};
    try fx.run(&app, seconds(0.3));
    const presents = fx.gw.stats.presents;
    const builds = app.builds;
    const whole = fx.gw.stats.whole;
    // A widget changes while the window is hidden for two attempts.
    fx.gw.refuse = 2;
    app.toggles = 1;
    fx.ctx.waker.post();
    try fx.run(&app, seconds(2 * retry_seconds + 0.5));
    try testing.expectEqual(@as(u32, 2), fx.gw.stats.not_shown);
    // Built once (the toggle) and once more (its settle), drawn whole once shown.
    try testing.expect(app.builds - builds <= 2);
    try testing.expect(fx.gw.stats.presents > presents);
    try testing.expect(fx.gw.stats.whole > whole);
    const lit: Color = .rgb(250, 250, 250);
    try testing.expectEqual(lit, try shown(&fx.w, 30, 30, lit));
}

test "not shown: widget frames with every other one refused never call draw, then sleep" {
    var fx: Fixture = undefined;
    try fx.open(try displayOrSkip(), 200, 100);
    defer fx.close();
    var app: SurfaceApp = .{ .shade = 100 };
    try fx.run(&app, seconds(0.3));
    const draws = app.draws;
    const surface = try x11.pixel(&fx.w, 140, 50);
    const Presented = struct {
        a: *const SurfaceApp,
        gw: *const Window,
        fn stop(d: @This()) bool {
            return d.a.toggles == 0 and d.gw.rows == null;
        }
    };
    const frames = 8;
    for (0..frames) |k| {
        fx.gw.refuse = @intFromBool(k % 2 == 0);
        app.toggles = 1;
        fx.ctx.waker.post();
        const done: Presented = .{ .a = &app, .gw = &fx.gw };
        const t0: std.Io.Timestamp = .now(testing.io, .awake);
        const clock: Clock(Presented) = .{ .t0 = t0, .seconds = 3, .done = done };
        try fx.run(&app, clock);
        try testing.expect(done.stop());
        const want: Color = if (app.hot) .rgb(250, 250, 250) else .rgb(0, 0, 200);
        try testing.expectEqual(want, try shown(&fx.w, 30, 30, want));
    }
    try testing.expectEqual(@as(u32, frames / 2), fx.gw.stats.not_shown);
    // Each refused frame came back whole from the rows and the surface's texture on the GPU.
    try testing.expectEqual(draws, app.draws);
    const off: Color = .rgb(0, 0, 200);
    try testing.expectEqual(off, try shown(&fx.w, 30, 30, off));
    try testing.expectEqual(surface, try x11.pixel(&fx.w, 140, 50));

    // Hidden with a frame owed: the loop sleeps between `retry_seconds` attempts, no spin.
    fx.gw.refuse = 1000;
    app.toggles = 1;
    fx.ctx.waker.post();
    const presents = fx.gw.stats.presents;
    const refused = fx.gw.stats.not_shown;
    try fx.run(&app, seconds(1.2));
    try testing.expectEqual(presents, fx.gw.stats.presents);
    try testing.expectEqual(draws, app.draws);
    // The toggle and its settle, a retry each `retry_seconds`, and the one the clock's end woke.
    try testing.expect(fx.gw.stats.not_shown - refused <= 2 + 2 + 1);
    fx.gw.refuse = 0;
}

/// The application's image on a node, a line of text in the test face, and a box.
const PictureApp = struct {
    const green: Color = .rgb(0, 200, 0);
    const ground: Color = .rgb(30, 30, 30);
    const blue: Color = .rgb(0, 0, 220);
    const Picture = struct { pixels: []const u32, size: [2]u32, generation: u32 = 0 };
    /// Where image 0 and image 1 are shown.
    const first_rect = [4]f32{ 10, 10, 30, 30 };
    const second_at = [2]f32{ 50, 10 };
    texels: [4]u32 = @splat(green.bitsOf()),
    second: [4]u32 = @splat(blue.bitsOf()),
    list: [2]Picture = undefined,
    generation: u32 = 0,

    pub fn images(a: *PictureApp) []const Picture {
        a.list = .{
            .{ .pixels = &a.texels, .size = .{ 2, 2 }, .generation = a.generation },
            .{ .pixels = &a.second, .size = .{ 2, 2 } },
        };
        return &a.list;
    }

    pub fn build(_: *PictureApp, f: *lcgf.frame.Frame, _: *const Events) void {
        std.debug.assert(first_rect[0] < second_at[0]);
        _ = f.open(.none, .{ .size = .{ .fill, .fill }, .fill = ground });
        const at: [2]f32 = .{ first_rect[0], first_rect[1] };
        _ = f.leaf(.none, .{
            .float = true,
            .offset = at,
            .size = .{ .px(20), .px(20) },
            .fill = .white,
            .texture = @fromBackingInt(1),
        });
        _ = f.leaf(.none, .{
            .float = true,
            .offset = second_at,
            .size = .{ .px(20), .px(20) },
            .fill = .white,
            .texture = @fromBackingInt(2),
        });
        const line: lcgf.types.Style = .{ .float = true, .offset = .{ 100, 10 } };
        _ = f.textStyled("W", .{ .px = 20, .color = .white }, line);
        f.close();
    }
};

test "gpu images and text: an image and the service's glyphs draw; a new generation, its nodes" {
    var fx: Fixture = undefined;
    try fx.openWith(try displayOrSkip(), 200, 100, &Fixture.face);
    defer fx.close();
    try testing.expect(fx.tw.on());
    var app: PictureApp = .{};
    try fx.run(&app, seconds(0.3));
    try testing.expectEqual(PictureApp.green, try shown(&fx.w, 20, 20, PictureApp.green));
    try testing.expectEqual(PictureApp.ground, try x11.pixel(&fx.w, 50, 50));
    // The glyph covers part of its box, smoothly: some pixels lit, most of the box not.
    var lit: u32 = 0;
    for (10..35) |y| for (100..115) |x| {
        lit += @intFromBool((try x11.pixel(&fx.w, @intCast(x), @intCast(y))).r > 128);
    };
    try testing.expect(lit > 12);
    try testing.expect(lit < 15 * 25 / 2);

    // New pixels in image 0, under a new generation: only its node is drawn, from them; image 1
    // is not drawn again, and an idle second after presents nothing.
    const whole = fx.gw.stats.whole;
    const red: Color = .rgb(220, 0, 0);
    app.texels = @splat(red.bitsOf());
    app.generation += 1;
    fx.ctx.waker.post();
    try fx.run(&app, seconds(0.3));
    try testing.expectEqual(red, try shown(&fx.w, 20, 20, red));
    try testing.expectEqual(PictureApp.first_rect, fx.gw.stats.damage.bounds());
    try testing.expectEqual(@as(u32, 1), fx.gw.stats.damage.count());
    try testing.expectEqual(whole, fx.gw.stats.whole);
    try testing.expectEqual(PictureApp.blue, try x11.pixel(&fx.w, 60, 20));
    const presents = fx.gw.stats.presents;
    try fx.run(&app, seconds(1));
    try testing.expectEqual(presents, fx.gw.stats.presents);
}

test "gpu page: a composed page draws both sides; a pan scissors the canvas; idle presents none" {
    var fx: Fixture = undefined;
    try fx.openWith(try displayOrSkip(), 300, 200, &Fixture.face);
    defer fx.close();
    try testing.expect(fx.tw.on());
    const T = page.TestApp;
    var app: T = .{};
    try fx.run(&app, seconds(0.3));
    const plot = app.canvas_rect;
    try testing.expectEqual(T.tint, try shown(&fx.w, 258, 16, T.tint));
    try testing.expectEqual(T.page_fill, try x11.pixel(&fx.w, 200, 4));
    try testing.expectEqual(T.region_fill, try x11.pixel(&fx.w, 290, 190));
    try testing.expectEqual(T.red, try page.pixelIn(&fx.w, plot, 15, 15));
    try page.expectPageText(&fx.w, &app, &fx.tw.text.?);

    // A pan: one frame built, its pass scissored to the canvas node's rect; no `draw` (none).
    const builds = fx.gw.stats.builds;
    app.camera.offset = .{ 50, 30 };
    fx.ctx.waker.post();
    try fx.run(&app, seconds(0.3));
    try testing.expectEqual(plot, fx.gw.stats.damage.bounds());
    try testing.expectEqual(@as(u32, 1), fx.gw.stats.damage.count());
    try testing.expectEqual(T.red, try page.pixelIn(&fx.w, plot, 55, 35));
    try testing.expectEqual(T.canvas_fill, try page.pixelIn(&fx.w, plot, 15, 15));
    try testing.expect(fx.gw.stats.builds > builds);
    try testing.expectEqual(@as(u32, 0), fx.gw.stats.draws);

    // The compiled checkbox: within its rect.
    const widget = app.widgetRect();
    app.ui.signals.state.grid = false;
    fx.ctx.waker.post();
    try fx.run(&app, seconds(0.3));
    const d = fx.gw.stats.damage.bounds();
    try testing.expect(d[0] >= widget[0] and d[1] >= widget[1]);
    try testing.expect(d[2] <= widget[2] and d[3] <= widget[3]);

    // The page's icon gets new pixels: its node is the scissor, and nothing else.
    app.clearIcon();
    fx.ctx.waker.post();
    try fx.run(&app, seconds(0.3));
    try testing.expectEqual(T.icon_rect, fx.gw.stats.damage.bounds());
    try testing.expectEqual(T.page_fill, try shown(&fx.w, 258, 16, T.page_fill));

    // Idle: nothing presented.
    const presents = fx.gw.stats.presents;
    try fx.run(&app, seconds(1));
    try testing.expectEqual(presents, fx.gw.stats.presents);
}

test "gpu page: a canvas label in a composed page's region draws as the reference" {
    var fx: Fixture = undefined;
    try fx.openWith(try displayOrSkip(), 300, 200, &Fixture.face);
    defer fx.close();
    Fixture.label_atlas = .init(&Fixture.label_bytes, Fixture.label_options);
    fx.tw.labels = &Fixture.label_atlas;
    const handle: text.labels.Handle = .{ .text = &fx.tw.text.?, .labels = &Fixture.label_atlas };
    var app: page.TestApp = .{ .labels = handle };
    try fx.run(&app, seconds(0.3));
    try testing.expect(app.labelled);
    _ = try shown(&fx.w, 258, 16, page.TestApp.tint);
    try page.expectCanvas(&fx.w, &app);
    try page.expectPageText(&fx.w, &app, &fx.tw.text.?);
}

test "gpu canvas: bitmap canvas glyphs sample the bundled font beside the service's text" {
    for ([_][]const text.File{ &Fixture.face, &.{} }) |files| {
        var fx: Fixture = undefined;
        try fx.openWith(try displayOrSkip(), 300, 200, files);
        defer fx.close();
        try testing.expectEqual(files.len != 0, fx.tw.on());
        const Shapes = lcgf.canvas.Instances;
        const Rows = struct {
            const n = Shapes.requiredBytes(64, 1, 1, .{});
            var bytes: [n]u8 align(lcgf.mem.column_align) = undefined;
            var reference: [lcgf.render_sw.Framebuffer.len(300, 200)]u32 = undefined;
        };
        var carver: lcgf.mem.Carver = .{ .buf = &Rows.bytes };
        var shapes = Shapes.init(&carver, 64, 1, 1, .{});
        var app: text.labels.BitmapApp = .{ .shapes = &shapes };
        for ([_]f32{ 1, 2 }) |s| {
            fx.conn.overrideScale(s);
            fx.ctx.waker.post();
            try fx.run(&app, seconds(0.3));
            try app.expectWindow(&fx.w, x11.pixel, s, &Rows.reference);
        }
    }
}

/// 100,000 filled squares `cell` logical pixels a side, `across` to a line, in their own grey,
/// the first, the middle and the last red, green and blue; the camera `pan` pixels right.
/// `moves` more frames each move it a pixel.
const RowsApp = struct {
    const n = 100_000;
    const Instances = lcgf.canvas.Instances;
    const Storage = struct {
        const len = Instances.requiredBytes(n, 0, 1, .{});
        var bytes: [len]u8 align(lcgf.mem.column_align) = undefined;
    };
    const grey: Color = .rgb(64, 64, 64);
    const picked = [3]u32{ 0, n / 2, n - 1 };
    const colors = [3]Color{ .rgb(255, 0, 0), .rgb(0, 255, 0), .rgb(0, 0, 255) };
    shapes: Instances,
    cell: u32,
    across: u32,
    pan: i32 = 0,
    moves: u32 = 0,
    builds: u32 = 0,
    ranges: [1]lcgf.canvas.Range = undefined,

    fn init(cell: u32, across: u32) RowsApp {
        std.debug.assert(cell > 0);
        var carver: lcgf.mem.Carver = .{ .buf = &Storage.bytes };
        const shapes: Instances = .init(&carver, n, 0, 1, .{});
        var a: RowsApp = .{ .shapes = shapes, .cell = cell, .across = across };
        for (0..n) |k| {
            const p = a.at(@intCast(k));
            const q = [2]i32{ p[0] + @as(i32, @intCast(cell)), p[1] + @as(i32, @intCast(cell)) };
            _ = a.shapes.rect(p, q, .{ .color = grey, .stroke = false });
        }
        for (picked, colors) |k, color| a.shapes.setColor(k, color);
        return a;
    }

    /// Row `k`'s top-left corner, logical pixels at camera scale 1 and no pan.
    fn at(a: *const RowsApp, k: u32) [2]i32 {
        return .{ @intCast((k % a.across) * a.cell), @intCast((k / a.across) * a.cell) };
    }

    pub fn build(a: *RowsApp, f: *lcgf.frame.Frame, _: *const Events) void {
        a.builds += 1;
        if (a.moves > 0) {
            a.moves -= 1;
            a.pan += 1;
            f.ctx.waker.post();
        }
        a.ranges = .{a.shapes.since(0)};
        _ = f.open(.none, .{ .size = .{ .fill, .fill }, .fill = .black });
        const cam: lcgf.canvas.Camera = .{ .scale = 1, .offset = .{ @floatFromInt(a.pan), 0 } };
        const o: lcgf.frame.CanvasOptions = .{ .camera = cam, .ranges = &a.ranges };
        _ = f.canvas(.from("rows"), .{ .size = .{ .fill, .fill } }, &a.shapes, o);
        f.close();
    }
};

/// The GPU window's room for `RowsApp`: `Options.canvas = .{ .rows = 100_000 }`.
const rows_room: Window.Open = .{ .staging_bytes = 8 << 20, .canvas_rows = RowsApp.n };

test "gpu canvas: 100,000 rows draw to the last one, and a pan uploads none of them" {
    var fx: Fixture = undefined;
    try fx.openRoom(try displayOrSkip(), .{ 808, 500 }, &.{}, rows_room);
    defer fx.close();
    var app: RowsApp = .init(2, 400);
    try fx.run(&app, seconds(0.5));
    try testing.expectEqual(null, fx.gw.x.setup.gfx.canvas.?.err);
    try expectRows(&fx, &app);
    // Four frames, the camera a pixel further each: the rows stay where they were uploaded.
    const bytes = fx.gw.stats.canvas_bytes;
    const presents = fx.gw.stats.presents;
    app.moves = 4;
    fx.ctx.waker.post();
    try fx.run(&app, seconds(0.5));
    try testing.expectEqual(4, app.pan);
    try testing.expect(fx.gw.stats.presents - presents >= 4);
    const uniforms = lcgf.canvas_shader.Uniforms.headBytes(0);
    try testing.expect(fx.gw.stats.canvas_bytes - bytes <= 8 * uniforms);
    try expectRows(&fx, &app);
}

/// The first, the middle and the last row of `app` in their colours, and the row before the
/// last grey: a canvas that drew short leaves the ground there.
fn expectRows(fx: *Fixture, app: *const RowsApp) !void {
    std.debug.assert(app.cell >= 2);
    for (RowsApp.picked, RowsApp.colors) |k, want| {
        const p = app.at(k);
        const got = try shown(&fx.w, @intCast(p[0] + app.pan + 1), @intCast(p[1] + 1), want);
        try testing.expectEqual(want, got);
    }
    const p = app.at(RowsApp.n - 2);
    const got = try shown(&fx.w, @intCast(p[0] + app.pan + 1), @intCast(p[1] + 1), RowsApp.grey);
    try testing.expectEqual(RowsApp.grey, got);
}

/// A canvas with a half-transparent line, and a box beside it that `lit` turns white.
const CanvasApp = struct {
    shapes: *const lcgf.canvas.Instances,
    palette: *const lcgf.canvas.Palette,
    /// Read when the frame is drawn, after `build`: kept here, not on its stack.
    ranges: [1]lcgf.canvas.Range,
    lit: bool = false,

    pub fn build(a: *CanvasApp, f: *lcgf.frame.Frame, _: *const Events) void {
        _ = f.open(.none, .{ .size = .{ .fill, .fill }, .fill = .rgb(30, 30, 30) });
        const side: [2]lcgf.types.Size = .{ .px(80), .px(80) };
        const view: lcgf.types.Style = .{ .float = true, .offset = .{ 10, 10 }, .size = side };
        const o: lcgf.frame.CanvasOptions = .{ .palette = a.palette, .ranges = &a.ranges };
        _ = f.canvas(.from("canvas"), view, a.shapes, o);
        const box: Color = if (a.lit) .white else .rgb(0, 0, 200);
        const square: [2]lcgf.types.Size = .{ .px(30), .px(30) };
        _ = f.leaf(.none, .{ .float = true, .offset = .{ 120, 10 }, .size = square, .fill = box });
        f.close();
    }
};

test "gpu labels: labels draw as the reference at camera and window scales; a pan uploads none" {
    var fx: Fixture = undefined;
    try fx.openWith(try displayOrSkip(), 200, 100, &Fixture.face);
    defer fx.close();
    Fixture.label_atlas = .init(&Fixture.label_bytes, Fixture.label_options);
    fx.tw.labels = &Fixture.label_atlas;
    const Shapes = lcgf.canvas.Instances;
    const Rows = struct {
        var bytes: [Shapes.requiredBytes(64, 1, 1, .{})]u8 align(lcgf.mem.column_align) = undefined;
        var reference: [lcgf.render_sw.Framebuffer.len(200, 100)]u32 = undefined;
    };
    var carver: lcgf.mem.Carver = .{ .buf = &Rows.bytes };
    var shapes = Shapes.init(&carver, 64, 1, 1, .{});
    var app: text.labels.TestApp = .{
        .shapes = &shapes,
        .words = &.{ "R1 10k Vout", "GND" },
        .labels = .{ .text = &fx.tw.text.?, .labels = &Fixture.label_atlas },
    };
    for ([_]f32{ 1, 2 }) |s| {
        fx.conn.overrideScale(s);
        for ([_]f32{ 1, 4 }) |zoom| {
            app.zoom = zoom;
            fx.ctx.waker.post();
            try fx.run(&app, seconds(0.3));
            try app.expectWindow(&fx.w, x11.pixel, s, &Rows.reference);
        }
    }
    try testing.expectEqual(1, app.remakes);
    try testing.expect(fx.gw.stats.label_bytes > 0);
    // A pan: no label made again, no byte of the label atlas uploaded.
    const bytes = fx.gw.stats.label_bytes;
    app.pan = 30;
    fx.ctx.waker.post();
    try fx.run(&app, seconds(0.3));
    try app.expectWindow(&fx.w, x11.pixel, 2, &Rows.reference);
    try testing.expectEqual(1, app.remakes);
    try testing.expectEqual(bytes, fx.gw.stats.label_bytes);
}

test "gpu canvas: a canvas beside a damaged rect is not drawn again over itself" {
    var fx: Fixture = undefined;
    try fx.open(try displayOrSkip(), 200, 100);
    defer fx.close();
    const Shapes = lcgf.canvas.Instances;
    var buf: [Shapes.requiredBytes(4, 0, 1, .{})]u8 align(lcgf.mem.column_align) = undefined;
    var carver: lcgf.mem.Carver = .{ .buf = &buf };
    var shapes: Shapes = .init(&carver, 4, 0, 1, .{});
    _ = shapes.segment(.{ 5, 40 }, .{ 75, 40 }, .{});
    const layers = [_]lcgf.canvas.Layer{.of(.{ .stroke = .{ .r = 255, .a = 128 }, .width = 8 })};
    const palette: lcgf.canvas.Palette = .{ .layers = &layers };
    var app: CanvasApp = .{ .shapes = &shapes, .palette = &palette, .ranges = .{shapes.since(0)} };
    try fx.run(&app, seconds(0.3));
    _ = try shown(&fx.w, 130, 20, .rgb(0, 0, 200));
    const line = try x11.pixel(&fx.w, 50, 50);
    try testing.expect(line.r > 100);
    try testing.expect(line.r < 250);
    // The box changes five times: each frame's damage is the box, and the canvas, outside it,
    // keeps its pixels (drawn again over itself, its half-transparent line would darken).
    for (0..5) |_| {
        app.lit = !app.lit;
        fx.ctx.waker.post();
        try fx.run(&app, seconds(0.1));
    }
    try testing.expectEqual(Color.white, try shown(&fx.w, 130, 20, .white));
    try testing.expectEqual(line, try x11.pixel(&fx.w, 50, 50));
}

/// 32 x 24 bordered cells over a 2560 x 1440 window, the plot surface over the middle of
/// them: `toggles` widget frames (cell 0 changes colour), `paints` surface frames.
const GridApp = struct {
    plot: Surface = .{},
    hot: bool = false,
    toggles: u32 = 0,
    paints: u32 = 0,
    builds: u32 = 0,
    draws: u32 = 0,

    pub fn build(a: *GridApp, f: *lcgf.frame.Frame, _: *const Events) void {
        std.debug.assert(f.ctx.limits.nodes >= 32 * 24 + 26);
        a.builds += 1;
        _ = f.open(.none, .{ .size = .{ .fill, .fill }, .fill = .rgb(30, 30, 30) });
        for (0..24) |row| {
            _ = f.open(.none, .{ .dir = .x, .size = .{ .fill, .px(60) } });
            for (0..32) |col| {
                const on = row == 0 and col == 0 and a.hot;
                _ = f.leaf(.none, .{
                    .size = .{ .px(76), .px(56) },
                    .radius = 6,
                    .border = 1,
                    .border_color = .white,
                    .fill = if (on) .rgb(220, 60, 60) else .rgb(60, 60, 70),
                });
            }
            f.close();
        }
        const plot: [2]lcgf.types.Size = .{ .px(800), .px(600) };
        const at: [2]f32 = .{ 880, 420 };
        _ = a.plot.node(f, .from("plot"), .{ .float = true, .offset = at, .size = plot });
        f.close();
        if (a.toggles > 0) {
            a.toggles -= 1;
            a.hot = !a.hot;
            f.ctx.waker.post();
        }
    }

    pub fn draw(a: *GridApp, g: *GpuFrame) !void {
        a.draws += 1;
        const v: f64 = @as(f64, @floatFromInt(a.draws % 256)) / 255;
        var pass = g.encoder().beginRenderPass(.{ .color_attachments = &.{.{
            .view = a.plot.texture.createView(),
            .clear_value = .{ .r = v, .g = 0.3, .b = 0.5, .a = 1 },
        }} });
        pass.end();
        a.paints -|= 1;
        if (a.paints > 0) a.plot.redraw();
    }
};

/// Wall and calling-thread CPU time of what runs between `start` and `stop`.
const Spent = struct {
    at: [2]u64,

    fn start() Spent {
        std.debug.assert(clockNs(.MONOTONIC) > 0);
        return .{ .at = .{ clockNs(.MONOTONIC), clockNs(.THREAD_CPUTIME_ID) } };
    }

    /// Microseconds of wall and thread CPU time per frame, over `frames`.
    fn per(s: Spent, frames: u32) [2]f64 {
        const n: f64 = @floatFromInt(@max(frames, 1));
        const wall: f64 = @floatFromInt(clockNs(.MONOTONIC) - s.at[0]);
        const cpu: f64 = @floatFromInt(clockNs(.THREAD_CPUTIME_ID) - s.at[1]);
        return .{ wall / n / 1000, cpu / n / 1000 };
    }
};

fn clockNs(clock: std.os.linux.clockid_t) u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(clock, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Appends a formatted line to `fd`: the test runner fails a test that writes to stderr.
fn note(fd: i32, comptime format: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const t = std.fmt.bufPrint(&buf, format, args) catch return;
    _ = std.os.linux.write(fd, t.ptr, t.len);
}

// What a surface frame, a widget frame and an idle second cost through `lcgf_app`'s loop at
// 2560 x 1440: calling-thread CPU and wall time per frame, from the loop's first call to its
// return (build, layout, paint, `draw`, uploads, the UI's pass, submit and present), appended
// to the file LCGF_APP_GPU_BENCH names. The device is the one VK_ICD_FILENAMES leaves.
test "gpu frame cost at 2560 x 1440 (LCGF_APP_GPU_BENCH)" {
    const display = try displayOrSkip();
    const path = testing.environ.getPosix("LCGF_APP_GPU_BENCH") orelse return error.SkipZigTest;
    const flags: std.os.linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    const opened = std.os.linux.open(path, flags, 0o644);
    if (std.os.linux.errno(opened) != .SUCCESS) return error.BenchFile;
    const fd: i32 = @intCast(opened);
    defer _ = std.os.linux.close(fd);
    var fx: Fixture = undefined;
    try fx.open(display, 2560, 1440);
    defer fx.close();
    var app: GridApp = .{};
    try fx.run(&app, seconds(0.5));
    const frames = 300;
    const Done = struct {
        a: *const GridApp,
        fn stop(d: @This()) bool {
            return d.a.paints == 0 and d.a.toggles == 0;
        }
    };
    const done: Done = .{ .a = &app };
    const unfinished = "; unfinished {d}, not shown {d}\n";
    note(fd, "device {s}, {d} frames a mode\n", .{ fx.gw.x.setup.device.name(), frames });

    var builds = app.builds;
    var draws = app.draws;
    var refused = fx.gw.stats.not_shown;
    app.paints = frames;
    app.plot.redraw();
    var t = Spent.start();
    try fx.run(&app, Clock(Done){ .t0 = .now(testing.io, .awake), .seconds = 120, .done = done });
    var us = t.per(app.draws - draws);
    const surface = "surface frame (800 x 600): wall {d:.1} us, thread cpu {d:.1} us; builds {d}";
    refused = fx.gw.stats.not_shown - refused;
    note(fd, surface ++ unfinished, .{ us[0], us[1], app.builds - builds, app.paints, refused });
    // A mode the window did not finish (not shown) must not run into the next one.
    app.paints = 0;
    try fx.run(&app, seconds(0.3));

    builds = app.builds;
    draws = app.draws;
    refused = fx.gw.stats.not_shown;
    app.toggles = frames;
    fx.ctx.waker.post();
    t = Spent.start();
    try fx.run(&app, Clock(Done){ .t0 = .now(testing.io, .awake), .seconds = 120, .done = done });
    us = t.per(app.builds - builds);
    const widget = "widget frame (one cell): wall {d:.1} us, thread cpu {d:.1} us; draws {d}";
    refused = fx.gw.stats.not_shown - refused;
    note(fd, widget ++ unfinished, .{ us[0], us[1], app.draws - draws, app.toggles, refused });
    app.toggles = 0;

    try fx.run(&app, seconds(0.3));
    const presents = fx.gw.stats.presents;
    t = Spent.start();
    try fx.run(&app, seconds(1));
    us = t.per(1);
    const idle = "idle second: {d} frames, thread cpu {d:.1} us\n";
    note(fd, idle, .{ fx.gw.stats.presents - presents, us[1] });
}

// The canvas of 100,000 rows (`RowsApp`, 6-pixel squares over the window) at 2560 x 1440, the
// camera moving a pixel a frame, through `lcgf_app`'s loop: calling-thread CPU and wall time
// per frame, canvas bytes uploaded per frame, builds, and frames unfinished and not shown,
// appended to the file LCGF_APP_GPU_BENCH names.
test "gpu canvas of 100,000 rows at 2560 x 1440, the camera moving (LCGF_APP_GPU_BENCH)" {
    const display = try displayOrSkip();
    const path = testing.environ.getPosix("LCGF_APP_GPU_BENCH") orelse return error.SkipZigTest;
    const flags: std.os.linux.O = .{ .ACCMODE = .WRONLY, .CREAT = true, .APPEND = true };
    const opened = std.os.linux.open(path, flags, 0o644);
    if (std.os.linux.errno(opened) != .SUCCESS) return error.BenchFile;
    const fd: i32 = @intCast(opened);
    defer _ = std.os.linux.close(fd);
    var fx: Fixture = undefined;
    try fx.openRoom(display, .{ 2560, 1440 }, &.{}, rows_room);
    defer fx.close();
    var app: RowsApp = .init(6, 426);
    try fx.run(&app, seconds(0.5));
    const frames = 300;
    const Done = struct {
        a: *const RowsApp,
        fn stop(d: @This()) bool {
            return d.a.moves == 0;
        }
    };
    const builds = app.builds;
    const presents = fx.gw.stats.presents;
    const bytes = fx.gw.stats.canvas_bytes;
    const refused = fx.gw.stats.not_shown;
    app.moves = frames;
    fx.ctx.waker.post();
    const t = Spent.start();
    const t0: std.Io.Timestamp = .now(testing.io, .awake);
    const clock = Clock(Done){ .t0 = t0, .seconds = 120, .done = .{ .a = &app } };
    try fx.run(&app, clock);
    const shown_n = fx.gw.stats.presents - presents;
    const us = t.per(shown_n);
    const per_frame = (fx.gw.stats.canvas_bytes - bytes) / @max(shown_n, 1);
    note(fd, "device {s}\n", .{fx.gw.x.setup.device.name()});
    const line = "canvas 100k rows, camera moving: {d} frames, wall {d:.1} us, " ++
        "thread cpu {d:.1} us, {d} canvas bytes uploaded a frame; builds {d}; " ++
        "unfinished {d}, not shown {d}\n";
    const refusals = fx.gw.stats.not_shown - refused;
    note(fd, line, .{ shown_n, us[0], us[1], per_frame, app.builds - builds, app.moves, refusals });
}
