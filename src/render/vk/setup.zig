//! A Vulkan setup for an application that brings no device of its own: the loader, instance,
//! device and renderer (`Setup`), and per window its surface, swapchain and frames (`Window`).
//! Moved from the Android shell, which made them itself. An application that owns its Vulkan
//! objects uses `Renderer` directly instead (vk.zig, "WHO OWNS WHAT").
//!
//!     var g: Setup = undefined;
//!     const surface = try g.init("app", &extensions, window, createSurface);
//!     var w = try Window.init(&g, surface, extent);
//!     try w.draw(&g, &draw, glyphs, viewport, scale, clear, extent); // per frame
//!     w.deinit(&g);
//!     g.deinit();

const loader = @import("loader.zig");
const device_mod = @import("device.zig");
const host = @import("host.zig");
const swapchain = @import("swapchain.zig");
const frame = @import("frame.zig");
const pass = @import("pass.zig");
const renderer = @import("renderer.zig");
const lcgr = @import("lcgr");
const c = loader.c;
const DrawList = lcgr.draw_list.DrawList;
const Glyphs = renderer.Glyphs;

/// The device and what is drawn with: made once, kept while windows come and go.
pub const Setup = struct {
    lib: loader.Library,
    instance: loader.Instance,
    device: device_mod.Device,
    once: host.Once,
    sampler: c.VkSampler,
    white: device_mod.Image,
    gfx: renderer.Renderer,
    format: c.VkFormat,

    /// Fills `g` in place (the renderer keeps a pointer to its device) and returns the first
    /// window's surface, made by `createSurface(&g.instance, window)`, which picks a device
    /// that can present to it. `extensions` are VK_KHR_surface and the platform's.
    pub fn init(g: *Setup, app_name: [:0]const u8, extensions: []const [*:0]const u8, window: anytype, comptime createSurface: anytype) !c.VkSurfaceKHR {
        g.lib = try loader.Library.open();
        errdefer g.lib.close();
        g.instance = try loader.Instance.init(&g.lib, .{ .app_name = app_name, .extensions = extensions });
        errdefer g.instance.deinit();
        const surface = try createSurface(&g.instance, window);
        errdefer swapchain.destroySurface(&g.instance, surface);
        g.device = try device_mod.Device.init(&g.instance, try device_mod.pick(&g.instance, surface), true);
        errdefer g.device.deinit();
        const d = &g.device;
        g.once = try host.Once.init(d);
        g.sampler = try host.nearestSampler(d);
        var h: host.Host = .{ .lib = g.lib, .instance = g.instance, .device = g.device, .once = g.once };
        g.white = try h.sampled(1, 1, &.{ 0xff, 0xff, 0xff, 0xff });
        // The swapchain's format: what the surface offers (Android: RGBA8, often BGRA8).
        var probe = try swapchain.Swapchain.init(&g.instance, d, surface, .{ .width = 1, .height = 1 }, null);
        g.format = probe.format;
        probe.deinit(d);
        g.gfx = try renderer.Renderer.init(d, .{ .format = g.format, .frames = 2 }, g.white.view, g.sampler);
        return surface;
    }

    pub fn deinit(g: *Setup) void {
        const d = &g.device;
        _ = d.fns.vkDeviceWaitIdle.?(d.handle);
        g.gfx.deinit(d);
        d.destroyImage(&g.white);
        d.fns.vkDestroySampler.?(d.handle, g.sampler, null);
        g.once.deinit(d);
        g.device.deinit();
        g.instance.deinit();
        g.lib.close();
    }
};

/// A window's surface, swapchain and frames: made when a window arrives, gone with it. Owns
/// `surface` from `init` on.
pub const Window = struct {
    surface: c.VkSurfaceKHR,
    chain: swapchain.Swapchain,
    frames: frame.Frames,

    pub fn init(g: *const Setup, surface: c.VkSurfaceKHR, extent: c.VkExtent2D) !Window {
        var chain = try swapchain.Swapchain.init(&g.instance, &g.device, surface, extent, null);
        errdefer chain.deinit(&g.device);
        return .{ .surface = surface, .chain = chain, .frames = try .init(&g.device, 2) };
    }

    pub fn deinit(w: *Window, g: *const Setup) void {
        _ = g.device.fns.vkDeviceWaitIdle.?(g.device.handle);
        w.frames.deinit(&g.device);
        w.chain.deinit(&g.device);
        swapchain.destroySurface(&g.instance, w.surface);
    }

    /// Draws `draw` into the next swapchain image, cleared to `clear`, and presents it. A
    /// swapchain whose size is not `want`, or that presented suboptimal, is rebuilt at `want`.
    /// error.OutOfDate: `rebuild` and draw the next frame; error.SurfaceLost or DeviceLost:
    /// make the window (and for DeviceLost the setup) again.
    pub fn draw(w: *Window, g: *Setup, list: *const DrawList, glyphs: Glyphs, viewport: [2]f32, scale: f32, clear: [4]f32, want: c.VkExtent2D) !void {
        const d = &g.device;
        if (want.width != w.chain.extent.width or want.height != w.chain.extent.height) try w.rebuild(g, want);
        const f = try w.frames.begin(d, &w.chain);
        g.gfx.prepare(f.slot, list, glyphs, viewport, scale);
        pass.begin(d, f.cmd, .{ .image = f.image, .view = f.view, .extent = w.chain.extent, .clear = clear });
        g.gfx.render(f.cmd, list);
        pass.end(d, f.cmd, .{ .image = f.image, .layout = c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR });
        if (try w.frames.present(d, &w.chain, f) == .suboptimal) try w.rebuild(g, want);
    }

    /// The swapchain made again at `want` (rotation, resize, out of date).
    pub fn rebuild(w: *Window, g: *const Setup, want: c.VkExtent2D) !void {
        try w.frames.resize(&g.device, &w.chain, &g.instance, w.surface, want);
    }
};
