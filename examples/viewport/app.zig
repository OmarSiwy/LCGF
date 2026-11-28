//! 3D viewport under the UI, as Qt's "RHI under QML": a scene the application draws itself,
//! with the UI on top. The scene is a lit sphere ray-cast per pixel. On a GPU window it is a
//! `lcgf_app.Surface` behind the whole window, drawn by a WGSL shader (sphere.wgsl) through
//! `lcgf_app.gpu` the way examples/surface draws its rings, and again only when the light,
//! the bands or the window's size change. The UI is a translucent panel over the scene with
//! controls that steer it; the rest of the window is `id_viewport`, through which the scene is
//! seen.
//!
//! A software window (`LCGF_RENDER=sw`, or no Vulkan device) never draws a surface: there the
//! same sphere is shaded on the CPU (`shade`, the shader's twin) into an `lcgf_app.Image`
//! shown in the middle of the viewport, over the sky the surface's node paints, and the panel
//! says so.

const std = @import("std");
const lcgf = @import("lcgf");
const lcgf_app = @import("lcgf_app");
const w = lcgf.widgets_base;
const simd = lcgf.simd;
const Frame = lcgf.frame.Frame;
const types = lcgf.types;
const Id = types.Id;
const Color = types.Color;
const Events = lcgf.shell_iface.Events;

pub const id_panel = Id.from("controls");
pub const id_light = Id.from("light");
pub const id_wire = Id.from("wireframe");
pub const id_viewport = Id.from("viewport");
pub const id_picture = Id.from("picture");

pub const sky: Color = .rgb(16, 24, 40);
pub const panel_w = 220;
/// The CPU sphere's image: `side` x `side` texels, the sphere touching its edges.
pub const side = 256;
const picture_texture: types.Texture = @fromBackingInt(1);

pub const App = struct {
    theme: w.Theme = .default,
    /// Light direction around the vertical axis, radians (0..2pi).
    light: f32 = 0.8,
    /// Bands of latitude drawn dark, as a wireframe stand-in.
    bands: bool = false,
    /// The scene on the GPU, and what it was last asked to draw.
    scene: lcgf_app.Surface = .{},
    sphere: Sphere = undefined,
    params: Params = .{},
    /// The last frame was in a GPU window; scenes the GPU drew.
    live: bool = false,
    draws: u32 = 0,
    /// The scene on the CPU, and the light and bands it was shaded for.
    pixels: [side * side]u32 = undefined,
    image: [1]lcgf_app.Image = .{.{ .size = .{ side, side } }},
    shaded: ?[2]f32 = null,

    pub fn build(app: *App, f: *Frame, ev: *const Events) void {
        var th = app.theme;
        th.panel.a = 200; // translucent: the scene shows through
        const live = app.scene.live();
        app.live = live;
        // The sphere: centred in the viewport, 0.4 of its shorter side across.
        const vp = ev.in.viewport;
        const radius = @min(vp[0] - panel_w, vp[1]) * 0.4;
        const params: Params = .{
            .sphere = .{ (panel_w + vp[0]) * 0.5 * ev.in.scale, vp[1] * 0.5 * ev.in.scale, radius * ev.in.scale, app.light },
            .bands = .{ @floatFromInt(@intFromBool(app.bands)), 0, 0, 0 },
        };
        if (live and !std.meta.eql(params, app.params)) app.scene.redraw();
        app.params = params;

        _ = f.open(.from("layout"), .{ .dir = .x, .size = .{ .fill, .fill } });
        // Behind everything: the GPU's scene, or the sky its node paints on a software window.
        const fill: Color = if (live) .{} else sky;
        _ = app.scene.node(f, .from("scene"), .{ .float = true, .size = .{ .pct(1), .pct(1) }, .fill = fill });
        _ = f.open(id_panel, .{ .size = .{ .px(panel_w), .fill }, .pad = @splat(10), .gap = 8, .fill = th.panel });
        _ = w.label(f, &th, "Light");
        _ = w.slider(f, &th, id_light, &app.light, 0, 2 * std.math.pi);
        _ = w.checkbox(f, &th, id_wire, &app.bands, "Bands");
        if (!live) _ = w.label(f, &th, "No GPU: the sphere is shaded on the CPU.");
        f.close();
        _ = f.open(id_viewport, .{ .size = .{ .fill, .fill }, .main = .center, .cross = .center });
        if (!live) {
            app.shade();
            const d: types.Size = .px(@max(2 * radius, 0));
            _ = f.leaf(id_picture, .{ .size = .{ d, d }, .fill = .white, .texture = picture_texture });
        }
        f.close();
        f.close();
    }

    /// Texture 1: the sphere shaded on the CPU; none until a software window shaded it.
    pub fn images(app: *App) []const lcgf_app.Image {
        return if (app.shaded == null) &.{} else &app.image;
    }

    /// The scene on the GPU: never called on a software window.
    pub fn draw(app: *App, g: *lcgf_app.GpuFrame) !void {
        if (lcgf_app.has_gpu) {
            if (g.fresh) app.sphere = try .init(g.device, g.arena);
            app.sphere.draw(g, &app.scene, app.params);
            app.draws += 1;
        }
    }

    /// Shades the CPU image again when the light or the bands changed.
    fn shade(app: *App) void {
        const now: [2]f32 = .{ app.light, @floatFromInt(@intFromBool(app.bands)) };
        if (app.shaded) |s| if (std.meta.eql(s, now)) return;
        shadeSphere(&app.pixels, app.light, app.bands);
        app.image[0].pixels = &app.pixels;
        app.image[0].generation +%= 1;
        app.shaded = now;
    }
};

