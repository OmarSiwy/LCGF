//! lcgf_app on the GPU: the frame loop of a GPU window, written once over a platform's window
//! (`Gpu(P)`), and the application's own GPU drawing in it (`Surface`, `draw`). In: the
//! application's `build`, `draw` and images, and the window's events. Out: frames presented,
//! each drawing again only what changed (docs/plans/window.md, "The contract"):
//!
//!   - a built frame (a widget changed) uploads its rows and redraws its `DrawList.damage`;
//!   - a dirty surface (`Surface.redraw`, or its size) calls `draw` and redraws the surface's
//!     rectangle from the rows already on the GPU: no build, no upload of rows;
//!   - a canvas's camera or palette (`lcgf_app.Canvas.redraw`) redraws the canvas node's
//!     rectangle from the kept list, its uniforms written: no build, no upload of rows;
//!   - nothing changed: no frame.
//!
//! The platform paces the frames in `P.begin` (FIFO, a latency waitable, a display link), so
//! the loop waits on no timer of its own. A frame the presentation engine does not take (a
//! hidden, minimised or blanked window: error.NotShown) is not drawn: the loop then owes the
//! whole window and tries again on the next event or after `retry_seconds`, asleep between.
//!
//! Texture handles, as `Style.texture` sees them: 0 white, k + 1 image k of `App.images`,
//! then the bundled font, the text service's atlas, the canvas label atlas and the surfaces
//! (`handles` in all).
//!
//! ## The window contract
//!
//! `P` is one GPU window over one platform's shell window: src/app/gpu_x11.zig (Vulkan over
//! X11) is the reference. It is comptime (no vtable): every name below is looked up on `P`.
//! The loop owns the bookkeeping (which images changed, which atlas rectangle is dirty, what
//! is owed); `P` owns the device, the swapchain and the shell window, and does what is asked.
//!
//!   const gpu        the build's `lcgf_render.gpu` projection: what `draw` renders with
//!   const Image      an image the window owns: sampled by the UI, or a surface's target
//!   const Frame      one frame being recorded, from `begin` to `present`
//!   const Shell      what `open` opens the GPU over (the shell's window and its display)
//!   const max_textures   texture handles the renderer holds: at least `handles`
//!
//!   fn open(p: *P, shell: Shell, o: Open, handles: u16) !void
//!       The device over the shell window, texture handles 0 to `handles - 1` registered as
//!       white, `o.canvas_rows` and `o.canvas_verts` of canvas room, `o.gpu_bytes` of device
//!       memory for `draw` and `o.staging_bytes` of staging per frame slot. Fails leaving
//!       nothing open (no library, no device: the caller falls back to software).
//!   fn close(p: *P) void            after every `Image` was destroyed
//!   fn waitIdle(p: *P) void         the GPU done with everything submitted
//!
//!   fn createImage(p: *P, kind: ImageKind, size: [2]u32) !Image
//!       `.rgba`: RGBA8, sampled, a copy destination. `.coverage`: one byte a texel, sampled
//!       as white with that byte as alpha. `.target`: `Surface.format`, a render attachment
//!       and sampled, resting shader-readable once `GpuFrame.upload` prepared it.
//!   fn destroyImage(p: *P, img: *Image) void     no frame in flight may sample it
//!   fn extent(img: *const Image) [2]u32
//!   fn bind(p: *P, handle: u16, img: *const Image) void      the UI samples it as `handle`
//!   fn writeNow(p: *P, img: *Image, bytes: []const u8) !void  all of it, waited for
//!   fn targetTexture(img: *const Image) gpu.Texture          a `.target` as `draw` sees it
//!
//!   fn begin(p: *P) !Frame
//!       The next frame at the shell window's size; error.NotShown when the window takes no
//!       frame within the platform's wait (nothing consumed). The frame slot's last frame is
//!       done when it returns.
//!   fn stage(p: *P, f: *Frame, ch: Channel, bytes: u64) ![]u8
//!       Mapped room for `bytes` this frame in channel `ch`'s buffer: once a channel a frame.
//!   fn copy(p: *P, f: *Frame, ch: Channel, at: u64, img: *Image, r: Rect, fresh: bool) void
//!       Records a copy of the staged bytes from `at` into rectangle `r` of `img`, tightly
//!       packed rows; `fresh` when the image's old content may be dropped.
//!   fn gpuFrame(p: *P, f: *Frame) GpuParts      the application's upload phase this frame
//!   fn present(p: *P, f: *Frame, ui: Ui) !void
//!       Draws the UI into the window's picture inside `ui.damage` (everything when the
//!       platform lost it) from `ui.rows`, or from the rows of the last rows given when null,
//!       their canvases' uniforms written again when `ui.canvases`, and presents.
//!   fn kept(p: *const P) ?*const DrawList        the list of the last rows given
//!   fn canvasUploaded(p: *const P) ?usize        canvas bytes the last `present` wrote
//!
//!   fn poll(p: *P, ev: *Events) Polled           the shell's events since the last poll
//!   fn apply(p: *P, platform: *const lcgf.context.Platform) void   cursor, IME, title
//!   fn wait(p: *P, seconds: f32, pace: scheduler.Pace) void        asleep until an event
//!   fn wake(p: *P) void                          from any thread: `wait` returns
//!   fn setBackground(p: *P, color: Color) void   what a resize shows before a frame
//!   fn background(p: *const P) Color
//!
//! The module that holds `P` also has `pub const Loop = Gpu(P)` and `runApp` (`Want`), which
//! app.zig picks per OS and `-Drender` (`gpu_window`).
//!
//! Contents
//!   pub const Open, ImageKind, Channel, Rect, Rows, Ui, GpuParts, Polled
//!   pub fn Gpu(comptime P: type) type
//!     pub const gpu, Surface, GpuFrame, Stats, Run, Window
//!     pub fn loop(comptime App: type, app: *App, gw: *Window, run: Run, clock: anytype) !void
//!     pub fn wake() bool

