//! 3D viewport under the UI, as Qt's "RHI under QML": the host draws its 3D scene into the
//! frame first (host.zig `draw` calls `under`), then the UI on top. The UI is a translucent
//! panel over the scene with controls that steer it; the rest of the window is the
//! prototype's `id_viewport`, a custom rect the UI only reserves, through which the scene is
//! seen. The scene is a lit sphere ray-cast per pixel on the CPU; a GPU host would record its
//! pass before the UI's in the same command buffer.

const std = @import("std");
const lcgr = @import("lcgr");
const w = lcgr.widgets_base;
const sw = lcgr.render_sw;
const Frame = lcgr.frame.Frame;
const types = lcgr.types;
const Id = types.Id;
const Color = types.Color;
const Events = lcgr.shell_iface.Events;

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
    /// Where the scene is seen (the custom rect), from the last frame.
    view: types.Rect = .{},

    pub fn build(app: *App, f: *Frame, _: *const Events) void {
        var th = app.theme;
        th.panel.a = 200; // translucent: the scene shows through
        _ = f.open(.from("layout"), .{ .dir = .x, .size = .{ .fill, .fill } });
        _ = f.open(id_panel, .{ .size = .{ .px(220), .fill }, .pad = @splat(10), .gap = 8, .fill = th.panel });
        _ = w.label(f, &th, "Light");
        _ = w.slider(f, &th, id_light, &app.light, 0, 2 * std.math.pi);
        _ = w.checkbox(f, &th, id_wire, &app.bands, "Bands");
        f.close();
        _ = f.custom(id_viewport, .{ .size = .{ .fill, .fill } }, 0);
        f.close();
        app.view = f.lastRect(id_viewport);
    }

    /// The scene, drawn before the UI over the whole frame: a unit sphere centred in the
    /// viewport, Lambert-lit from `light`.
    pub fn under(app: *App, fb: *sw.Framebuffer) void {
        fb.clear(sky);
        const v = app.view;
        const cx = (v.x0 + v.x1) / 2;
        const cy = (v.y0 + v.y1) / 2;
        const radius = @max(@min(v.x1 - v.x0, v.y1 - v.y0) * 0.4, 1);
        const l: [3]f32 = .{ @cos(app.light) * 0.8, -0.4, @sin(app.light) * 0.8 + 0.6 };
        const ln = @sqrt(l[0] * l[0] + l[1] * l[1] + l[2] * l[2]);
        for (0..fb.height) |y| for (0..fb.width) |x| {
            const nx = (@as(f32, @floatFromInt(x)) - cx) / radius;
            const ny = (@as(f32, @floatFromInt(y)) - cy) / radius;
            const d = 1 - nx * nx - ny * ny;
            if (d < 0) continue;
            const nz = @sqrt(d);
            const lit = @max((nx * l[0] + ny * l[1] + nz * l[2]) / ln, 0);
            const band = app.bands and @mod(std.math.asin(ny) * 8, 1) < 0.15;
            const k: f32 = if (band) 0.2 else 0.15 + 0.85 * lit;
            const c: Color = .rgb(@intFromFloat(230 * k), @intFromFloat(140 * k), @intFromFloat(60 * k));
            fb.pixels[y * fb.stride + x] = fb.pack(c);
        };
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