/// sphere.wgsl's uniform: centre and radius in the surface's physical pixels and the light's
/// angle; bands.x is 1 to draw the bands.
const Params = extern struct {
    sphere: [4]f32 = @splat(0),
    bands: [4]f32 = @splat(0),
};

/// The shader's pipeline, uniform buffer and bind group, made in the window's arena; nothing
/// in a build without a GPU path.
const Sphere = if (lcgf_app.has_gpu) struct {
    const gpu = lcgf_app.gpu;
    const Shader = gpu.Shader(@import("viewport_shaders").sphere);

    pipeline: gpu.RenderPipeline(Shader),
    group: gpu.BindGroup(Shader, 0),
    params: gpu.Buffer,

    fn init(dev: gpu.Device, arena: *gpu.Arena) !@This() {
        const params = try dev.createBuffer(arena, .{ .size = @sizeOf(Params), .usage = .{ .uniform = true, .copy_dst = true } });
        const pipeline = try dev.createRenderPipeline(Shader, .{
            .fragment = .{ .targets = &.{.{ .format = lcgf_app.Surface.format }} },
        });
        const group = try dev.createBindGroup(arena, pipeline, 0, .{ .params = params });
        return .{ .pipeline = pipeline, .group = group, .params = params };
    }

    /// One triangle over the `size` pixels of `scene` in use.
    fn draw(s: *const @This(), g: *lcgf_app.GpuFrame, scene: *const lcgf_app.Surface, params: Params) void {
        g.upload.writeBuffer(s.params, 0, std.mem.asBytes(&params));
        const size = scene.size;
        const enc = g.encoder();
        const target = scene.texture.createView();
        var pass = enc.beginRenderPass(.{ .color_attachments = &.{.{ .view = target, .clear_value = .{ .a = 1 } }} });
        pass.setViewport(0, 0, @floatFromInt(size[0]), @floatFromInt(size[1]), 0, 1);
        pass.setScissorRect(0, 0, size[0], size[1]);
        pass.setPipeline(s.pipeline);
        pass.setBindGroup(0, &s.group);
        pass.draw(3, 1, 0, 0);
        pass.end();
    }
} else void;

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    try lcgf_app.run(App, &app, init, .{ .title = "Viewport" });
    // In a GPU window the scene must have been drawn (ci/run.sh examples-x11 runs it so).
    if (app.live and app.draws == 0) return error.NothingDrawn;
}

// ---- private ----

/// The unit sphere filling `pixels` (`side` x `side`, Color bits), Lambert-lit from `light`,
/// on sky: sphere.wgsl's shading, a row of lanes at a time.
fn shadeSphere(pixels: *[side * side]u32, light: f32, bands: bool) void {
    const c: f32 = side / 2;
    const l = lightDir(light);
    const ln = @sqrt(l[0] * l[0] + l[1] * l[1] + l[2] * l[2]);
    const sky_pixel = simd.u(sky.bitsOf());
    for (0..side) |y| {
        const ny = (@as(f32, @floatFromInt(y)) - c) / c;
        const band = bands and @mod(std.math.asin(ny) * 8, 1) < 0.15;
        const row = pixels[y * side ..][0..side];
        var x: u32 = 0;
        while (x < side) : (x += simd.lanes) {
            const xs: simd.F = @floatFromInt(simd.iota + simd.u(x));
            const nx = (xs - simd.f(c)) / simd.f(c);
            const d = simd.f(1) - nx * nx - simd.f(ny * ny);
            const nz = @sqrt(@max(d, simd.f(0)));
            const lit = @max((nx * simd.f(l[0]) + simd.f(ny * l[1]) + nz * simd.f(l[2])) / simd.f(ln), simd.f(0));
            const k = if (band) simd.f(0.2) else simd.f(0.15) + simd.f(0.85) * lit;
            const r: simd.U = @intFromFloat(simd.f(230) * k);
            const g: simd.U = @intFromFloat(simd.f(140) * k);
            const b: simd.U = @intFromFloat(simd.f(60) * k);
            const pixel = simd.u(0xff000000) | r | (g << @splat(8)) | (b << @splat(16));
            row[x..][0..simd.lanes].* = @select(u32, d >= simd.f(0), pixel, sky_pixel);
        }
    }
}

