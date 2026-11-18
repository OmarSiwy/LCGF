//! UI rendered into a texture ("texture out" in the header of prototype/ui_wgpu.zig: point the
//! pass at any texture view). A second UI, the hello example with its own `Context` and
//! buffer, is built and drawn into an offscreen framebuffer; that framebuffer is texture 1 of
//! the outer UI, which shows it on a tilted card (`Style.texture`, `Style.transform`) as a game
//! shows a screen inside its world. The inner UI is redrawn only when it builds a frame.
//!
//! ponytail: the inner UI gets no input (pointer mapping through the card's transform is the
//! host's to add); it shows what it would show at rest.

const std = @import("std");
const lcgf = @import("lcgf");
const w = lcgf.widgets_base;
const sw = lcgf.render_sw;
const context = lcgf.context;
const Frame = lcgf.frame.Frame;
const Input = lcgf.input.Input;
const Quad = lcgf.draw_list.Quad;
const types = lcgf.types;
const Id = types.Id;
const Events = lcgf.shell_iface.Events;
const host = @import("host");
const panel_id = Id.from("hello");

pub const tex_w = 320;
pub const tex_h = 200;
pub const id_card = Id.from("screen");
pub const id_tilt = Id.from("tilt");
pub const screen_texture: types.Texture = @fromBackingInt(1);

const inner_limits: context.Limits = .{ .nodes = 64, .texts = 16, .customs = 1, .strings = 1024, .signals = 4, .memos = 4 };
var inner_buffer: [context.Context.requiredBytes(inner_limits)]u8 align(lcgf.mem.column_align) = undefined;
var tex_pixels: [sw.Framebuffer.len(tex_w, tex_h)]u32 = undefined;
var quads: [256]Quad = undefined;
var first: [inner_limits.texts]u32 = undefined;
var count: [inner_limits.texts]u32 = undefined;

/// The offscreen scene uses the same greeting as the hello application.
const Greeting = struct {
    theme: w.Theme = .default,
    waves: u32 = 0,

    fn build(greeting: *Greeting, f: *Frame, _: *const Events) void {
        const th = &greeting.theme;
        _ = f.open(.from("center"), .{ .size = .{ .fill, .fill }, .main = .center, .cross = .center });
        _ = f.open(panel_id, .{ .pad = @splat(16), .gap = 8, .cross = .center, .fill = th.panel, .radius = th.radius });
        _ = w.label(f, th, "Hello, window");
        if (w.button(f, th, .from("wave"), "Wave").clicked) greeting.waves += 1;
        var buf: [32]u8 = undefined;
        _ = w.label(f, th, std.fmt.bufPrint(&buf, "Waved {d} times", .{greeting.waves}) catch "?");
        f.close();
        f.close();
    }
};

pub const App = struct {
    theme: w.Theme = .default,
    inner: Greeting = .{},
    inner_ctx: ?context.Context = null,
    inner_in: Input = .{ .viewport = .{ tex_w, tex_h } },
    tex: sw.Framebuffer = undefined,
    gfx: sw.Software = .{},
    /// Frames the inner UI built and drew into the texture.
    renders: u32 = 0,
    /// Where the inner UI's panel was laid out, in texels.
    inner_panel: types.Rect = .{},
    /// Card rotation, radians.
    tilt: f32 = 0.2,
    image_rows: [2]sw.Image = undefined,

    pub fn build(app: *App, f: *Frame, ev: *const Events) void {
        if (app.inner_ctx == null) {
            app.inner_ctx = context.Context.init(&inner_buffer, inner_limits) catch unreachable;
            app.tex = .init(&tex_pixels, tex_w, tex_h, .rgba8);
        }
        // The inner UI: its own frame, drawn into the texture when it needs one.
        app.inner_in.time = ev.in.time;
        app.inner_in.dt = ev.in.dt;
        const ictx = &app.inner_ctx.?;
        if (ictx.needsFrame(&app.inner_in)) {
            var inner = ictx.begin(&app.inner_in);
            const iev: Events = .{ .in = app.inner_in };
            app.inner.build(&inner, &iev);
            const out = inner.end(.{});
            host.draw(&app.inner, &app.gfx, &app.tex, .{ .quads = &quads, .first = &first, .count = &count }, &out, 1, app.theme.control_held);
            app.renders += 1;
            app.inner_panel = out.tree.rect(out.tree.find(panel_id));
        }

        // The outer UI: a slider for the tilt, and the card showing the texture.
        const th = &app.theme;
        _ = f.open(.from("page"), .{ .size = .{ .fill, .fill }, .pad = @splat(16), .gap = 16, .cross = .center });
        _ = w.slider(f, th, id_tilt, &app.tilt, -0.6, 0.6);
        const c = @cos(app.tilt);
        const s = @sin(app.tilt);
        _ = f.leaf(id_card, .{ .size = .{ .px(tex_w), .px(tex_h) }, .fill = .white, .texture = screen_texture, .uv = .{ 0, 0, @as(f32, tex_w) / @as(f32, @floatFromInt(app.tex.stride)), 1 }, .transform = .{ c, s, -s, c, 0, 0 } });
        f.close();
    }

    /// Texture 0 is white for plain quads, texture 1 holds the inner UI's pixels.
    pub fn images(app: *App) []const sw.Image {
        app.image_rows = .{ sw.Image.white, .{ .pixels = app.tex.pixels, .width = app.tex.stride, .height = tex_h } };
        return &app.image_rows;
    }
};

const testing = std.testing;

test "texture: the hello UI is drawn into a texture and shown on a card" {
    var app: App = .{};
    var s = try host.Smoke.run(&app, "frame\nviewport 800 600\nframe\nframe\n");
    try testing.expect(app.renders >= 1);
    // The texture holds the hello panel at its centre.
    const p = app.inner_panel;
    try testing.expectEqual(app.inner.theme.panel, app.tex.at(@intFromFloat(p.x0 + 4), @intFromFloat(p.y0 + 4)));
    // The same H is rasterized inside this offscreen surface.
    const title = app.inner_ctx.?.draw.runs[0].rect;
    const x: u32 = @intFromFloat(title[0]);
    const y: u32 = @intFromFloat(title[1]);
    try testing.expect(app.tex.at(x + 4, y + 8).r > 128);
    try testing.expectEqual(app.inner.theme.panel, app.tex.at(x + 4, y + 5));
    // The card's centre (the transform keeps it in place) shows the texture's centre.
    const r = s.rect(id_card);
    const mid = host.center(r);
    try testing.expectEqual(app.tex.at(tex_w / 2, tex_h / 2), s.at(@intFromFloat(mid[0]), @intFromFloat(mid[1])));
    // Untilted, the card's corner is the texture's corner colour; tilted, it is not drawn there.
    try testing.expect(!std.meta.eql(app.tex.at(1, 1), s.at(@intFromFloat(r.x0 + 1), @intFromFloat(r.y0 + 1))));
}