const std = @import("std");
const lcgf = @import("lcgf");
const text = @import("text.zig");
const page = @import("page.zig");
const app_mod = @import("app.zig");
const context = lcgf.context;
const scheduler = lcgf.scheduler;
const font = lcgf.render_sw_font;
const Region = lcgf.damage.Region;
const Events = lcgf.shell_iface.Events;
const Glyphs = lcgf.render_iface.Glyphs;
const DrawList = lcgf.draw_list.DrawList;
const Quad = lcgf.draw_list.Quad;
const Frame = lcgf.frame.Frame;
const Style = lcgf.types.Style;
const Color = lcgf.types.Color;

/// Surfaces one window shows.
pub const surfaces_max = 16;
/// Images an application may give (app.zig `images_max`).
pub const images_max = 64;
/// Seconds between attempts to draw a window the presentation engine is not showing.
pub const retry_seconds: f32 = 0.5;

pub const handle_font = images_max + 1;
pub const handle_text = images_max + 2;
pub const handle_labels = images_max + 3;
pub const handle_surface = images_max + 4;
/// Texture handles a GPU window registers (`P.open`).
pub const handles = handle_surface + surfaces_max;

/// A GPU window's room (`P.open`).
pub const Open = struct {
    /// Device-local bytes `draw` places its resources in, and staging bytes per frame.
    gpu_bytes: u64 = 64 << 20,
    staging_bytes: u64 = 8 << 20,
    canvas_rows: u32 = 4096,
    canvas_verts: u32 = 4096,
};

/// What an image of the window's is for (`P.createImage`).
pub const ImageKind = enum { rgba, coverage, target };

/// The loop's own texture writes, each a mapped buffer per frame slot (`P.stage`): the
/// application's images, the text service's atlas and the canvas label atlas.
pub const Channel = enum { images, text, labels };

/// Texels of an image, from its top-left corner.
pub const Rect = struct { x: u32 = 0, y: u32 = 0, w: u32, h: u32 };

/// A new list for `P.present` to upload and draw from.
pub const Rows = struct {
    /// Not culled to its damage (`Context.trackDamageWhole`): a later frame may draw any rect
    /// of the window from these rows.
    list: *const DrawList,
    glyphs: Glyphs,
    viewport: [2]f32,
    scale: f32,
};

/// One frame's UI for `P.present`.
pub const Ui = struct {
    /// New rows, or null: those of the last rows given, still alive, drawn again.
    rows: ?Rows,
    /// Logical pixels to draw again; outside it the picture keeps last frame's pixels.
    damage: Region,
    /// Straight RGBA, 0 to 1: each damage rect is cleared to it before the list draws.
    clear: [4]f32,
    /// With no new rows: the kept list's canvas rows changed (`Canvas.redraw`).
    canvases: bool = false,
};

/// What `P.gpuFrame` gives the application's `draw`, in `lcgf_render.gpu` terms.
pub fn GpuParts(comptime gpu: type) type {
    return struct { device: gpu.Device, arena: *gpu.Arena, upload: gpu.Upload };
}

