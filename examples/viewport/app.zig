//! 3D viewport under the UI, as Qt's "RHI under QML": the host draws its 3D scene into the
//! frame first (host.zig `draw` calls `under`), then the UI on top. The UI is a translucent
//! panel over the scene with controls that steer it; the rest of the window is the
//! prototype's `id_viewport`, a custom rect the UI only reserves, through which the scene is
//! seen. The scene is a lit sphere ray-cast per pixel on the CPU; a GPU host would record its
//! pass before the UI's in the same command buffer.

const std = @import("std");
const lcgf = @import("lcgf");
const w = lcgf.widgets_base;
const sw = lcgf.render_sw;
const Frame = lcgf.frame.Frame;
const types = lcgf.types;
const Id = types.Id;
const Color = types.Color;
const Events = lcgf.shell_iface.Events;

pub const id_panel = Id.from("controls");
pub const id_light = Id.from("light");
pub const id_wire = Id.from("wireframe");
pub const id_viewport = Id.from("viewport");

pub const sky: Color = .rgb(16, 24, 40);

pub const App = struct {
    theme: w.Theme = .default,
    /// Light direction around the vertical axis, radians (0..2pi).
    light: f32 = 0.8,
    /// Bands of latitude drawn dark, as a wireframe stand-in.
    bands: bool = false,
    // The host calls under after layout, while the current frame's tree is still valid.
    tree: *const lcgf.tree.Tree = undefined,
    viewport: types.Node = .none,
    scale: f32 = 1,

    pub fn build(app: *App, f: *Frame, ev: *const Events) void {
        var th = app.theme;
        th.panel.a = 200; // translucent: the scene shows through
        _ = f.open(.from("layout"), .{ .dir = .x, .size = .{ .fill, .fill } });
        _ = f.open(id_panel, .{ .size = .{ .px(220), .fill }, .pad = @splat(10), .gap = 8, .fill = th.panel });
        _ = w.label(f, &th, "Light");
        _ = w.slider(f, &th, id_light, &app.light, 0, 2 * std.math.pi);
        _ = w.checkbox(f, &th, id_wire, &app.bands, "Bands");
        f.close();
        app.viewport = f.custom(id_viewport, .{ .size = .{ .fill, .fill } }, 0);
        f.close();
        app.tree = f.tree();
        app.scale = ev.in.scale;
    }

    /// The scene, drawn before the UI over the whole frame: a unit sphere centred in the
    /// viewport, Lambert-lit from `light`.
    pub fn under(app: *App, fb: *sw.Framebuffer) void {
        fb.clear(sky);
        if (app.viewport == .none) return;
        const v = app.tree.rect(app.viewport.ix());
        const cx = (v.x0 + v.x1) * 0.5 * app.scale;
        const cy = (v.y0 + v.y1) * 0.5 * app.scale;
        const radius = @min(v.x1 - v.x0, v.y1 - v.y0) * 0.4 * app.scale;
        if (radius <= 0) return;
        const l: [3]f32 = .{ @cos(app.light) * 0.8, -0.4, @sin(app.light) * 0.8 + 0.6 };
        const ln = @sqrt(l[0] * l[0] + l[1] * l[1] + l[2] * l[2]);
        const simd = lcgf.simd;
        const x0 = std.mem.alignBackward(u32, bound(@floor(cx - radius), fb.width), simd.lanes);
        const x1 = bound(@floor(cx + radius) + 1, fb.width);
        const y0 = bound(@ceil(cy - radius), fb.height);
        const y1 = bound(@floor(cy + radius) + 1, fb.height);
        const red: u5 = if (fb.format == .bgra8) 16 else 0;
        const sky_pixel = simd.u(fb.pack(sky));
        for (y0..y1) |y| {
            const ny = (@as(f32, @floatFromInt(y)) - cy) / radius;
            const band = app.bands and @mod(std.math.asin(ny) * 8, 1) < 0.15;
            const row = fb.pixels[y * fb.stride ..][0..fb.stride];
            var x = x0;
            while (x < x1) : (x += simd.lanes) {
                const xs: simd.F = @floatFromInt(simd.iota + simd.u(x));
                const nx = (xs - simd.f(cx)) / simd.f(radius);
                const d = simd.f(1) - nx * nx - simd.f(ny * ny);
                const nz = @sqrt(@max(d, simd.f(0)));
                const lit = @max((nx * simd.f(l[0]) + simd.f(ny * l[1]) + nz * simd.f(l[2])) / simd.f(ln), simd.f(0));
                const k = if (band) simd.f(0.2) else simd.f(0.15) + simd.f(0.85) * lit;
                const r: simd.U = @intFromFloat(simd.f(230) * k);
                const g: simd.U = @intFromFloat(simd.f(140) * k);
                const b: simd.U = @intFromFloat(simd.f(60) * k);
                const pixel = simd.u(0xff000000) | (r << @splat(red)) | (g << @splat(8)) | (b << @splat(16 - red));
                row[x..][0..simd.lanes].* = @select(u32, d >= simd.f(0), pixel, sky_pixel);
            }
        }
    }

    fn bound(value: f32, max: u32) u32 {
        return @intFromFloat(std.math.clamp(value, 0, @as(f32, @floatFromInt(max))));
    }
};

