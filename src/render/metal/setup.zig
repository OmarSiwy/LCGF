//! A Metal setup for an application that brings no device of its own: the system default
//! device and its queue, a CAMetalLayer configured for it, the renderer, and the frames in
//! flight. Moved from the iOS shell, which made them itself. An application that owns its
//! Metal objects uses `Renderer` directly instead.
//!
//!     var g = try Setup.init(layer);          // the view's CAMetalLayer
//!     g.draw(&draw, glyphs, viewport, scale, clear); // per frame
//!     g.deinit();

const lcgr = @import("lcgr");
const objc = @import("objc.zig");
const mtl = @import("mtl.zig");
const device = @import("device.zig");
const present = @import("present.zig");
const renderer = @import("renderer.zig");
const DrawList = lcgr.draw_list.DrawList;
const Id = objc.Id;
const msg = objc.msg;

pub const Error = device.Error || renderer.Error;

pub const Setup = struct {
    dev: device.Device,
    layer: device.Layer,
    gfx: renderer.Renderer,
    frames: present.Frames,

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
        const drawable = present.nextDrawable(g.layer.layer) orelse return false;
        const pass = present.beginPass(cmd, present.drawableTexture(drawable), clear);
        g.gfx.render(pass, list);
        present.endPass(pass);
        g.frames.present(cmd, drawable, null);
        return true;
    }
};