/// What app.zig's `run` gives a GPU window's `runApp(App, app, want, clock) !bool`, which opens
/// the platform's shell window and the GPU over it and runs `Gpu(P).loop` there until the
/// window closes: false when it could not (no server, no device), nothing left open, so `run`
/// opens the software window instead.
pub const Want = struct {
    title: []const u8,
    /// The window's content, logical pixels.
    size: [2]u32,
    room: Open,
    /// Where the platform has them (X11): the display, and the authority cookie file's bytes.
    display: []const u8 = "",
    auth: []const u8 = "",
    /// Where the platform has them (Wayland): the compositor's socket and its directory.
    wayland: []const u8 = "",
    runtime_dir: []const u8 = "/tmp",
    ctx: *context.Context,
    tw: *text.Window,
    /// Rows for the frame's glyph quads in the bundled font.
    quads: []Quad,
    first: []u32,
    count: []u32,
};

/// The shell's events since the last poll (`P.poll`).
pub const Polled = enum {
    /// The window closed, or its connection broke.
    closed,
    ready,
    /// As `ready`, and the shell lost the window's pixels (an Expose): the picture has them.
    exposed,
};

/// What `Surface.redraw` wakes: the running GPU window's loop, whichever platform it is on.
const Waker = struct { ptr: *anyopaque, wake: *const fn (*anyopaque) void };

/// The surfaces of a build's GPU windows and what `draw` takes, by the GPU projection and the
/// image type alone: every window of one back end (Vulkan over X11 or over Wayland) shares one
/// `lcgf_app.Surface`.
fn Shared(comptime gpu: type, comptime Image: type) type {
    return struct {
        /// A rectangle of the window this program draws itself, through `gpu`: a texture of
        /// its own, shown as an ordinary quad at its node's place in paint order
        /// (`Style.texture`), so widgets over it cover it and its node's clip, radius and
        /// opacity apply. Lives in the application's state, as a `<canvas>` lives in a page:
        ///
        ///     const node = s.plot.node(f, .from("plot"), .{ .size = .{ .fill, .fill } });
        ///     if (f.interact(node, .{ .drag = true }).dragged) s.plot.redraw();
        ///
        /// The texture follows the node's size in physical pixels, growing in steps of
        /// `step_px` so a resize does not make one a pixel; `size` is the part in use.
        pub const Surface = struct {
            /// What `draw` renders into: `format`, render attachment, sampled by the UI. Valid
            /// in `draw` once `size` is not zero; a new texture when the node outgrows it.
            texture: gpu.Texture = undefined,
            /// Physical pixels of `texture` the node shows, from the last layout; zero before.
            size: [2]u32 = .{ 0, 0 },
            /// `draw` must draw it this frame: new, resized, or `redraw` was called before.
            dirty: bool = true,
            /// `redraw` was called: dirty in the next frame (a call in `draw` is for the next).
            requested: bool = false,
            /// The node's rectangle in logical pixels, from the last layout.
            rect: [4]f32 = .{ 0, 0, 0, 0 },
            /// Where the window keeps it (set by `node`), its node, and its image.
            slot: ?u8 = null,
            node_ix: u32 = 0,
            image: ?Image = null,

            pub const format: gpu.TextureFormat = .rgba8_unorm;
            pub const step_px = 256;

            /// The node that shows the surface: `style` with the surface as its texture, its
            /// fill white unless it has one (a fill tints the texture). Registers the surface
            /// with the window. Panics past `surfaces_max` surfaces. Not `live`: `style` as it
            /// is, its fill painted.
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

            /// Whether the window draws its surfaces: it is on the GPU. Not in the software
            /// window a GPU build falls back to (`LCGF_RENDER=sw`, no display or no device),
            /// where `draw` is never called and the node paints its style's fill: show
            /// something else in its place.
            pub fn live(s: *const Surface) bool {
                _ = s;
                return registry.shell != null;
            }

            /// Asks for a frame that calls `draw` and shows the surface's new pixels, with no
            /// `build`: it wakes the window's loop, not the context. On the UI thread (in
            /// `build` or `draw`, or between frames); another thread wakes the shell itself.
            pub fn redraw(s: *Surface) void {
                s.requested = true;
                if (registry.shell) |w| w.wake(w.ptr);
            }
        };

        /// What the application's `pub fn draw(*App, *GpuFrame) !void` draws with. It is called
        /// in a frame in which a surface is dirty (`Surface.dirty`), never for a widget.
        pub const GpuFrame = struct {
            device: gpu.Device,
            /// Device-local memory for the application's buffers, textures and bind groups
            /// (`Options.gpu_bytes`), kept while the device lives.
            arena: *gpu.Arena,
            /// The device is new (the first `draw`): make the pipelines and resources in
            /// `arena`.
            fresh: bool,
            /// The frame's one upload phase (`writeBuffer`, `writeTexture`).
            upload: gpu.Upload,
            finished: ?gpu.Encoder = null,

            /// Ends the upload phase and gives the frame's encoder, for the application's
            /// passes. The loop ends the phase itself when `draw` never calls this.
            pub fn encoder(g: *GpuFrame) gpu.Encoder {
                if (g.finished) |e| return e;
                g.finished = g.upload.finish();
                return g.finished.?;
            }
        };

        /// The program's surfaces by slot, registered by `Surface.node`.
        // ponytail: module state, as app.zig's buffers are: one window a program.
        pub const registry = struct {
            pub var list: [surfaces_max]?*Surface = @splat(null);
            /// The window whose loop `Surface.redraw` wakes.
            pub var shell: ?Waker = null;
            /// The surface's node was in the last frame built.
            pub var built: [surfaces_max]bool = @splat(false);

            pub fn add(s: *Surface) u8 {
                for (&list, 0..) |*l, k| if (l.* == null) {
                    l.* = s;
                    s.slot = @intCast(k);
                    return @intCast(k);
                };
                @panic("lcgf_app: more than surfaces_max surfaces in one window");
            }
        };
    };
}

