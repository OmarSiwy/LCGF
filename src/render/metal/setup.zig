//! A Metal setup for an application that brings no device of its own: the system default
//! device and its queue, a CAMetalLayer configured for it, the renderer, and the frames in
//! flight. `Setup` draws each frame whole into the drawable (the iOS shell's, moved from it);
//! `Window` keeps a picture, as src/render/vk/setup.zig's `Window` does on Vulkan. An
//! application that owns its Metal objects uses `Renderer` directly instead.
//!
//!     var g = try Setup.init(layer);          // the view's CAMetalLayer
//!     g.draw(&draw, glyphs, viewport, scale, clear); // per frame
//!     g.deinit();
//!
//! The window keeps its picture: a texture of its own, in the layer's format and of its
//! drawable size, that holds what the window shows between frames. A frame draws the UI into
//! the picture only inside its damage, from rows that stay in the renderer's shared buffer
//! until a new list replaces them, then copies the picture to the drawable
//! (docs/plans/window.md, "How a frame is drawn"):
//!
//!     var w = try Window.init(size, scale, .{});
//!     w.layer.attach(view);
//!     // per frame, inside an objc.Pool, in one call:
//!     try w.draw(list, glyphs, viewport, scale, clear);
//!     // or in two, with the application's own work into f.cmd between them:
//!     const f = try w.begin(viewport, scale);
//!     w.present(&f, .{ .rows = rows, .damage = list.damage, .clear = clear });
//!     w.deinit();

const std = @import("std");
const lcgf = @import("lcgf");
const objc = @import("objc.zig");
const mtl = @import("mtl.zig");
const msl = @import("msl.zig");
const device = @import("device.zig");
const pipeline = @import("pipeline.zig");
const presenting = @import("present.zig");
const renderer = @import("renderer.zig");
const texture = @import("texture.zig");
const DrawList = lcgf.draw_list.DrawList;
const Quad = lcgf.draw_list.Quad;
const Region = lcgf.damage.Region;
const max_rects = lcgf.damage.max_rects;
const Glyphs = renderer.Glyphs;
const Gfx = renderer.CanvasRenderer;
const Id = objc.Id;
const msg = objc.msg;

pub const Error = device.Error || renderer.Error;

pub const Setup = struct {
    dev: device.Device,
    layer: device.Layer,
    gfx: renderer.Renderer,
    frames: presenting.Frames,

    /// Over `layer`, an existing CAMetalLayer (on iOS the view's own, from `layerClass`),
    /// configured as `Layer.init` would: BGRA8, framebuffer only, opaque.
    pub fn init(layer: Id) Error!Setup {
        var dev = try device.Device.init();
        errdefer dev.deinit();
        msg(void, layer, "setDevice:", .{dev.device});
        msg(void, layer, "setPixelFormat:", .{mtl.PixelFormat.bgra8_unorm});
        msg(void, layer, "setFramebufferOnly:", .{@as(objc.BOOL, true)});
        msg(void, layer, "setOpaque:", .{@as(objc.BOOL, true)});
        var gfx = try renderer.Renderer.init(dev.device, .{});
        errdefer gfx.deinit();
        return .{
            .dev = dev,
            .layer = .{ .layer = layer, .format = .bgra8_unorm },
            .gfx = gfx,
            .frames = .init(dev.queue, gfx.desc.frames_in_flight),
        };
    }

    pub fn deinit(g: *Setup) void {
        g.frames.deinit();
        g.gfx.deinit();
        g.dev.deinit();
    }

    /// Draws `draw` into the layer's next drawable, cleared to `clear`, and presents it. The
    /// layer follows `viewport` (logical pixels) at `scale`. False when there was no drawable and
    /// the frame was skipped.
    pub fn draw(g: *Setup, list: *const DrawList, glyphs: renderer.Glyphs, viewport: [2]f32, scale: f32, clear: [4]f64) bool {
        _ = g.layer.resize(viewport, scale);
        const cmd = g.frames.begin();
        g.gfx.prepare({}, list, glyphs, viewport, scale);
        const drawable = presenting.nextDrawable(g.layer.layer) orelse return false;
        const pass = presenting.beginPass(cmd, presenting.drawableTexture(drawable), clear);
        g.gfx.render(pass, list);
        presenting.endPass(pass);
        g.frames.present(cmd, drawable, null);
        return true;
    }
};

