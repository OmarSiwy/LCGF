//! The shell example on the web: the example UI (src/shell/example.zig) in a browser page,
//! through the web shell (web.zig) and drawn with the web back end's 2D-canvas path
//! (src/render/web/canvas.zig). Built by `zig build web` into zig-out/web/shell.wasm; index.html
//! is the page.
const std = @import("std");
const lcgr = @import("lcgr");
const rweb = @import("render_web");
const context = lcgr.context;
const scheduler = lcgr.scheduler;
const example = lcgr.shell_example;
const sw = lcgr.render_sw;
const Output = context.Output;
const Pace = scheduler.Pace;

pub const panic = rweb.js.panic;

const imports = struct {
    extern "lcgr" fn shell_schedule(seconds: f32, pace: u32) void;
};

/// The page, as web.zig's `host`.
const host = struct {
    pub fn schedule(seconds: f32, pace: Pace) void {
        imports.shell_schedule(seconds, @backingInt(pace));
    }
    pub fn present(out: *const Output) void {
        const n = font.quads(out.draw, &glyph_quads, .{ .first = &glyph_first, .count = &glyph_count });
        const glyphs: lcgr.render_iface.Glyphs = .{ .quads = glyph_quads[0..n], .first = &glyph_first, .count = &glyph_count };
        const scale = shell.in.scale;
        // The framebuffer is the canvas's pixel size, up to what `pixels` holds.
        const w: u32 = @min(@as(u32, @intFromFloat(@round(@max(shell.in.viewport[0] * scale, 1)))), max_w);
        const h: u32 = @min(@as(u32, @intFromFloat(@round(@max(shell.in.viewport[1] * scale, 1)))), @as(u32, @intCast(pixels.len / sw.Framebuffer.len(w, 1))));
        var c: rweb.canvas.Canvas = .init(&pixels, w, h);
        c.gfx.prepare({}, out.draw, glyphs, shell.in.viewport, scale);
        c.fb.clear(background);
        lcgr.render_iface.render(&c.gfx, c.target(), out.draw);
        c.present();
    }
};

const Shell = lcgr.shell_web.Web(host);

const limits: context.Limits = .{ .nodes = 1024, .texts = 256 };
var buffer: [context.Context.requiredBytes(limits)]u8 align(lcgr.mem.column_align) = undefined;
var ctx: context.Context = undefined;
var app: example.App = .{};
var shell: Shell = .{};
var ev: lcgr.shell_iface.Events = .{};
const font: lcgr.protocol.Mono = .{};
var glyph_quads: [4096]lcgr.draw_list.Quad = undefined;
var glyph_first: [limits.texts]u32 = undefined;
var glyph_count: [limits.texts]u32 = undefined;
/// The 2D-canvas framebuffer: up to 2560 x 1600 physical pixels, 16 MB of zero-initialised
/// memory; a bigger canvas shows its top left.
const max_w = 2560;
var pixels: [sw.Framebuffer.len(max_w, 1600)]u32 = undefined;
const background: lcgr.types.Color = .rgb(0, 0, 0);

export fn lcgr_init() bool {
    ctx = context.Context.init(&buffer, limits) catch return false;
    return true;
}

/// One animation frame: one turn of iface.run's body (web.zig).
export fn lcgr_frame(ms: f64) void {
    shell.time(ms / 1000);
    if (!shell.poll(&ev)) return;
    if (ctx.needsFrame(&ev.in)) {
        var f = ctx.begin(&ev.in);
        app.build(&f, &ev);
        const out = f.end(font);
        shell.apply(&out.platform);
        shell.present(&out);
    }
    shell.wait(scheduler.wake(&ctx, &ev.in), scheduler.pace(&ctx));
}

export fn lcgr_resize(css_w: f32, css_h: f32, dpr: f32) void {
    shell.resize(css_w, css_h, dpr);
}
export fn lcgr_pointer(x: f32, y: f32) void {
    shell.pointer(x, y);
}
export fn lcgr_leave() void {
    shell.leave();
}
export fn lcgr_button(b: u32, down: bool) void {
    shell.button(b, down);
}
export fn lcgr_close() void {
    shell.close();
}

/// The example's state, for the tests: builds, resets, layers, exposure * 1000, the theme's
/// panel colour (RGBA bytes, little-endian), polls.
export fn lcgr_example_state(i: u32) u32 {
    const s = [_]u32{ app.builds, app.resets, app.layers, @intFromFloat(@round(app.exposure * 1000)), app.theme.panel.bitsOf(), shell.polls };
    return s[@min(i, s.len - 1)];
}
