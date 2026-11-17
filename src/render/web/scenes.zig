//! The render conformance scenes (src/render/conformance.zig) drawn in a browser: the wasm side
//! of test_webgpu.html and test_canvas.html, which read each scene back and compare it with its
//! golden image (browser.py --out, tools/golden/golden.py; ci/jobs/web.sh).
//!
//! The host loop is the one of src/render/wgpu/play.zig, split where JS has to step in: JS owns
//! the device, the target and the pass (and waits for the read-back, which is asynchronous), so
//! it calls `lcgf_scene_prepare` before the pass and `lcgf_scene_draw` inside it. Custom commands
//! go back to the host's own pipeline through the page's `host_custom` import.
const std = @import("std");
const lcgf = @import("lcgf");
const js = @import("js.zig");
const webgpu = @import("webgpu.zig");
const conformance = lcgf.render_conformance;
const iface = lcgf.render_iface;

pub const panic = js.panic;

extern "lcgf" fn host_custom(pass: u32, x0: u32, y0: u32, x1: u32, y1: u32) void;

var st: conformance.Storage = .{};
var gfx: webgpu.Renderer = undefined;
var queue: u32 = 0;
var atlas: lcgf.types.Texture = .white;
var viewport: [2]f32 = .{ 0, 0 };

export fn lcgf_scene_count() u32 {
    return conformance.scenes.len;
}

/// Width in the low 16 bits, height in the high 16, logical pixels at scale 1. Logs the name.
export fn lcgf_scene_size(i: u32) u32 {
    const s = &conformance.scenes[i];
    js.log(s.name);
    return @as(u32, @intFromFloat(s.viewport[0])) | (@as(u32, @intFromFloat(s.viewport[1])) << 16);
}

/// `white` is a 1x1 white texture view, `atlas_view` the goldens' stand-in glyph atlas, both
/// sampled with `sampler` (nearest).
export fn lcgf_webgpu_init(device: u32, q: u32, format: u32, white: u32, sampler: u32, atlas_view: u32) void {
    queue = q;
    gfx = .init(device, .{ .format = @fromBackingInt(@intCast(format)), .max_quads = 64, .max_glyphs = 64 }, white, sampler);
    atlas = gfx.addTexture(device, atlas_view, sampler);
}

/// Loads scene `i` and uploads it. Call before the pass begins.
export fn lcgf_scene_prepare(i: u32) void {
    const s = &conformance.scenes[i];
    st.load(s);
    viewport = s.viewport;
    var glyphs = st.glyphs();
    glyphs.texture = atlas;
    gfx.prepare(queue, &st.draw, glyphs, s.viewport, 1);
}

/// Records the loaded scene into `pass`, the host's custom draw at each custom command.
export fn lcgf_scene_draw(pass: u32) void {
    var i = iface.drawUntilCustom(&gfx, pass, &st.draw, 0);
    while (i < st.draw.cmd_len) : (i = iface.drawUntilCustom(&gfx, pass, &st.draw, i + 1)) {
        const b = clamped(st.draw.customs[st.draw.command(i).custom].rect);
        host_custom(pass, b[0], b[1], b[2], b[3]);
    }
}

/// The custom rect in whole pixels inside the scene, as play.zig scissors it.
fn clamped(r: [4]f32) [4]u32 {
    const w = viewport[0];
    const h = viewport[1];
    return .{
        @intFromFloat(std.math.clamp(r[0], 0, w)),
        @intFromFloat(std.math.clamp(r[1], 0, h)),
        @intFromFloat(std.math.clamp(r[2], r[0], w)),
        @intFromFloat(std.math.clamp(r[3], r[1], h)),
    };
}

// The 2D-canvas fallback (canvas.zig): the same scenes in software, presented with putImageData.

const canvas = @import("canvas.zig");
const sw = lcgf.render_sw;

var pixels: [sw.Framebuffer.len(160, 120)]u32 = undefined;
var atlas_px: [64 * 64]u32 = undefined;

/// Draws scene `i` into the framebuffer and presents it on the page's canvas.
export fn lcgf_canvas_scene(i: u32) void {
    const s = &conformance.scenes[i];
    st.load(s);
    viewport = s.viewport;
    // render.py's stand-in glyph atlas: every printable byte a 2x3 block of white.
    atlas_px = @splat(0);
    for (33..127) |byte| for (1..4) |y| for (1..3) |x| {
        atlas_px[((byte >> 4) * 4 + y) * 64 + (byte & 15) * 4 + x] = 0xffff_ffff;
    };
    const w: u32 = @intFromFloat(s.viewport[0]);
    const h: u32 = @intFromFloat(s.viewport[1]);
    var c: canvas.Canvas = .init(&pixels, w, h);
    c.gfx.images = &.{ sw.Image.white, .{ .pixels = &atlas_px, .width = 64, .height = 64 } };
    var glyphs = st.glyphs();
    glyphs.texture = @fromBackingInt(1);
    c.gfx.prepare({}, &st.draw, glyphs, s.viewport, 1);
    c.fb.clear(.black);
    var k = iface.drawUntilCustom(&c.gfx, c.target(), &st.draw, 0);
    while (k < st.draw.cmd_len) : (k = iface.drawUntilCustom(&c.gfx, c.target(), &st.draw, k + 1)) {
        // The host's own draw: render.py's gradient over the custom rect, replacing what is there.
        const b = clamped(st.draw.customs[st.draw.command(k).custom].rect);
        for (b[1]..b[3]) |y| for (b[0]..b[2]) |x| {
            const fx = @as(f32, @floatFromInt(x)) + 0.5;
            const fy = @as(f32, @floatFromInt(y)) + 0.5;
            c.fb.pixels[y * c.fb.stride + x] = c.fb.pack(.rgb(unorm(fx / s.viewport[0] * 0.5), unorm(0.25), unorm(fy / s.viewport[1] * 0.6)));
        };
    }
    c.present();
}

fn unorm(x: f32) u8 {
    return @intFromFloat(@round(std.math.clamp(x, 0, 1) * 255));
}
