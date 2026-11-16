//! The 2D-canvas fallback: the software back end (src/render/sw/) draws into a framebuffer in the
//! module's memory and `present` copies it onto a `<canvas>` with `putImageData` (lcgr.js
//! `canvas2d`). For browsers without WebGPU, or where a GPU context is not worth it: the pixels
//! are the software renderer's, which match the GPU goldens (ci/jobs/sw-golden.sh).
//!
//!     var c: Canvas = .init(pixels, width, height);   // pixels: sw.Framebuffer.len(w, h) u32s
//!     c.gfx.prepare({}, draw, glyphs, viewport, scale);
//!     c.fb.clear(.black);
//!     iface.render(&c.gfx, c.target(), draw);
//!     c.present();
//!
//! The framebuffer is RGBA8 in memory order, ImageData's layout, so `present` is one copy with
//! no conversion. wasm32-freestanding only.
const lcgr = @import("lcgr");
const sw = lcgr.render_sw;

const imports = struct {
    extern "lcgr" fn canvas_put(pixels: [*]const u32, stride: u32, width: u32, height: u32) void;
};

pub const Canvas = struct {
    fb: sw.Framebuffer,
    gfx: sw.Software = .{},

    /// `pixels` holds at least `sw.Framebuffer.len(width, height)` pixels, physical size.
    pub fn init(pixels: []u32, width: u32, height: u32) Canvas {
        return .{ .fb = .init(pixels, width, height, .rgba8) };
    }

    /// The pass to draw into: the whole framebuffer.
    pub fn target(c: *Canvas) sw.Target {
        return .{ .fb = &c.fb, .scissor = c.fb.all() };
    }

    /// Copies the framebuffer onto the canvas (rows are `stride` pixels apart; the padding is
    /// not shown).
    pub fn present(c: *const Canvas) void {
        imports.canvas_put(c.fb.pixels.ptr, c.fb.stride, c.fb.width, c.fb.height);
    }
};