/// A window's Metal: the device, its layer, the renderer with the canvas pipeline, the frames
/// in flight and the picture. One window each: the rows kept are its renderer's.
pub const Window = struct {
    dev: device.Device,
    /// The window's CAMetalLayer, owned: attach it to the view (`Layer.attach`). Not
    /// framebuffer-only, as the picture is copied into its drawables.
    layer: device.Layer,
    gfx: Gfx,
    frames: presenting.Frames,
    /// The stock quad pipeline without blending: what clears a damage rect to `Ui.clear`.
    clear: Id,
    /// What the window shows, kept between frames, the layer's drawable size; null before the
    /// first `begin`.
    picture: ?Id = null,
    /// The picture holds nothing yet (new, or made again at a new size): the next `present`
    /// draws all of it, whatever damage it is given.
    lost: bool = true,

    /// Canvas instance rows and polygon vertices the renderer keeps on the GPU
    /// (`renderer.Desc.canvas_rows`, `canvas_verts`); none: canvases draw nothing.
    pub const Canvas = struct { rows: u32 = 0, verts: u32 = 0 };

    /// error.NotShown: the layer gave no drawable (`nextDrawable` waits at most a second, then
    /// answers nil: a hidden, minimised or occluded window, whose drawables the compositor
    /// keeps). Nothing was drawn, the picture and the damage owed are as they were: wait for
    /// an event and try again. A shell that can tell the window is not visible says so before
    /// asking (the macOS shell's `shown`), so a hidden window never waits that second.
    /// error.TextureFailed: the picture could not be made at the new size.
    pub const FrameError = error{NotShown} || texture.Error;

    /// A frame between `begin` and `present`: its command buffer, outside any encoder, and the
    /// drawable it presents. An application encodes its own uploads and passes into `cmd`
    /// before `present` (an `lcgf_render.gpu` `Upload.beginStaged` on it, then its passes),
    /// and ends every encoder it opened.
    pub const Frame = struct { cmd: Id, drawable: Id };

    /// What `present` draws into the picture.
    pub const Ui = struct {
        /// A new list to upload and draw from, or null: the list of the last `rows` given is
        /// unchanged and still alive, and its rows are drawn again with no upload.
        rows: ?Rows,
        /// Logical pixels to draw again: the list's `damage`, with any rect of the
        /// application's added. Ignored (everything is drawn) while the picture is `lost`.
        /// Outside it the picture keeps last frame's pixels.
        damage: Region,
        /// Straight RGBA, 0 to 1: each damage rect is set to it before the list draws.
        clear: [4]f32,
        /// With no new `rows`: the kept list's canvas rows changed (a camera, a palette, an
        /// instance's rows), so their uniforms and dirty rows are written again, the list's
        /// quads not. Implied by `rows`.
        canvases: bool = false,
    };

    pub const Rows = struct {
        /// Not culled to its damage (`Context.trackDamageWhole`, or no damage tracking): a
        /// later frame may draw any rect of the window from these rows.
        list: *const DrawList,
        glyphs: Glyphs,
        viewport: [2]f32,
        scale: f32,
    };

    /// The system default device, a layer of `size` logical pixels at `scale`, and the
    /// renderer. `objc.load` must have succeeded. Fails as `Device.init` (no device) or
    /// `Renderer.init` (a pipeline or buffer the device refused) do, leaving nothing made.
    pub fn init(size: [2]f32, scale: f32, canvas: Canvas) Error!Window {
        std.debug.assert(scale > 0);
        var dev = try device.Device.init();
        errdefer dev.deinit();
        var layer: device.Layer = .init(&dev, .{ .size = size, .scale = scale });
        errdefer layer.deinit();
        msg(void, layer.layer, "setFramebufferOnly:", .{@as(objc.BOOL, false)});
        const desc: renderer.Desc = .{
            .canvas_rows = canvas.rows,
            .canvas_verts = canvas.verts,
        };
        var gfx: Gfx = try .init(dev.device, desc);
        errdefer gfx.deinit();
        const unblended: pipeline.Desc = .{ .format = layer.format, .blend = false };
        const clear = try pipeline.quad(dev.device, msl.stock, unblended);
        std.debug.assert(gfx.desc.frames_in_flight <= presenting.max_in_flight);
        return .{
            .dev = dev,
            .layer = layer,
            .gfx = gfx,
            .frames = .init(dev.queue, gfx.desc.frames_in_flight),
            .clear = clear,
        };
    }

    /// Waits for every frame in flight, then lets go of everything `init` and the frames made.
    pub fn deinit(w: *Window) void {
        w.frames.deinit();
        if (w.picture) |p| objc.release(p);
        objc.release(w.clear);
        w.gfx.deinit();
        w.layer.deinit();
        w.dev.deinit();
    }

    /// `begin` and `present` in one call, for a host with nothing of its own to draw: uploads
    /// `list` and draws it inside `list.damage` (all of the window unless the context tracks
    /// damage), each rect set to `clear` first.
    // tidy: allow(line-too-long) the API index reads one-line signatures
    pub fn draw(w: *Window, list: *const DrawList, glyphs: Glyphs, viewport: [2]f32, scale: f32, clear: [4]f32) FrameError!void {
        const f = try w.begin(viewport, scale);
        const rows: Rows = .{
            .list = list,
            .glyphs = glyphs,
            .viewport = viewport,
            .scale = scale,
        };
        w.present(&f, .{ .rows = rows, .damage = list.damage, .clear = clear });
    }

    /// Follows `viewport` (logical pixels) at `scale`: a new drawable size makes the picture
    /// again, and the next `present` draws all of it. Then waits for the frame that last used
    /// this frame's slot (`Frames.begin`) and takes the layer's next drawable. Call inside an
    /// objc.Pool that lasts until `present` returns.
    pub fn begin(w: *Window, viewport: [2]f32, scale: f32) FrameError!Frame {
        std.debug.assert(scale > 0);
        const resized = w.layer.resize(viewport, scale);
        if (resized or w.picture == null) {
            const px = w.layer.px;
            const picture = try texture.target(w.dev.device, w.layer.format, px[0], px[1]);
            // A frame in flight holds the old one: its command buffer retains what it uses.
            if (w.picture) |old| objc.release(old);
            w.picture = picture;
            w.lost = true;
        }
        const cmd = w.frames.begin();
        const drawable = presenting.nextDrawable(w.layer.layer) orelse return error.NotShown;
        return .{ .cmd = cmd, .drawable = drawable };
    }

    /// Draws the UI into the picture, copies the picture to `f`'s drawable and presents it.
    /// With `ui.rows` the list is uploaded first; without, the rows of the last list are drawn
    /// again. One pass on the picture that loads it; per damage rect the rect set to `clear`
    /// and the whole list scissored to it: the scissor culls, so the list stays whole.
    /// Asserts that some `rows` were given before.
    pub fn present(w: *Window, f: *const Frame, ui: Ui) void {
        std.debug.assert(ui.rows != null or w.gfx.list != null);
        const picture = w.picture.?;
        if (ui.rows) |r| w.gfx.prepareRows({}, r.list, r.glyphs, r.viewport, r.scale);
        if (ui.rows != null or ui.canvases) w.gfx.prepareCanvases();
        const c = ui.clear;
        const whole: [4]f64 = .{ c[0], c[1], c[2], c[3] };
        const pass = presenting.beginPass(f.cmd, picture, if (w.lost) whole else null);
        var rects: [max_rects]mtl.ScissorRect = undefined;
        const damage = if (w.lost) Region.everything else ui.damage;
        const n = damageRects(damage, w.layer.px, w.gfx.scale, &rects);
        const list = w.gfx.list.?;
        const kept = w.gfx.scissor;
        for (rects[0..n]) |box| {
            w.gfx.scissor = box;
            clearRect(&w.gfx, pass, w.clear, ui.clear);
            w.gfx.render(pass, list);
        }
        w.gfx.scissor = kept;
        presenting.endPass(pass);
        const blit = msg(Id, f.cmd, "blitCommandEncoder", .{});
        const shown = presenting.drawableTexture(f.drawable);
        msg(void, blit, "copyFromTexture:toTexture:", .{ picture, shown });
        msg(void, blit, "endEncoding", .{});
        w.frames.present(f.cmd, f.drawable, null);
        w.lost = false;
    }
};