fn lightDir(light: f32) [3]f32 {
    return .{ @cos(light) * 0.8, -0.4, @sin(light) * 0.8 + 0.6 };
}

const testing = std.testing;
const replay = lcgf_app.replay;

test "viewport: the CPU sphere sits in the viewport and shows through nothing but the panel" {
    var app: App = .{};
    var s = try replay.run(&app, "frame\nviewport 800 600\n");
    const v = s.rect(id_viewport);
    try testing.expectEqual(types.Rect{ .x0 = 220, .y0 = 0, .x1 = 800, .y1 = 600 }, v);
    // No GPU here: the picture's middle is lit, the viewport's corner is sky, the panel is a
    // blend of its colour and the sky.
    const mid = s.at(510, 300);
    try testing.expect(mid.r > 100 and mid.r > mid.b);
    try testing.expectEqual(sky, s.at(230, 10));
    const p = s.at(5, 590);
    try testing.expect(!std.meta.eql(p, app.theme.panel) and !std.meta.eql(p, sky));

    // Dragging the light slider shades the sphere again.
    const before = s.at(400, 300);
    const generation = app.image[0].generation;
    const track = s.rect(id_light);
    var rec: [256]u8 = undefined;
    const y = (track.y0 + track.y1) / 2;
    app = .{};
    s = try replay.run(&app, try std.fmt.bufPrint(&rec, "frame\nviewport 800 600\nframe\npointer {d} {d}\nframe\nbuttons left\nframe\nbuttons\nframe\n", .{ track.x1 - 2, y }));
    try testing.expect(app.light > 6);
    try testing.expect(app.image[0].generation > generation);
    try testing.expect(!std.meta.eql(before, s.at(400, 300)));
}

test "viewport: a resized window centres a smaller sphere in the new viewport" {
    var app: App = .{};
    const s = try replay.run(&app, "frame\nviewport 800 600\nframe\nviewport 420 180\n");
    const r = s.rect(id_picture);
    try testing.expectApproxEqAbs(@as(f32, 320), (r.x0 + r.x1) / 2, 0.5);
    try testing.expectApproxEqAbs(@as(f32, 2 * 180 * 0.4), r.x1 - r.x0, 0.5);
    try testing.expect(s.at(320, 90).r > 100);
}

test "viewport: clicking Bands darkens a latitude without moving the sphere" {
    var app: App = .{};
    var s = try replay.run(&app, "frame\nviewport 800 600\n");
    const center_before = s.at(510, 300);
    const check = replay.center(s.rect(id_wire));
    var rec: [256]u8 = undefined;
    app = .{};
    s = try replay.run(&app, try replay.clicks(&rec, &.{check}));
    try testing.expect(app.bands);
    try testing.expectEqual(Color.rgb(46, 28, 12), s.at(510, 300));
    try testing.expect(center_before.r > s.at(510, 300).r);
}

test "viewport: SIMD shading matches the scalar sphere at every texel" {
    var pixels: [side * side]u32 = undefined;
    for ([_]bool{ false, true }) |bands| {
        const light = 3.2;
        shadeSphere(&pixels, light, bands);
        const c: f32 = side / 2;
        const l = lightDir(light);
        const ln = @sqrt(l[0] * l[0] + l[1] * l[1] + l[2] * l[2]);
        for (0..side) |y| for (0..side) |x| {
            const nx = (@as(f32, @floatFromInt(x)) - c) / c;
            const ny = (@as(f32, @floatFromInt(y)) - c) / c;
            const d = 1 - nx * nx - ny * ny;
            const expected: Color = if (d < 0) sky else color: {
                const lit = @max((nx * l[0] + ny * l[1] + @sqrt(d) * l[2]) / ln, 0);
                const band = bands and @mod(std.math.asin(ny) * 8, 1) < 0.15;
                const k: f32 = if (band) 0.2 else 0.15 + 0.85 * lit;
                break :color .rgb(@intFromFloat(230 * k), @intFromFloat(140 * k), @intFromFloat(60 * k));
            };
            try testing.expectEqual(expected.bitsOf(), pixels[y * side + x]);
        };
    }
}