/// The GPU loop over platform window `P` (the module doc's contract).
// tidy: allow-fn(function-too-long) the loop's types and steps, one namespace per platform
pub fn Gpu(comptime P: type) type {
    comptime std.debug.assert(handles <= P.max_textures);
    const Image = P.Image;
    return struct {
        /// `lcgf_render.gpu` on this build's back end: what `draw` renders a surface with.
        pub const gpu = P.gpu;
        pub const Platform = P;

        const shared = Shared(P.gpu, P.Image);
        pub const Surface = shared.Surface;
        pub const GpuFrame = shared.GpuFrame;
        const registry = shared.registry;

        /// What a window did, for tests and measurements.
        pub const Stats = struct {
            builds: u32 = 0,
            draws: u32 = 0,
            presents: u32 = 0,
            not_shown: u32 = 0,
            /// Bytes of UI rows (quads and glyph quads) uploaded.
            row_bytes: u64 = 0,
            /// Frames that drew a canvas again for its `lcgf_app.Canvas.redraw`, no build.
            canvas_redraws: u32 = 0,
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
            ctx: *context.Context,
            tw: *text.Window,
            /// Rows for the frame's glyph quads in the bundled font.
            quads: []Quad,
            first: []u32,
            count: []u32,
        };

        /// A GPU window: the platform's (`p`), the textures the UI samples and the frame's
        /// state. Filled in place (the platform's renderer points at its device).
        // tidy: allow(bool-heavy-struct) one flag per texture the loop keeps, read where written
        pub const Window = struct {
            p: P,
            images: [images_max]?Image,
            generations: [images_max]u32,
            sizes: [images_max][2]u32,
            image_len: u32,
            images_known: bool,
            font: Image,
            text: ?Image,
            /// The text service's atlas has to be written whole (new, or a frame not shown).
            text_whole: bool,
            /// The canvas label atlas (`text.Window.labels`), and whether it has to be
            /// written whole.
            labels: ?Image,
            labels_whole: bool,
            text_dirty: ?text.Frame,
            /// Damage not yet presented, the rows of the last frame built when not uploaded.
            owed: Region,
            rows: ?Rows,
            stats: Stats,
            /// The context of the loop running in the window, which a surface's new size
            /// rebuilds.
            ctx: ?*context.Context,
            /// Frames to give up on as error.NotShown before `begin`: what a hidden window
            /// does, for a test on a server that shows every window.
            refuse: u32,
            /// A composing application's region and the input its last frame was built from.
            paging: page.Paging,

            /// The GPU over `shell`, every texture handle registered (white until used) and
            /// the bundled font written. Fails as `P.open` does, leaving nothing open.
            pub fn open(gw: *Window, shell: P.Shell, o: Open) !void {
                std.debug.assert(o.staging_bytes > 0);
                try gw.p.open(shell, o, handles);
                errdefer gw.p.close();
                gw.font = try gw.p.createImage(.coverage, .{ font.width, font.height });
                errdefer gw.p.destroyImage(&gw.font);
                try gw.p.writeNow(&gw.font, font.image.alpha8);
                gw.p.bind(handle_font, &gw.font);
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
                app_mod.canvases.forget();
            }

            /// Waits for the device, then lets go of everything `open` and the frames made,
            /// the surfaces' textures too (a surface shown again later gets a new one).
            pub fn close(gw: *Window) void {
                gw.p.waitIdle();
                for (&registry.list) |*l| if (l.*) |s| {
                    if (s.image) |*img| gw.p.destroyImage(img);
                    s.* = .{};
                    l.* = null;
                };
                registry.built = @splat(false);
                registry.shell = null;
                app_mod.canvases.forget();
                for (&gw.images) |*img| if (img.*) |*i| gw.p.destroyImage(i);
                if (gw.text) |*t| gw.p.destroyImage(t);
                if (gw.labels) |*t| gw.p.destroyImage(t);
                gw.p.destroyImage(&gw.font);
                gw.p.close();
            }
        };

        /// The window's frames until it closes or `clock.left()` is not above 0: the
        /// contract's rows.
        // tidy: allow-fn(large-generic-function) one instance per App
        // tidy: allow-fn(function-too-long) the loop's steps in order, each a few lines
        pub fn loop(comptime App: type, app: *App, gw: *Window, run: Run, clock: anytype) !void {
            std.debug.assert(run.first.len == run.count.len);
            const w = &gw.p;
            const ctx = run.ctx;
            const follows = @hasField(App, "theme") and
                @FieldType(App, "theme") == lcgf.widgets_base.Theme;
            var styled: ?lcgf.input.Input.Appearance = null;
            var ev: Events = .{};
            var waiting_since_not_shown = false;
            gw.ctx = ctx;
            registry.shell = .{ .ptr = w, .wake = wakeP };
            // tidy: allow(unbounded-loop) the event loop: it ends when the window closes or
            // `clock` says
            while (true) {
                const polled = w.poll(&ev);
                if (polled == .closed) break;
                const exposed = polled == .exposed;
                if (follows and !std.meta.eql(styled, ev.in.appearance)) {
                    styled = ev.in.appearance;
                    app.theme = lcgf.theme.widgets(&lcgf.theme.forAppearance(ev.in.appearance));
                    w.setBackground(app.theme.panel);
                }
                if (comptime page.composes(App)) {
                    if (gw.paging.wants(ctx, &ev.in)) buildPage(App, app, gw, run, &ev);
                } else if (ctx.needsFrame(&ev.in)) build(App, app, gw, run, &ev);
                const owed = anyDirty() or app_mod.canvases.owed();
                const due = gw.rows != null or owed or exposed or waiting_since_not_shown;
                if (due and (w.kept() != null or gw.rows != null)) {
                    if (present(App, app, gw)) |_| {
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
                // The platform's `begin` paces the next frame.
                if ((anyDirty() or app_mod.canvases.owed()) and !waiting_since_not_shown) continue;
                var s = @min(scheduler.wake(ctx, &ev.in), left);
                if (waiting_since_not_shown) s = @min(s, retry_seconds);
                // `.display` would add the shell's refresh timer: `begin` paces instead.
                const pace = scheduler.pace(ctx);
                w.wait(s, if (pace == .display) .once else pace);
            }
        }

        /// Wakes the GPU window's loop for a `Canvas.redraw`: false when none is running.
        pub fn wake() bool {
            const w = registry.shell orelse return false;
            w.wake(w.ptr);
            return true;
        }

        // ---- private ----

        fn wakeP(ptr: *anyopaque) void {
            const w: *P = @ptrCast(@alignCast(ptr));
            w.wake();
        }

        /// One built frame: the application's `build`, layout and paint, the glyphs placed,
        /// the surfaces' rectangles from the layout, and the damage and rows owed.
        // tidy: allow-fn(large-generic-function) one instance per App
        fn build(comptime App: type, app: *App, gw: *Window, run: Run, ev: *const Events) void {
            std.debug.assert(ev.in.scale > 0);
            const ctx = run.ctx;
            var f = ctx.begin(&ev.in);
            registry.built = @splat(false);
            app_mod.canvases.forget();
            app.build(&f, ev);
            const out = run.tw.end(&f);
            gw.p.apply(&out.platform);
            gw.stats.builds += 1;
            const scale = ev.in.scale;
            const placed: ?text.Frame = if (run.tw.on()) run.tw.glyphs(ctx, &out, scale) else null;
            const glyphs = textGlyphs(gw, run, out.draw, placed);
            owe(gw, run, &out, out.draw, glyphs, .{ 0, 0 }, &ev.in);
            oweImages(App, app, gw, out.draw);
        }

        /// `build` for an App that composes its frames into a page (src/app/page.zig): the
        /// frame is built in the page's region, and the window draws the application's list.
        // tidy: allow-fn(large-generic-function) one instance per App
        fn buildPage(comptime App: type, app: *App, gw: *Window, run: Run, ev: *const Events) void {
            std.debug.assert(ev.in.scale > 0);
            const ctx = run.ctx;
            registry.built = @splat(false);
            app_mod.canvases.forget();
            const b = page.build(App, app, &gw.paging, ctx, run.tw, ev);
            gw.p.apply(&b.out.platform);
            gw.stats.builds += 1;
            const list = b.composed.draw;
            const scale = ev.in.scale;
            const sides = b.composed.texts;
            const placed: ?text.Frame =
                if (run.tw.on()) run.tw.glyphsOf(ctx, list, sides, scale) else null;
            owe(gw, run, &b.out, list, textGlyphs(gw, run, list, placed), b.origin, &ev.in);
            oweImages(App, app, gw, list);
        }

        /// The quads of `list` that show an image whose generation moved since it was last
        /// written, owed: the image's pixels changed, which no node's hash sees. A new count
        /// of images, a new size or a first image owes the whole window.
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
                const changed = gw.generations[k] != img.generation;
                moved |= @as(u128, @intFromBool(changed)) << @intCast(k + 1);
            }
            lcgf.damage.addTextures(list, moved, &gw.owed);
        }

        /// The glyphs of `list` with the handles they sample: the service's `placed`, its atlas
        /// owed an upload, or the bundled font's.
        fn textGlyphs(gw: *Window, run: Run, list: *const DrawList, placed: ?text.Frame) Glyphs {
            if (placed) |p| {
                var glyphs = p.glyphs;
                glyphs.texture = @fromBackingInt(handle_text);
                // Canvas glyphs sample the label atlas when the App has one, else the font's.
                const canvas_handle: u16 = if (p.labels != null) handle_labels else handle_font;
                glyphs.canvas = @fromBackingInt(canvas_handle);
                gw.text_dirty = p;
                return glyphs;
            }
            var glyphs = text.bitmapGlyphs(run.ctx, list, run.quads, run.first, run.count);
            glyphs.texture = @fromBackingInt(handle_font);
            return glyphs;
        }

        /// The rows of `list` to draw, its damage owed, and the surfaces of frame `out`
        /// placed: their nodes' rects moved by `origin`, the frame's (0, 0) in the window.
        // tidy: allow(too-many-parameters) one frame's parts, from either build
        fn owe(
            gw: *Window,
            run: Run,
            out: *const context.Output,
            list: *const DrawList,
            glyphs: Glyphs,
            origin: [2]f32,
            in: *const lcgf.input.Input,
        ) void {
            std.debug.assert(in.scale > 0);
            app_mod.sayCustom(list);
            gw.rows = .{
                .list = list,
                .glyphs = glyphs,
                .viewport = in.viewport,
                .scale = in.scale,
            };
            unite(&gw.owed, &list.damage);
            for (registry.list, registry.built) |l, built| if (l) |s| if (built) {
                const r = out.tree.rect(s.node_ix);
                const o = origin;
                s.rect = .{ r.x0 + o[0], r.y0 + o[1], r.x1 + o[0], r.y1 + o[1] };
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

        /// Draws and presents the frame owed: textures written, `draw` for dirty surfaces, the
        /// UI inside the damage and the surfaces' rectangles. error.NotShown: nothing drawn or
        /// consumed.
        // tidy: allow-fn(large-generic-function) one instance per App
        fn present(comptime App: type, app: *App, gw: *Window) !void {
            std.debug.assert(gw.ctx != null);
            const p = &gw.p;
            if (gw.refuse > 0) {
                gw.refuse -= 1;
                return error.NotShown;
            }
            var f = try p.begin();
            if (@hasDecl(App, "images")) {
                // A frame built since the last present owed the images' quads (`oweImages`);
                // a change with no frame built (a surface's frame) is drawn whole.
                const built = gw.rows != null;
                if (try writeImages(gw, &f, app.images()) and !built) gw.owed = .everything;
            }
            if (gw.text_dirty) |placed| {
                const t: Atlas = .{
                    .image = &gw.text,
                    .whole = &gw.text_whole,
                    .channel = .text,
                    .handle = handle_text,
                };
                _ = try writeAtlas(gw, &f, placed.atlas, placed.dirty, t);
                if (placed.labels) |l| {
                    const at: Atlas = .{
                        .image = &gw.labels,
                        .whole = &gw.labels_whole,
                        .channel = .labels,
                        .handle = handle_labels,
                    };
                    gw.stats.label_bytes += try writeAtlas(gw, &f, l, placed.labels_dirty, at);
                }
            }
            for (registry.list) |l| if (l) |s| {
                s.dirty = s.dirty or s.requested;
                s.requested = false;
            };
            if (anyDirty()) {
                const parts = p.gpuFrame(&f);
                var gf: GpuFrame = .{
                    .device = parts.device,
                    .arena = parts.arena,
                    .fresh = gw.stats.draws == 0,
                    .upload = parts.upload,
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
            // The canvases moved since their frame was built: in the list the window draws from.
            const kept = if (gw.rows) |r| r.list else p.kept();
            const moved = if (kept) |l| moveCanvases(&gw.owed, l) else false;
            gw.stats.canvas_redraws += @intFromBool(moved and gw.rows == null);
            const bg = p.background();
            const clear: [4]f32 = .{ unit(bg.r), unit(bg.g), unit(bg.b), 1 };
            const ui: Ui = .{
                .rows = gw.rows,
                .damage = gw.owed,
                .clear = clear,
                .canvases = moved,
            };
            try p.present(&f, ui);
            // The canvases were written (new rows, or a canvas moved): what they wrote is this
            // frame's, and the rows uploaded are clean (the host clears them after `prepare`).
            if (gw.rows != null or moved) if (p.canvasUploaded()) |bytes| {
                gw.stats.canvas_bytes += bytes;
                if (kept) |l| clearCanvases(l);
            };
            gw.stats.presents += 1;
            gw.stats.damage = gw.owed;
            gw.stats.whole += @intFromBool(std.meta.eql(gw.owed, Region.everything));
            gw.owed = .empty;
            gw.rows = null;
            gw.text_dirty = null;
        }

        fn anyDirty() bool {
            for (registry.list, registry.built) |l, built| if (l) |s| {
                if (built and (s.dirty or s.requested)) return true;
            };
            return false;
        }

        /// The application's images whose generation, size or count changed, written in
        /// frame `f` and registered. True when any did, never on the first frame (drawn whole
        /// anyway).
        // tidy: allow-fn(large-generic-function) one instance per App's image type
        fn writeImages(gw: *Window, f: *P.Frame, images: anytype) !bool {
            std.debug.assert(images.len <= images_max);
            const p = &gw.p;
            var changed = false;
            var bytes: u64 = 0;
            for (images, 0..) |img, k| {
                if (gw.images[k] != null and gw.generations[k] == img.generation and
                    std.mem.eql(u32, &gw.sizes[k], &img.size)) continue;
                bytes += @as(u64, img.size[0]) * img.size[1] * texelBytes(img);
            }
            if (bytes == 0 and images.len == gw.image_len and gw.images_known) return false;
            const staged = try p.stage(f, .images, @max(bytes, 4));
            var at: u64 = 0;
            for (images, 0..) |img, k| {
                const same_size = std.mem.eql(u32, &gw.sizes[k], &img.size);
                const same = gw.generations[k] == img.generation and same_size;
                if (gw.images[k] != null and same) continue;
                changed = true;
                if (gw.images[k] == null or !same_size) {
                    // Frames in flight may sample the old image.
                    p.waitIdle();
                    if (gw.images[k]) |*old| p.destroyImage(old);
                    const kind: ImageKind = if (texelBytes(img) == 1) .coverage else .rgba;
                    gw.images[k] = try p.createImage(kind, img.size);
                    p.bind(@intCast(k + 1), &gw.images[k].?);
                }
                const texels = @as(usize, img.size[0]) * img.size[1];
                const n = texels * texelBytes(img);
                const rgba = std.mem.sliceAsBytes(img.pixels);
                const src = if (n == texels) alphaOf(img)[0..texels] else rgba[0..n];
                @memcpy(staged[@intCast(at)..][0..n], src);
                const region: Rect = .{ .w = img.size[0], .h = img.size[1] };
                p.copy(f, .images, at, &gw.images[k].?, region, true);
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

        /// Where a coverage atlas lives on the GPU: its image, whether it has to be written
        /// whole, its channel and its texture handle.
        const Atlas = struct { image: *?Image, whole: *bool, channel: Channel, handle: u16 };

        /// Atlas `a`'s image made the first time, then its changed rectangle `dirty` written
        /// (all of it when `at.whole`), in frame `f`. Returns the bytes written.
        fn writeAtlas(
            gw: *Window,
            f: *P.Frame,
            a: *const CoverageAtlas,
            dirty: ?CoverageAtlas.Upload,
            at: Atlas,
        ) !u64 {
            std.debug.assert(a.pixels.len >= @as(usize, a.w) * a.h);
            const p = &gw.p;
            if (at.image.* == null) {
                at.image.* = try p.createImage(.coverage, .{ a.w, a.h });
                p.bind(at.handle, &at.image.*.?);
                at.whole.* = true;
            }
            const whole: Rect = .{ .w = a.w, .h = a.h };
            const changed: ?Rect =
                if (dirty) |v| .{ .x = v.x, .y = v.y, .w = v.w, .h = v.h } else null;
            const r: Rect = if (at.whole.*) whole else changed orelse return 0;
            if (r.w == 0 or r.h == 0) return 0;
            const bytes = @as(u64, r.w) * r.h;
            const staged = try p.stage(f, at.channel, bytes);
            for (0..r.h) |y| {
                const src = a.pixels[(r.y + y) * a.w + r.x ..][0..r.w];
                @memcpy(staged[y * r.w ..][0..r.w], src);
            }
            p.copy(f, at.channel, 0, &at.image.*.?, r, at.whole.*);
            at.whole.* = false;
            return bytes;
        }

        /// Gives `s` a texture at least its size, in steps of `Surface.step_px`, ready to
        /// sample (through `upload`, the frame's upload phase) and registered.
        fn fitSurface(gw: *Window, s: *Surface, upload: *gpu.Upload) !void {
            std.debug.assert(s.slot != null);
            if (s.size[0] == 0 or s.size[1] == 0) return;
            const p = &gw.p;
            if (s.image) |*img| {
                const e = P.extent(img);
                if (e[0] >= s.size[0] and e[1] >= s.size[1]) return;
            }
            // Frames in flight may sample the old texture.
            p.waitIdle();
            if (s.image) |*old| p.destroyImage(old);
            const step = Surface.step_px;
            const size: [2]u32 = .{
                std.mem.alignForward(u32, s.size[0], step),
                std.mem.alignForward(u32, s.size[1], step),
            };
            s.image = try p.createImage(.target, size);
            s.texture = P.targetTexture(&s.image.?);
            upload.prepare(s.texture);
            p.bind(handle_surface + @as(u16, s.slot.?), &s.image.?);
            // The node's `uv` was for the old texture.
            if (gw.ctx) |ctx| ctx.waker.post();
        }
    };
}

/// A coverage atlas (the text service's, the labels'), as `Gpu.writeAtlas` writes it.
const CoverageAtlas = lcgf.raster_atlas.Atlas;

fn unit(v: u8) f32 {
    return @as(f32, @floatFromInt(v)) / 255;
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

/// Writes each `lcgf_app.Canvas` that asked for a redraw into `list`'s canvas row of its node
/// (the row whose palette is the canvas's own), and owes that node's rectangle: the list stays
/// the one the renderer draws, its rows on the GPU, with the new camera. Whether one moved.
fn moveCanvases(owed: *Region, list: *const DrawList) bool {
    std.debug.assert(list.cmd_len <= list.cmd.kind.len);
    var moved = false;
    for (app_mod.canvases.list) |l| if (l) |v| if (v.requested) {
        v.requested = false;
        for (0..list.cmd_len) |i| {
            const k = switch (list.command(@intCast(i))) {
                .canvas => |k| k,
                else => continue,
            };
            const row = &list.canvases[k];
            if (row.palette != &v.palette) continue;
            row.camera = v.camera;
            const node = list.customs[k];
            owed.add(.{
                @max(node.rect[0], node.clip[0]),
                @max(node.rect[1], node.clip[1]),
                @min(node.rect[2], node.clip[2]),
                @min(node.rect[3], node.clip[3]),
            });
            moved = true;
        }
    };
    return moved;
}

/// Every rect of `from` added to `to`.
fn unite(to: *Region, from: *const Region) void {
    for (0..lcgf.damage.max_rects) |k| to.add(from.rect(@intCast(k)));
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