// ---- private ----

/// The non-empty rects of `damage` as scissors on a target of `size` physical pixels at
/// `scale`, into `out`; how many.
fn damageRects(damage: Region, size: [2]u32, scale: f32, out: *[max_rects]mtl.ScissorRect) u32 {
    std.debug.assert(size[0] > 0);
    std.debug.assert(size[1] > 0);
    var n: u32 = 0;
    for (0..max_rects) |k| {
        const r = Region.scissor(damage.rect(@intCast(k)), size, scale);
        if (r[2] == 0 or r[3] == 0) continue;
        out[n] = .{ .x = r[0], .y = r[1], .width = r[2], .height = r[3] };
        n += 1;
    }
    std.debug.assert(n <= max_rects);
    return n;
}

/// The renderer's scissor set to `rgba` with `clear`, the stock pipeline unblended: one quad
/// over the whole viewport, with the full state a draw sets (iface.zig, "Full state
/// rebinding"). Metal clears only whole attachments, so a rect is drawn instead.
fn clearRect(gfx: *const Gfx, pass: mtl.RenderEncoder, clear: Id, rgba: [4]f32) void {
    std.debug.assert(gfx.texture_count > 0);
    const vp = gfx.globals.viewport;
    // One logical pixel past every edge, so the quad's antialiased edge is outside the scissor.
    const box: [4]f32 = .{ -1, -1, vp[0] + 1, vp[1] + 1 };
    const fill: lcgf.types.Color = .rgba(
        unit8(rgba[0]),
        unit8(rgba[1]),
        unit8(rgba[2]),
        unit8(rgba[3]),
    );
    const q: Quad = .{
        .rect = box,
        .clip = box,
        .params = @splat(0),
        .uv = @splat(0),
        .radii = @splat(0),
        .fill = fill.bitsOf(),
        .border_color = 0,
        .border = 0,
        .opacity = 1,
    };
    const g = std.mem.asBytes(&gfx.globals);
    pass.setPipeline(clear);
    pass.setVertexBytes(std.mem.asBytes(&q), msl.instance_buffer);
    pass.setVertexBytes(g, msl.globals_buffer);
    pass.setFragmentBytes(g, msl.globals_buffer);
    pass.setFragmentTexture(gfx.textures[0], 0);
    pass.setFragmentSampler(gfx.samplers[0], 0);
    const w: f64 = @floatFromInt(gfx.extent[0]);
    const h: f64 = @floatFromInt(gfx.extent[1]);
    pass.setViewport(.{ .x = 0, .y = 0, .width = w, .height = h });
    pass.setScissor(gfx.scissor);
    pass.setRaster();
    pass.drawQuads(1);
}

