//! Widgets around a surface the application draws itself: rings from a WGSL shader
//! (wave.wgsl) through `lcgf_app.gpu`, the build's GPU back end, animated while it runs. The
//! rings are drawn again every frame and the widgets only when they change: a click on the
//! button builds a frame, an animation frame does not (docs/guide/surface.md).
//!
//!     zig build surface-example && zig-out/bin/surface-example
//!
//! Vulkan over X11 on Linux (`-Drender=vk`, the default there). `LCGF_APP_SECONDS=1` closes
//! it after a second, and it fails when no ring was drawn on the GPU (ci/run.sh app runs it so
//! on Xvfb). Under `LCGF_RENDER=sw` it runs in the software window and says it has no rings.

const std = @import("std");
const lcgf = @import("lcgf");
const lcgf_app = @import("lcgf_app");
const gpu = lcgf_app.gpu;

/// The rings: a pipeline, a uniform buffer and a bind group, made in the application's arena.
const Wave = struct {
    const Shader = gpu.Shader(@import("surface_shaders").wave);

    pipeline: gpu.RenderPipeline(Shader),
    group: gpu.BindGroup(Shader, 0),
    params: gpu.Buffer,

    fn init(dev: gpu.Device, arena: *gpu.Arena) !Wave {
        const params = try dev.createBuffer(arena, .{ .size = 16, .usage = .{ .uniform = true, .copy_dst = true } });
        const pipeline = try dev.createRenderPipeline(Shader, .{
            .fragment = .{ .targets = &.{.{ .format = lcgf_app.Surface.format }} },
        });
        const group = try dev.createBindGroup(arena, pipeline, 0, .{ .params = params });
        return .{ .pipeline = pipeline, .group = group, .params = params };
    }

    /// Draws the rings at time `t` (seconds) over the `size` pixels of `plot` in use.
    fn draw(w: *const Wave, g: *lcgf_app.GpuFrame, plot: *const lcgf_app.Surface, t: f32) void {
        const size = plot.size;
        const params: [4]f32 = .{ @floatFromInt(size[0]), @floatFromInt(size[1]), t, 0 };
        g.upload.writeBuffer(w.params, 0, std.mem.asBytes(&params));
        const enc = g.encoder();
        const target = plot.texture.createView();
        var pass = enc.beginRenderPass(.{ .color_attachments = &.{.{ .view = target, .clear_value = .{ .a = 1 } }} });
        pass.setViewport(0, 0, @floatFromInt(size[0]), @floatFromInt(size[1]), 0, 1);
        pass.setScissorRect(0, 0, size[0], size[1]);
        pass.setPipeline(w.pipeline);
        pass.setBindGroup(0, &w.group);
        pass.draw(3, 1, 0, 0);
        pass.end();
    }
};

const App = struct {
    theme: lcgf.widgets_base.Theme = .default,
    /// The rectangle the rings are drawn in.
    plot: lcgf_app.Surface = .{},
    wave: Wave = undefined,
    running: bool = true,
    /// Frames of rings drawn, and widget frames built.
    draws: u32 = 0,
    builds: u32 = 0,
    /// The window draws the surface (on the GPU); else it says why there are no rings.
    live: bool = false,

    pub fn build(app: *App, f: *lcgf.frame.Frame, _: *const lcgf.shell_iface.Events) void {
        app.builds += 1;
        const th = &app.theme;
        _ = f.open(.from("page"), .{ .dir = .y, .size = .{ .fill, .fill }, .pad = @splat(12), .gap = 8, .fill = th.panel });
        const ui = lcgf.widgets.on(f, th);
        if (ui.button(.run, .{ .label = if (app.running) "Pause" else "Run" }).clicked) {
            app.running = !app.running;
            if (app.running) app.plot.redraw();
        }
        app.live = app.plot.live();
        if (!app.live) _ = ui.label("No GPU here (LCGF_RENDER=sw, or no Vulkan device): no rings.");
        // A fill tints the rings; without them it is what the node shows.
        const fill: lcgf.types.Color = if (app.live) .{} else th.control;
        _ = app.plot.node(f, .from("plot"), .{ .size = .{ .fill, .fill }, .radius = 8, .fill = fill });
        f.close();
    }

    /// A frame in which the rings must be drawn: never because a widget changed.
    pub fn draw(app: *App, g: *lcgf_app.GpuFrame) !void {
        if (g.fresh) app.wave = try .init(g.device, g.arena);
        app.wave.draw(g, &app.plot, @as(f32, @floatFromInt(app.draws)) / 60);
        app.draws += 1;
        if (app.running) app.plot.redraw();
    }
};

pub fn main(init: std.process.Init) !void {
    var app: App = .{};
    try lcgf_app.run(App, &app, init, .{ .title = "Surface", .size = .{ 480, 360 } });
    if (app.live and app.draws == 0) return error.NothingDrawn;
}