const testing = std.testing;
const host = @import("host");

test "viewport: the scene is drawn under the UI and shows through the panel" {
    var app: App = .{};
    var s = try host.Smoke.run(&app, "frame\nviewport 800 600\nframe\n");
    const v = s.rect(id_viewport);
    try testing.expectEqual(types.Rect{ .x0 = 220, .y0 = 0, .x1 = 800, .y1 = 600 }, v);
    // The sphere's middle is lit, its corner is sky; the panel is a blend of its colour and sky.
    const mid = s.at(510, 300);
    try testing.expect(mid.r > 100 and mid.r > mid.b);
    try testing.expectEqual(sky, s.at(230, 10));
    const p = s.at(5, 590);
    try testing.expect(!std.meta.eql(p, app.theme.panel) and !std.meta.eql(p, sky));

    // Dragging the light slider changes the shading the scene draws.
    const before = s.at(400, 300);
    const track = s.rect(id_light);
    var rec: [256]u8 = undefined;
    const y = (track.y0 + track.y1) / 2;
    app = .{};
    s = try host.Smoke.run(&app, try std.fmt.bufPrint(&rec, "frame\nviewport 800 600\nframe\npointer {d} {d}\nframe\nbuttons left\nframe\nbuttons\nframe\n", .{ track.x1 - 2, y }));
    try testing.expect(app.light > 6);
    try testing.expect(!std.meta.eql(before, s.at(400, 300)));
}

test "viewport: the first resized frame lights the new sphere and clears the old one" {
    var app: App = .{};
    const s = try host.Smoke.run(&app, "frame\nviewport 800 600\nframe\nviewport 420 180\n");
    try testing.expect(s.at(320, 90).r > 100);
    try testing.expectEqual(sky, s.at(510, 300));
}

test "viewport: clicking Bands darkens a latitude without moving the sphere" {
    var app: App = .{};
    var s = try host.Smoke.run(&app, "frame\nviewport 800 600\n");
    const center_before = s.at(510, 300);
    const check = host.center(s.rect(id_wire));
    var rec: [256]u8 = undefined;
    app = .{};
    s = try host.Smoke.run(&app, try host.clicks(&rec, &.{check}));
    try testing.expect(app.bands);
    try testing.expectEqual(Color.rgb(46, 28, 12), s.at(510, 300));
    try testing.expect(center_before.r > s.at(510, 300).r);
}

test "viewport: SIMD shading matches the scalar sphere at every pixel of a narrow viewport" {
    for ([_]bool{ false, true }) |bands| {
        var app: App = .{ .bands = bands, .light = 3.2 };
        const s = try host.Smoke.run(&app, "frame\nviewport 269 81\n");
        const v = s.rect(id_viewport);
        const cx = (v.x0 + v.x1) * 0.5;
        const cy = (v.y0 + v.y1) * 0.5;
        const radius = @min(v.x1 - v.x0, v.y1 - v.y0) * 0.4;
        const l: [3]f32 = .{ @cos(app.light) * 0.8, -0.4, @sin(app.light) * 0.8 + 0.6 };
        const ln = @sqrt(l[0] * l[0] + l[1] * l[1] + l[2] * l[2]);
        for (0..81) |y| for (220..269) |x| {
            const nx = (@as(f32, @floatFromInt(x)) - cx) / radius;
            const ny = (@as(f32, @floatFromInt(y)) - cy) / radius;
            const d = 1 - nx * nx - ny * ny;
            const expected: Color = if (d < 0) sky else color: {
                const lit = @max((nx * l[0] + ny * l[1] + @sqrt(d) * l[2]) / ln, 0);
                const band = bands and @mod(std.math.asin(ny) * 8, 1) < 0.15;
                const k: f32 = if (band) 0.2 else 0.15 + 0.85 * lit;
                break :color .rgb(@intFromFloat(230 * k), @intFromFloat(140 * k), @intFromFloat(60 * k));
            };
            try testing.expectEqual(expected, s.at(@intCast(x), @intCast(y)));
        };
    }
}