fn unit8(v: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(v, 0, 1) * 255));
}

const testing = std.testing;
const Fake = objc.Fake;
const conformance = lcgf.render_conformance;
const quad_shader = lcgf.quad_shader;
const draw_quads = "drawPrimitives:vertexStart:vertexCount:instanceCount:";

/// A window over the fake runtime: every object `Fake.object`, the renderer's instance buffer
/// `memory`, a 64 x 48 layer at scale 1 already sized.
fn faked(memory: []u8) Window {
    const desc: renderer.Desc = .{
        .max_quads = conformance.max_quads,
        .max_glyphs = conformance.max_glyphs,
        .frames_in_flight = 3,
    };
    std.debug.assert(memory.len >= memory_bytes);
    var gfx: Gfx = .{ .device = Fake.object, .desc = desc, .contents = memory.ptr };
    gfx.pipelines[0] = Fake.object;
    gfx.material_count = 1;
    gfx.instances = Fake.object;
    gfx.white = Fake.object;
    gfx.sampler = Fake.object;
    _ = gfx.addTexture(Fake.object, null);
    return .{
        .dev = .{ .device = Fake.object, .queue = Fake.object },
        .layer = .{
            .layer = Fake.object,
            .format = .bgra8_unorm,
            .px = .{ 64, 48 },
            .scale = 1,
        },
        .gfx = gfx,
        .frames = .init(Fake.object, desc.frames_in_flight),
        .clear = Fake.object,
    };
}

