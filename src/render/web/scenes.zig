//! The render conformance scenes (src/render/conformance.zig) drawn in a browser: the wasm side
//! of test_webgpu.html and test_canvas.html, which read each scene back and compare it with its
//! golden image (browser.py --out, tools/golden/golden.py; ci/jobs/web.sh).
//!
//! The host loop is the one of src/render/wgpu/play.zig, split where JS has to step in: JS owns
//! the device, the target and the pass (and waits for the read-back, which is asynchronous), so
//! it calls `lcgf_scene_prepare` before the pass and `lcgf_scene_draw` inside it. Custom commands
//! are drawn here, through lcgf_render.gpu (src/render/gpu/gradient.zig, the code every back end
//! runs). The projection's own checks (src/render/gpu/check.zig) are recorded here too, and
//! test_gpu.html reads their results back.
const std = @import("std");
const lcgf = @import("lcgf");
const js = @import("js.zig");
const webgpu = @import("webgpu.zig");
const conformance = lcgf.render_conformance;
const iface = lcgf.render_iface;

pub const panic = js.panic;

const gpu = @import("gpu.zig");
const shaders = @import("gpu_shaders");
const Gradient = lcgf.gpu_gradient.Gradient(gpu, shaders.gradient);

var st: conformance.Storage = .{};
var gfx: webgpu.Renderer = undefined;
var queue: u32 = 0;
var atlas: lcgf.types.Texture = .white;
var viewport: [2]f32 = .{ 0, 0 };
var dev: gpu.Device = undefined;
var arena: gpu.Arena = undefined;
var gradient: Gradient = undefined;

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
    dev = .wrap(device, q);
    arena = gpu.Arena.init(dev, .{ .bytes = 0 }) catch unreachable;
    gradient = Gradient.init(dev, &arena, .{ .format = if (format == 1) .bgra8_unorm else .rgba8_unorm }) catch @panic("the custom draw's pipeline failed");
}

/// Loads scene `i` and uploads it. Call before the pass begins.
export fn lcgf_scene_prepare(i: u32) void {
    const s = &conformance.scenes[i];
    st.load(s);
    viewport = s.viewport;
    var glyphs = st.glyphs();
    glyphs.texture = atlas;
    gfx.prepare(queue, &st.draw, glyphs, s.viewport, 1);
    // The upload phase: the custom draw's target size, through the queue.
    var up: gpu.Upload = .begin(dev, 0);
    gradient.upload(&up, @intFromFloat(s.viewport[0]), @intFromFloat(s.viewport[1]));
    _ = up.finish();
}

/// Records the loaded scene into `pass`, the custom draw at each custom command.
export fn lcgf_scene_draw(pass: u32) void {
    const w: u32 = @intFromFloat(viewport[0]);
    const h: u32 = @intFromFloat(viewport[1]);
    var gp: gpu.RenderPass = .wrap(dev, pass, w, h);
    var i = iface.drawUntilCustom(&gfx, pass, &st.draw, 0);
    while (i < st.draw.cmd_len) : (i = iface.drawUntilCustom(&gfx, pass, &st.draw, i + 1)) {
        const k = st.draw.customs[st.draw.command(i).custom];
        gradient.draw(&gp, gpu.scissor(k.rect, k.clip, 1, w, h), w, h);
        // The UI's pipeline uses no scissor of its own: give it the whole target back.
        gp.setScissorRect(0, 0, w, h);
    }
}

// The projection's checks (src/render/gpu/check.zig), split where the browser's asynchronous
// readback has to happen: record into the page's encoder, let the page submit and read back
// into `check_pixels` and `check_values`, then verify.

const RenderToTexture = lcgf.gpu_check.RenderToTexture(gpu, shaders);
const Compute = lcgf.gpu_check.Compute(gpu, shaders);
const Instancing = lcgf.gpu_check.Instancing(gpu, shaders);
var check_instancing: Instancing = undefined;
var check_instancing_pixels: [Instancing.width * 4]u8 = undefined;
var check_texture: RenderToTexture = undefined;
var check_compute: Compute = undefined;
var check_pixels: [RenderToTexture.width * RenderToTexture.height * 4]u8 = undefined;
var check_values: [Compute.count]u32 = undefined;

/// Records the checks into `encoder`. Returns the texture to read back (8 x 8); the storage
/// buffer is `lcgf_check_buffer`, the instanced draws' target `lcgf_check_instancing` (8 x 1).
export fn lcgf_check_record(encoder: u32) u32 {
    check_texture.init(dev) catch @panic("check: render-to-texture setup failed");
    check_compute.init(dev) catch @panic("check: compute setup failed");
    var up: gpu.Upload = .begin(dev, encoder);
    check_texture.record(&up) catch @panic("check: render-to-texture recording failed");
    var up2: gpu.Upload = .begin(dev, encoder);
    check_compute.record(&up2);
    check_instancing.init(dev) catch @panic("check: instancing setup failed");
    var up3: gpu.Upload = .begin(dev, encoder);
    check_instancing.record(&up3);
    return check_texture.final.texture;
}

export fn lcgf_check_instancing() u32 {
    return check_instancing.target.texture;
}

export fn lcgf_check_instancing_pixels() [*]u8 {
    return &check_instancing_pixels;
}

export fn lcgf_check_buffer() u32 {
    return check_compute.out.buffer;
}

export fn lcgf_check_pixels() [*]u8 {
    return &check_pixels;
}

export fn lcgf_check_values() [*]u32 {
    return &check_values;
}

/// Bit 0: the render-to-texture check passed; bit 1: the compute check; bit 2: instancing.
export fn lcgf_check_verify() u32 {
    const ok = @as(u32, @intFromBool(RenderToTexture.verify(&check_pixels))) | (@as(u32, @intFromBool(Compute.verify(&check_values))) << 1) |
        (@as(u32, @intFromBool(Instancing.verify(&check_instancing_pixels))) << 2);
    check_instancing.deinit(dev);
    check_compute.deinit(dev);
    check_texture.deinit(dev);
    return ok;
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