const memory_bytes = 3 * (conformance.max_quads + conformance.max_glyphs) * quad_shader.stride;

/// The conformance scene of three quads, laid out in 160 x 120.
fn filled(st: *conformance.Storage) *const DrawList {
    st.load(&conformance.scenes[0]);
    return &st.draw;
}

/// `list` as the rows of a 64 x 48 frame at scale 1.
fn rowsOf(list: *const DrawList) Window.Rows {
    return .{ .list = list, .glyphs = .{}, .viewport = .{ 64, 48 }, .scale = 1 };
}

fn rect(x: u32, y: u32, w: u32, h: u32) mtl.ScissorRect {
    return .{ .x = x, .y = y, .width = w, .height = h };
}

test "window: the first frame makes the picture and draws all of it, then presents a copy" {
    if (@import("builtin").os.tag == .macos) return error.SkipZigTest;
    Fake.install();
    defer Fake.uninstall();
    var memory: [memory_bytes]u8 = undefined;
    var w = faked(&memory);
    var st: conformance.Storage = .{};
    const list = filled(&st);
    const f = try w.begin(.{ 64, 48 }, 1);
    try testing.expectEqual(1, Fake.count("newTextureWithDescriptor:"));
    try testing.expect(w.lost);
    const rows = rowsOf(list);
    w.present(&f, .{ .rows = rows, .damage = .empty, .clear = .{ 0, 0, 1, 1 } });
    try testing.expect(!w.lost);
    try testing.expectEqualSlices(u8, list.quadBytes(), memory[0..list.quadBytes().len]);
    // Empty damage, a lost picture: drawn whole, once (one clear quad, then the list).
    try testing.expectEqual(1 + conformance.scenes[0].draws.len, Fake.count(draw_quads));
    try testing.expectEqual(1, Fake.count("setClearColor:"));
    // The pass, then the copy to the drawable, then the present and the commit, in order.
    const pass = Fake.find("renderCommandEncoderWithDescriptor:", 0).?;
    const copy = Fake.find("copyFromTexture:toTexture:", pass).?;
    const shown = Fake.find("presentDrawable:", copy).?;
    _ = Fake.find("commit", shown).?;
}

test "window: no new list uploads nothing and draws each damage rect from the rows kept" {
    if (@import("builtin").os.tag == .macos) return error.SkipZigTest;
    Fake.install();
    defer Fake.uninstall();
    var memory: [memory_bytes]u8 = undefined;
    var w = faked(&memory);
    var st: conformance.Storage = .{};
    const rows = rowsOf(filled(&st));
    var f = try w.begin(.{ 64, 48 }, 1);
    w.present(&f, .{ .rows = rows, .damage = .everything, .clear = .{ 0, 0, 1, 1 } });
    const before = memory;
    const next = w.gfx.next;
    var two: Region = .empty;
    two.add(.{ 0, 0, 8, 8 });
    two.add(.{ 40, 30, 64, 48 });
    Fake.len = 0;
    f = try w.begin(.{ 64, 48 }, 1);
    w.present(&f, .{ .rows = null, .damage = two, .clear = .{ 0, 0, 1, 1 } });
    try testing.expectEqualSlices(u8, &before, &memory);
    try testing.expectEqual(next, w.gfx.next);
    // Per rect a clear quad and the list, each draw scissored; the pass loads the picture.
    try testing.expectEqual(2 * (1 + conformance.scenes[0].draws.len), Fake.count(draw_quads));
    try testing.expectEqual(Fake.count(draw_quads), Fake.count("setScissorRect:"));
    try testing.expectEqual(0, Fake.count("setClearColor:"));
    try testing.expectEqual(0, Fake.count("newTextureWithDescriptor:"));
    // The renderer's own scissor is the whole target again.
    try testing.expectEqual(rect(0, 0, 64, 48), w.gfx.scissor);
    // Nothing damaged: no draw, and the kept picture is presented again.
    Fake.len = 0;
    f = try w.begin(.{ 64, 48 }, 1);
    w.present(&f, .{ .rows = null, .damage = .empty, .clear = .{ 0, 0, 1, 1 } });
    try testing.expectEqual(0, Fake.count(draw_quads));
    try testing.expectEqual(1, Fake.count("presentDrawable:"));
}

test "window: damage rects become scissors in physical pixels, empty ones dropped" {
    var two: Region = .empty;
    two.add(.{ 0, 0, 8, 8 });
    two.add(.{ 40.5, 30, 64, 60 });
    var out: [max_rects]mtl.ScissorRect = undefined;
    const n = damageRects(two, .{ 128, 96 }, 2, &out);
    try testing.expectEqual(2, n);
    try testing.expectEqual(rect(0, 0, 16, 16), out[0]);
    try testing.expectEqual(rect(81, 60, 47, 36), out[1]);
    try testing.expectEqual(0, damageRects(.empty, .{ 128, 96 }, 2, &out));
    try testing.expectEqual(1, damageRects(.everything, .{ 128, 96 }, 2, &out));
    try testing.expectEqual(rect(0, 0, 128, 96), out[0]);
}

test "window: no drawable is error.NotShown, nothing drawn or committed and nothing owed lost" {
    if (@import("builtin").os.tag == .macos) return error.SkipZigTest;
    Fake.install();
    defer Fake.uninstall();
    var memory: [memory_bytes]u8 = undefined;
    var w = faked(&memory);
    Fake.nil = &.{"nextDrawable"};
    try testing.expectError(error.NotShown, w.begin(.{ 64, 48 }, 1));
    try testing.expect(w.lost);
    const picture = w.picture;
    try testing.expectError(error.NotShown, w.begin(.{ 64, 48 }, 1));
    try testing.expectEqual(picture, w.picture);
    try testing.expectEqual(0, Fake.count("commit"));
    try testing.expectEqual(0, Fake.count("renderCommandEncoderWithDescriptor:"));
}

test "window: a resize makes the picture again and draws all of it, whatever the damage" {
    if (@import("builtin").os.tag == .macos) return error.SkipZigTest;
    Fake.install();
    defer Fake.uninstall();
    var memory: [memory_bytes]u8 = undefined;
    var w = faked(&memory);
    var st: conformance.Storage = .{};
    const rows = rowsOf(filled(&st));
    var f = try w.begin(.{ 64, 48 }, 1);
    w.present(&f, .{ .rows = rows, .damage = .everything, .clear = .{ 0, 0, 1, 1 } });
    Fake.len = 0;
    f = try w.begin(.{ 80, 60 }, 1);
    try testing.expectEqual([2]u32{ 80, 60 }, w.layer.px);
    try testing.expectEqual(1, Fake.count("setDrawableSize:"));
    try testing.expectEqual(1, Fake.count("newTextureWithDescriptor:"));
    try testing.expect(w.lost);
    var resized = rows;
    resized.viewport = .{ 80, 60 };
    w.present(&f, .{ .rows = resized, .damage = .empty, .clear = .{ 0, 0, 1, 1 } });
    try testing.expectEqual(1 + conformance.scenes[0].draws.len, Fake.count(draw_quads));
    try testing.expectEqual(1, Fake.count("setClearColor:"));
    // A scale change alone keeps the size in points but not in pixels: made again too.
    Fake.len = 0;
    _ = try w.begin(.{ 80, 60 }, 2);
    try testing.expectEqual(1, Fake.count("newTextureWithDescriptor:"));
}
