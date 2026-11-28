//! A Vulkan setup for an application that brings no device of its own: the loader, instance,
//! device and renderer (`Setup`), and per window its surface, swapchain, frames and picture
//! (`Window`). Moved from the Android shell, which made them itself. An application that owns
//! its Vulkan objects uses `Renderer` directly instead (vk.zig, "WHO OWNS WHAT").
//!
//! The window keeps its picture: an image of its own, in the swapchain's format, that holds
//! what the window shows between frames. A frame draws the UI into the picture only inside its
//! damage, from rows that stay on the GPU until a new list replaces them, then copies the
//! picture to the swapchain image (docs/plans/window.md, "How a frame is drawn").
//!
//!     var g: Setup = undefined;
//!     const surface = try g.init("app", &extensions, window, createSurface, .{});
//!     var w = try Window.init(&g, surface, extent);
//!     // per frame, in one call:
//!     try w.draw(&g, list, glyphs, viewport, scale, clear, extent);
//!     // or in two, with the application's own work between them:
//!     const f = try w.begin(&g, extent);
//!     ... f.upload, f.upload.finish() and its passes, into f.cmd ...
//!     const rows: Window.Rows = .{ .list = list, ... };
//!     try w.present(&g, &f, .{ .rows = rows, .damage = list.damage, .clear = clear });
//!     w.deinit(&g);
//!     g.deinit();

const loader = @import("loader.zig");
const device_mod = @import("device.zig");
const host = @import("host.zig");
const swapchain = @import("swapchain.zig");
const frame = @import("frame.zig");
const pass = @import("pass.zig");
const renderer = @import("renderer.zig");
const lcgf = @import("lcgf");
const c = loader.c;
const gpu = @import("gpu.zig");
const std = @import("std");
const DrawList = lcgf.draw_list.DrawList;
const Region = lcgf.damage.Region;
const Glyphs = renderer.Glyphs;

/// The device and what is drawn with: made once, kept while windows come and go.
pub const Setup = struct {
    lib: loader.Library,
    instance: loader.Instance,
    device: device_mod.Device,
    once: host.Once,
    sampler: c.VkSampler,
    white: device_mod.Image,
    gfx: renderer.CanvasRenderer,
    format: c.VkFormat,
    /// The renderer's ring slot the next new list is uploaded to: never the slot of the rows
    /// drawn last, which a frame still in flight may be reading (`Window.present`).
    rows_next: u32,
    /// The same for the canvases' copy: counted apart, as a frame may write the canvases
    /// alone (`Ui.canvases`) and leave the rows where they are.
    canvases_next: u32,

    /// Canvas instance rows and polygon vertices the renderer keeps on the GPU
    /// (`renderer.Desc.canvas_rows`, `canvas_verts`); none: canvases draw nothing.
    pub const Canvas = struct { rows: u32 = 0, verts: u32 = 0 };

    /// Fills `g` in place (the renderer keeps a pointer to its device) and returns the first
    /// window's surface, made by `createSurface(&g.instance, window)`, which picks a device
    /// that can present to it. `extensions` are VK_KHR_surface and the platform's.
    // tidy: allow-fn(large-generic-function) one instance per platform's window type
    pub fn init(g: *Setup, app_name: [:0]const u8, extensions: []const [*:0]const u8, window: anytype, comptime createSurface: anytype, canvas: Canvas) !c.VkSurfaceKHR {
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
        const desc: renderer.Desc = .{
            .format = g.format,
            .frames = 2,
            .canvas_rows = canvas.rows,
            .canvas_verts = canvas.verts,
        };
        g.gfx = try .init(d, desc, g.white.view, g.sampler);
        g.rows_next = 0;
        g.canvases_next = 0;
        return surface;
    }

    /// `init` with no surface: a device with every one of `device_extensions`, drawing in
    /// `format`, for a window whose images go somewhere other than a swapchain (`Exported`).
    /// error.NoDevice: no device has them all.
    pub fn initOffscreen(
        g: *Setup,
        app_name: [:0]const u8,
        device_extensions: []const [*:0]const u8,
        format: c.VkFormat,
        canvas: Canvas,
    ) !void {
        std.debug.assert(device_extensions.len > 0);
        g.lib = try loader.Library.open();
        errdefer g.lib.close();
        g.instance = try loader.Instance.init(&g.lib, .{ .app_name = app_name });
        errdefer g.instance.deinit();
        const p = try device_mod.pickWith(&g.instance, null, device_extensions);
        g.device = try device_mod.Device.initWith(&g.instance, p, false, device_extensions);
        errdefer g.device.deinit();
        const d = &g.device;
        g.once = try host.Once.init(d);
        errdefer g.once.deinit(d);
        g.sampler = try host.nearestSampler(d);
        errdefer d.fns.vkDestroySampler.?(d.handle, g.sampler, null);
        var h: host.Host = .{
            .lib = g.lib,
            .instance = g.instance,
            .device = g.device,
            .once = g.once,
        };
        g.white = try h.sampled(1, 1, &.{ 0xff, 0xff, 0xff, 0xff });
        errdefer d.destroyImage(&g.white);
        g.format = format;
        const desc: renderer.Desc = .{
            .format = format,
            .frames = 2,
            .canvas_rows = canvas.rows,
            .canvas_verts = canvas.verts,
        };
        g.gfx = try .init(d, desc, g.white.view, g.sampler);
        g.rows_next = 0;
        g.canvases_next = 0;
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

/// A window's surface, swapchain, frames and picture: made when a window arrives, gone with
/// it. Owns `surface` from `init` on. One window per `Setup`: the rows on the GPU are the
/// setup's renderer's, and a frame with no new list draws the last list any window gave.
pub const Window = struct {
    surface: c.VkSurfaceKHR,
    chain: swapchain.Swapchain,
    frames: frame.Frames,
    /// What the window shows, kept between frames: the swapchain's size and format, colour
    /// attachment and transfer source. Rests in TRANSFER_SRC_OPTIMAL between frames.
    picture: device_mod.Image,
    /// The picture holds nothing yet (new, or made again with the swapchain): the next
    /// `present` draws all of it, whatever damage it is given.
    lost: bool = true,
    /// The last present was suboptimal or out of date: the next `begin` makes the swapchain
    /// again.
    stale: bool = false,

    /// How long `begin` waits for the frame two before and for an image. FIFO hands out an
    /// image within a refresh or two when the window is shown; past this it is not.
    pub const wait_ns: u64 = 100 * std.time.ns_per_ms;

    /// A frame between `begin` and `present`: acquired, its command buffer recording outside
    /// any pass.
    pub const Frame = struct {
        /// The frame's command buffer. An application records its own uploads and passes into
        /// it before `present`; at `present` it must be outside any pass.
        cmd: c.VkCommandBuffer,
        /// The frame's one upload phase, for the application's `lcgf_render.gpu` writes.
        /// `upload.finish()` ends it and gives the encoder for its passes. The UI's rows do
        /// not go through it: `present` writes them to mapped memory.
        upload: gpu.Upload,
        acquired: frame.Frame,
    };

    /// What `present` draws into the picture.
    pub const Ui = struct {
        /// A new list to upload and draw from, or null: the list of the last `rows` given is
        /// unchanged and still alive, and its rows on the GPU are drawn again with no upload.
        rows: ?Rows,
        /// Logical pixels to draw again: the list's `damage`, with any rect of the
        /// application's added. Ignored (everything is drawn) while the picture is `lost`.
        /// Outside it the picture keeps last frame's pixels.
        damage: Region,
        /// Straight RGBA, 0 to 1: each damage rect is cleared to it before the list draws.
        clear: [4]f32,
        /// With no new `rows`: the kept list's canvas rows changed (a camera, a palette, an
        /// instance's rows), so their uniforms and dirty rows are written again, the list's
        /// quads not. Implied by `rows`.
        canvases: bool = false,
    };

    pub const Rows = struct {
        /// Not culled to its damage (`Context.trackDamageWhole`, or no damage tracking): a
        /// later frame may draw any rect of the window from these rows.
        list: *const DrawList,
        glyphs: Glyphs,
        viewport: [2]f32,
        scale: f32,
    };

    /// error.NoTransferDst: the surface's swapchain images cannot be copied into, so the
    /// picture cannot be shown. Asserts that the renderer has two ring slots.
    pub fn init(g: *const Setup, surface: c.VkSurfaceKHR, extent: c.VkExtent2D) !Window {
        // A new list goes to the ring slot the rows drawn last are not in, which is free only
        // while at most one other frame is in flight (`present`).
        std.debug.assert(g.gfx.desc.frames == 2);
        const d = &g.device;
        var chain = try swapchain.Swapchain.init(&g.instance, d, surface, extent, null);
        errdefer chain.deinit(d);
        if (chain.usage & c.VK_IMAGE_USAGE_TRANSFER_DST_BIT == 0) return error.NoTransferDst;
        var picture = try makePicture(d, &chain);
        errdefer d.destroyImage(&picture);
        var frames: frame.Frames = try .init(d, g.gfx.desc.frames);
        frames.wait_ns = wait_ns;
        return .{ .surface = surface, .chain = chain, .frames = frames, .picture = picture };
    }

    pub fn deinit(w: *Window, g: *const Setup) void {
        _ = g.device.fns.vkDeviceWaitIdle.?(g.device.handle);
        w.frames.deinit(&g.device);
        g.device.destroyImage(&w.picture);
        w.chain.deinit(&g.device);
        swapchain.destroySurface(&g.instance, w.surface);
    }

    /// `begin` and `present` in one call, for a host with nothing of its own to draw: uploads
    /// `list` and draws it inside `list.damage` (all of the window unless the context tracks
    /// damage), each rect cleared to `clear` first.
    pub fn draw(w: *Window, g: *Setup, list: *const DrawList, glyphs: Glyphs, viewport: [2]f32, scale: f32, clear: [4]f32, want: c.VkExtent2D) !void {
        const f = try w.begin(g, want);
        const rows: Rows = .{
            .list = list,
            .glyphs = glyphs,
            .viewport = viewport,
            .scale = scale,
        };
        try w.present(g, &f, .{ .rows = rows, .damage = list.damage, .clear = clear });
    }

    /// Acquires the next swapchain image and begins the frame's command buffer. A swapchain
    /// whose size is not `want`, or that the last present found suboptimal or out of date, is
    /// made again first, and an acquire that finds it out of date makes it again once; either
    /// way the picture is made again and the next `present` draws all of it. Blocks on the
    /// fence of the frame two before and on the acquire (FIFO paces it to the display).
    /// error.NotShown: no image within `wait_ns` (a hidden, minimised or blanked window, whose
    /// images the presentation engine keeps); nothing was drawn, the picture and the damage
    /// owed are as they were, so wait for an event and try again.
    /// error.ZeroExtent: the window is minimised, try again when it has a size;
    /// error.SurfaceLost or DeviceLost: make the window (and for DeviceLost the setup) again.
    pub fn begin(w: *Window, g: *Setup, want: c.VkExtent2D) !Frame {
        const d = &g.device;
        const same = want.width == w.chain.extent.width and want.height == w.chain.extent.height;
        if (w.stale or !same) try w.rebuild(g, want);
        const acquired = w.frames.begin(d, &w.chain) catch |e| switch (e) {
            error.OutOfDate => again: {
                try w.rebuild(g, want);
                break :again try w.frames.begin(d, &w.chain);
            },
            else => return e,
        };
        std.debug.assert(!w.stale);
        std.debug.assert(w.picture.extent.width == w.chain.extent.width);
        const upload: gpu.Upload = .begin(.wrap(d), acquired.cmd);
        return .{ .cmd = acquired.cmd, .upload = upload, .acquired = acquired };
    }

    /// Draws the UI into the picture, copies the picture to `f`'s swapchain image and presents
    /// it. With `ui.rows` the list is uploaded first; without, the rows of the last list are
    /// drawn again. One pass on the picture that loads it; per damage rect a clear and the
    /// whole list scissored to the rect: the scissor culls, so the list stays whole.
    /// A suboptimal or out-of-date present is not an error: the frame was drawn, and the next
    /// `begin` makes the swapchain again. Asserts that some `rows` were given before.
    pub fn present(w: *Window, g: *Setup, f: *const Frame, ui: Ui) !void {
        std.debug.assert(ui.rows != null or g.gfx.list != null);
        std.debug.assert(w.picture.extent.height == w.chain.extent.height);
        const d = &g.device;
        const cmd = f.cmd;
        if (ui.rows) |r| {
            g.gfx.prepareRows(g.rows_next, r.list, r.glyphs, r.viewport, r.scale);
            g.rows_next = (g.rows_next + 1) % g.gfx.desc.frames;
        }
        if (ui.rows != null or ui.canvases) {
            g.gfx.prepareCanvases(g.canvases_next);
            g.canvases_next = (g.canvases_next + 1) % g.gfx.desc.frames;
        }
        const image = w.picture.handle;
        const attachment = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        const rest = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        const was: c.VkImageLayout = if (w.lost) c.VK_IMAGE_LAYOUT_UNDEFINED else rest;
        // Ordered after the last frame's copy out of it, which `pass.begin`'s barrier is not.
        pass.transition(d, cmd, image, was, attachment);
        const extent = w.picture.extent;
        pass.begin(d, cmd, .{
            .image = image,
            .view = w.picture.view,
            .extent = extent,
            .clear = null,
            .from = attachment,
        });
        drawDamage(g, cmd, if (w.lost) .everything else ui.damage, ui.clear, extent);
        pass.end(d, cmd, .{ .image = image, .layout = rest });
        copyPicture(d, cmd, &w.picture, f.acquired.image, c.VK_IMAGE_LAYOUT_PRESENT_SRC_KHR);
        w.lost = false;
        const presented = w.frames.present(d, &w.chain, f.acquired) catch |e| switch (e) {
            error.OutOfDate => .suboptimal,
            else => return e,
        };
        w.stale = presented == .suboptimal;
    }

    /// The swapchain and the picture made again at `want` (rotation, resize, out of date). The
    /// next `present` draws all of the picture: from new rows when the size changed, since the
    /// last list was laid out for the old one.
    pub fn rebuild(w: *Window, g: *const Setup, want: c.VkExtent2D) !void {
        const d = &g.device;
        try w.frames.resize(d, &w.chain, &g.instance, w.surface, want);
        d.destroyImage(&w.picture);
        w.picture = try makePicture(d, &w.chain);
        w.lost = true;
        w.stale = false;
    }
};

/// A window whose frames go to images the host shares with a compositor (dma-bufs, for a
/// Wayland shell that speaks the protocol itself and so cannot give Vulkan a surface) instead
/// of a swapchain. As `Window`, it keeps its picture and draws only the damage into it; each
/// frame then copies the picture whole into one of `count` exported images (`Shared`), which
/// the host attaches when `present` returns. Needs a setup from `initOffscreen` with
/// `device_extensions`, drawing in `format` (DRM_FORMAT_XRGB8888 to the compositor).
pub const Exported = struct {
    picture: device_mod.Image,
    images: [count]Shared,
    extent: c.VkExtent2D,
    /// The picture holds nothing yet: the next `present` draws all of it.
    lost: bool = true,
    pools: [frames]c.VkCommandPool,
    cmds: [frames]c.VkCommandBuffer,
    fences: [frames]c.VkFence,
    /// The frame slot the next `begin` uses.
    next: u32 = 0,
    fns: Fns,

    /// Images shared, so the compositor may hold two while the next is drawn.
    pub const count = 3;
    const frames = 2;
    pub const format = c.VK_FORMAT_B8G8R8A8_UNORM;
    pub const device_extensions = [_][*:0]const u8{
        "VK_KHR_external_memory_fd",
        "VK_EXT_external_memory_dma_buf",
        "VK_EXT_image_drm_format_modifier",
    };
    /// How long `begin` waits for its frame slot's last frame.
    pub const wait_ns = Window.wait_ns;

    /// One exported image: LINEAR (DRM modifier 0), its memory a dma-buf.
    pub const Shared = struct {
        image: c.VkImage = null,
        memory: c.VkDeviceMemory = null,
        /// The dma-buf: the host's to share and the image's to close (`deinit`, `resize`).
        fd: i32 = -1,
        offset: u64 = 0,
        stride: u64 = 0,
        size: u64 = 0,
    };

    const Fns = struct {
        vkGetMemoryFdKHR: c.PFN_vkGetMemoryFdKHR,
        vkGetImageSubresourceLayout: c.PFN_vkGetImageSubresourceLayout,
    };

    pub const Frame = struct {
        cmd: c.VkCommandBuffer,
        /// The frame's one upload phase, for the application's `lcgf_render.gpu` writes.
        upload: gpu.Upload,
        slot: u32,
    };

    pub fn init(g: *const Setup, extent: c.VkExtent2D) !Exported {
        std.debug.assert(g.gfx.desc.frames == frames);
        const d = &g.device;
        const get = g.instance.fns.vkGetDeviceProcAddr.?;
        var e: Exported = .{
            .picture = undefined,
            .images = @splat(.{}),
            .extent = extent,
            .pools = @splat(null),
            .cmds = @splat(null),
            .fences = @splat(null),
            .fns = .{
                .vkGetMemoryFdKHR = @ptrCast(get(d.handle, "vkGetMemoryFdKHR")),
                .vkGetImageSubresourceLayout = @ptrCast(get(d.handle, "vkGetImageSubresourceLayout")),
            },
        };
        if (e.fns.vkGetMemoryFdKHR == null or e.fns.vkGetImageSubresourceLayout == null)
            return error.MissingExtension;
        errdefer e.deinit(g);
        for (0..frames) |i| {
            try loader.check(d.fns.vkCreateCommandPool.?(d.handle, &.{
                .sType = c.VK_STRUCTURE_TYPE_COMMAND_POOL_CREATE_INFO,
                .flags = c.VK_COMMAND_POOL_CREATE_TRANSIENT_BIT,
                .queueFamilyIndex = d.family,
            }, null, &e.pools[i]));
            try loader.check(d.fns.vkAllocateCommandBuffers.?(d.handle, &.{
                .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_ALLOCATE_INFO,
                .commandPool = e.pools[i],
                .level = c.VK_COMMAND_BUFFER_LEVEL_PRIMARY,
                .commandBufferCount = 1,
            }, &e.cmds[i]));
            try loader.check(d.fns.vkCreateFence.?(d.handle, &.{
                .sType = c.VK_STRUCTURE_TYPE_FENCE_CREATE_INFO,
                .flags = c.VK_FENCE_CREATE_SIGNALED_BIT,
            }, null, &e.fences[i]));
        }
        e.picture.handle = null;
        try e.make(g, extent);
        return e;
    }

    pub fn deinit(e: *Exported, g: *const Setup) void {
        const d = &g.device;
        _ = d.fns.vkDeviceWaitIdle.?(d.handle);
        e.drop(g);
        for (0..frames) |i| {
            if (e.fences[i] != null) d.fns.vkDestroyFence.?(d.handle, e.fences[i], null);
            if (e.pools[i] != null) d.fns.vkDestroyCommandPool.?(d.handle, e.pools[i], null);
        }
    }

    /// The picture and the images made again at `extent`; every old dma-buf closed, so the
    /// host shares the new ones before attaching any.
    pub fn resize(e: *Exported, g: *const Setup, extent: c.VkExtent2D) !void {
        _ = g.device.fns.vkDeviceWaitIdle.?(g.device.handle);
        e.drop(g);
        try e.make(g, extent);
    }

    /// Waits until frame slot `next` is free and begins its command buffer. error.NotShown:
    /// its last frame did not finish within `wait_ns`; nothing was touched.
    pub fn begin(e: *Exported, g: *Setup) !Frame {
        const d = &g.device;
        const i = e.next;
        const waited = d.fns.vkWaitForFences.?(d.handle, 1, &e.fences[i], c.VK_TRUE, wait_ns);
        if (waited == c.VK_TIMEOUT) return error.NotShown;
        try loader.check(waited);
        try loader.check(d.fns.vkResetFences.?(d.handle, 1, &e.fences[i]));
        try loader.check(d.fns.vkResetCommandPool.?(d.handle, e.pools[i], 0));
        try loader.check(d.fns.vkBeginCommandBuffer.?(e.cmds[i], &.{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_BEGIN_INFO,
            .flags = c.VK_COMMAND_BUFFER_USAGE_ONE_TIME_SUBMIT_BIT,
        }));
        return .{ .cmd = e.cmds[i], .upload = .begin(.wrap(d), e.cmds[i]), .slot = i };
    }

    /// Draws the UI into the picture as `Window.present` does, copies the picture into image
    /// `k`, submits, and waits for the GPU: a dma-buf carries no fence the compositor would
    /// wait on, so the image is finished when this returns and may be attached.
    pub fn present(e: *Exported, g: *Setup, f: *const Frame, ui: Window.Ui, k: u32) !void {
        std.debug.assert(ui.rows != null or g.gfx.list != null);
        std.debug.assert(k < count);
        const d = &g.device;
        const cmd = f.cmd;
        if (ui.rows) |r| {
            g.gfx.prepareRows(g.rows_next, r.list, r.glyphs, r.viewport, r.scale);
            g.rows_next = (g.rows_next + 1) % g.gfx.desc.frames;
        }
        if (ui.rows != null or ui.canvases) {
            g.gfx.prepareCanvases(g.canvases_next);
            g.canvases_next = (g.canvases_next + 1) % g.gfx.desc.frames;
        }
        const image = e.picture.handle;
        const attachment = c.VK_IMAGE_LAYOUT_COLOR_ATTACHMENT_OPTIMAL;
        const rest = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
        const was: c.VkImageLayout = if (e.lost) c.VK_IMAGE_LAYOUT_UNDEFINED else rest;
        pass.transition(d, cmd, image, was, attachment);
        pass.begin(d, cmd, .{
            .image = image,
            .view = e.picture.view,
            .extent = e.extent,
            .clear = null,
            .from = attachment,
        });
        drawDamage(g, cmd, if (e.lost) .everything else ui.damage, ui.clear, e.extent);
        pass.end(d, cmd, .{ .image = image, .layout = rest });
        copyPicture(d, cmd, &e.picture, e.images[k].image, c.VK_IMAGE_LAYOUT_GENERAL);
        e.lost = false;
        try loader.check(d.fns.vkEndCommandBuffer.?(cmd));
        const info: c.VkCommandBufferSubmitInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_COMMAND_BUFFER_SUBMIT_INFO,
            .commandBuffer = cmd,
        };
        try loader.check(d.fns.vkQueueSubmit2.?(d.queue, 1, &.{
            .sType = c.VK_STRUCTURE_TYPE_SUBMIT_INFO_2,
            .commandBufferInfoCount = 1,
            .pCommandBufferInfos = &info,
        }, e.fences[f.slot]));
        e.next = (f.slot + 1) % frames;
        // ponytail: the CPU waits for each frame; an explicit-sync fence (linux-drm-syncobj)
        // would let the compositor wait instead.
        const max = std.math.maxInt(u64);
        try loader.check(d.fns.vkWaitForFences.?(d.handle, 1, &e.fences[f.slot], c.VK_TRUE, max));
    }

    fn make(e: *Exported, g: *const Setup, extent: c.VkExtent2D) !void {
        const d = &g.device;
        e.extent = extent;
        e.picture = try d.createImage(.{
            .width = extent.width,
            .height = extent.height,
            .format = format,
            .usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
        });
        e.lost = true;
        for (&e.images) |*s| s.* = try e.share(d, extent);
    }

    fn drop(e: *Exported, g: *const Setup) void {
        const d = &g.device;
        if (e.picture.handle != null) d.destroyImage(&e.picture);
        for (&e.images) |*s| {
            if (s.fd >= 0) _ = std.os.linux.close(s.fd);
            if (s.image != null) d.fns.vkDestroyImage.?(d.handle, s.image, null);
            if (s.memory != null) d.fns.vkFreeMemory.?(d.handle, s.memory, null);
            s.* = .{};
        }
    }

    /// One LINEAR image of `extent` with dedicated, exportable memory, and its dma-buf.
    fn share(e: *const Exported, d: *const device_mod.Device, extent: c.VkExtent2D) !Shared {
        std.debug.assert(extent.width > 0);
        const dma_buf = c.VK_EXTERNAL_MEMORY_HANDLE_TYPE_DMA_BUF_BIT_EXT;
        const linear = [1]u64{0};
        const modifiers: c.VkImageDrmFormatModifierListCreateInfoEXT = .{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_DRM_FORMAT_MODIFIER_LIST_CREATE_INFO_EXT,
            .drmFormatModifierCount = 1,
            .pDrmFormatModifiers = &linear,
        };
        const external: c.VkExternalMemoryImageCreateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_EXTERNAL_MEMORY_IMAGE_CREATE_INFO,
            .pNext = &modifiers,
            .handleTypes = dma_buf,
        };
        var s: Shared = .{};
        errdefer {
            if (s.image != null) d.fns.vkDestroyImage.?(d.handle, s.image, null);
            if (s.memory != null) d.fns.vkFreeMemory.?(d.handle, s.memory, null);
        }
        try loader.check(d.fns.vkCreateImage.?(d.handle, &.{
            .sType = c.VK_STRUCTURE_TYPE_IMAGE_CREATE_INFO,
            .pNext = &external,
            .imageType = c.VK_IMAGE_TYPE_2D,
            .format = format,
            .extent = .{ .width = extent.width, .height = extent.height, .depth = 1 },
            .mipLevels = 1,
            .arrayLayers = 1,
            .samples = c.VK_SAMPLE_COUNT_1_BIT,
            .tiling = c.VK_IMAGE_TILING_DRM_FORMAT_MODIFIER_EXT,
            .usage = c.VK_IMAGE_USAGE_TRANSFER_DST_BIT,
            .sharingMode = c.VK_SHARING_MODE_EXCLUSIVE,
            .initialLayout = c.VK_IMAGE_LAYOUT_UNDEFINED,
        }, null, &s.image));
        var req: c.VkMemoryRequirements = undefined;
        d.fns.vkGetImageMemoryRequirements.?(d.handle, s.image, &req);
        const index = d.memoryType(req.memoryTypeBits, 0) orelse return error.OutOfMemory;
        const dedicated: c.VkMemoryDedicatedAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_DEDICATED_ALLOCATE_INFO,
            .image = s.image,
        };
        const export_info: c.VkExportMemoryAllocateInfo = .{
            .sType = c.VK_STRUCTURE_TYPE_EXPORT_MEMORY_ALLOCATE_INFO,
            .pNext = &dedicated,
            .handleTypes = dma_buf,
        };
        try loader.check(d.fns.vkAllocateMemory.?(d.handle, &.{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_ALLOCATE_INFO,
            .pNext = &export_info,
            .allocationSize = req.size,
            .memoryTypeIndex = index,
        }, null, &s.memory));
        try loader.check(d.fns.vkBindImageMemory.?(d.handle, s.image, s.memory, 0));
        var layout: c.VkSubresourceLayout = undefined;
        const plane: c.VkImageSubresource = .{ .aspectMask = c.VK_IMAGE_ASPECT_MEMORY_PLANE_0_BIT_EXT };
        e.fns.vkGetImageSubresourceLayout.?(d.handle, s.image, &plane, &layout);
        s.offset = layout.offset;
        s.stride = layout.rowPitch;
        s.size = req.size;
        var fd: c_int = -1;
        try loader.check(e.fns.vkGetMemoryFdKHR.?(d.handle, &.{
            .sType = c.VK_STRUCTURE_TYPE_MEMORY_GET_FD_INFO_KHR,
            .memory = s.memory,
            .handleType = dma_buf,
        }, &fd));
        s.fd = fd;
        return s;
    }
};

// ---- private ----

fn makePicture(d: *const device_mod.Device, chain: *const swapchain.Swapchain) !device_mod.Image {
    return d.createImage(.{
        .width = chain.extent.width,
        .height = chain.extent.height,
        .format = chain.format,
        .usage = c.VK_IMAGE_USAGE_COLOR_ATTACHMENT_BIT | c.VK_IMAGE_USAGE_TRANSFER_SRC_BIT,
    });
}

/// Per non-empty rect of `damage`: cleared to `clear`, then the renderer's last list drawn
/// with its scissor narrowed to the rect. Inside a pass on a target of `size`.
fn drawDamage(
    g: *Setup,
    cmd: c.VkCommandBuffer,
    damage: Region,
    clear: [4]f32,
    size: c.VkExtent2D,
) void {
    std.debug.assert(size.width > 0);
    std.debug.assert(size.height > 0);
    const d = &g.device;
    const list = g.gfx.list.?;
    const whole = g.gfx.scissor;
    for (0..lcgf.damage.max_rects) |k| {
        const box = damage.rect(@intCast(k));
        const r = Region.scissor(box, .{ size.width, size.height }, g.gfx.scale);
        if (r[2] == 0 or r[3] == 0) continue;
        const rect: c.VkRect2D = .{
            .offset = .{ .x = @intCast(r[0]), .y = @intCast(r[1]) },
            .extent = .{ .width = r[2], .height = r[3] },
        };
        d.fns.vkCmdClearAttachments.?(cmd, 1, &.{
            .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
            .colorAttachment = 0,
            .clearValue = .{ .color = .{ .float32 = clear } },
        }, 1, &.{ .rect = rect, .layerCount = 1 });
        g.gfx.scissor = rect;
        g.gfx.render(cmd, list);
    }
    g.gfx.scissor = whole;
}

/// Copies `picture` (in TRANSFER_SRC_OPTIMAL) into `image`, of its size, and leaves `image`
/// in layout `then` (ready to present, or to share).
fn copyPicture(
    d: *const device_mod.Device,
    cmd: c.VkCommandBuffer,
    picture: *const device_mod.Image,
    image: c.VkImage,
    then: c.VkImageLayout,
) void {
    std.debug.assert(picture.handle != null);
    std.debug.assert(image != null);
    const src = c.VK_IMAGE_LAYOUT_TRANSFER_SRC_OPTIMAL;
    const dst = c.VK_IMAGE_LAYOUT_TRANSFER_DST_OPTIMAL;
    pass.transition(d, cmd, image, c.VK_IMAGE_LAYOUT_UNDEFINED, dst);
    const layers: c.VkImageSubresourceLayers = .{
        .aspectMask = c.VK_IMAGE_ASPECT_COLOR_BIT,
        .layerCount = 1,
    };
    d.fns.vkCmdCopyImage.?(cmd, picture.handle, src, image, dst, 1, &.{
        .srcSubresource = layers,
        .dstSubresource = layers,
        .extent = .{ .width = picture.extent.width, .height = picture.extent.height, .depth = 1 },
    });
    pass.transition(d, cmd, image, dst, then);
}

const testing = std.testing;
const Context = lcgf.context.Context;
const Color = lcgf.types.Color;

/// A setup and window over a headless surface, and a context whose frames fill the window
/// with one colour. Filled in place: the renderer points at the setup's device.
const Headless = struct {
    g: Setup,
    w: Window,
    ctx: Context,
    in: lcgf.input.Input,

    const limits: lcgf.context.Limits = .{
        .nodes = 4,
        .texts = 1,
        .customs = 1,
        .strings = 16,
        .depth = 4,
    };
    var buffer: [Context.requiredBytes(limits)]u8 align(lcgf.mem.column_align) = undefined;

    fn init(h: *Headless, width: u32, height: u32) !void {
        const extensions = &swapchain.headless_extensions;
        const surface = try h.g.init("test", extensions, {}, headlessSurface, .{});
        errdefer h.g.deinit();
        h.w = try .init(&h.g, surface, .{ .width = width, .height = height });
        h.ctx = try .init(&buffer, limits);
        h.in = .{ .viewport = .{ @floatFromInt(width), @floatFromInt(height) } };
    }

    fn deinit(h: *Headless) void {
        h.w.deinit(&h.g);
        h.g.deinit();
    }

    fn headlessSurface(instance: *const loader.Instance, _: void) !c.VkSurfaceKHR {
        return swapchain.headlessSurface(instance);
    }

    /// A list that is all `color`, laid out at `in.viewport`.
    fn fill(h: *Headless, color: Color) *DrawList {
        var f = h.ctx.begin(&h.in);
        _ = f.leaf(.none, .{ .size = .{ .fill, .fill }, .fill = color });
        _ = f.end(.{});
        return &h.ctx.draw;
    }

    /// One frame at `in.viewport`, waited for: `list` uploaded (or none), `damage` drawn.
    fn present(h: *Headless, list: ?*const DrawList, damage: Region) !void {
        const vp = h.in.viewport;
        const size: c.VkExtent2D = .{
            .width = @intFromFloat(vp[0]),
            .height = @intFromFloat(vp[1]),
        };
        const f = try h.w.begin(&h.g, size);
        var rows: ?Window.Rows = null;
        if (list) |l| rows = .{ .list = l, .glyphs = .{}, .viewport = vp, .scale = 1 };
        try h.w.present(&h.g, &f, .{ .rows = rows, .damage = damage, .clear = .{ 0, 0, 0, 1 } });
        try h.w.frames.wait(&h.g.device);
    }

    /// The picture's pixels, RGBA, into `out`.
    fn read(h: *Headless, out: []u8) !void {
        const g = &h.g;
        var view: host.Host = .{
            .lib = g.lib,
            .instance = g.instance,
            .device = g.device,
            .once = g.once,
        };
        try view.readback(h.w.picture.handle, h.w.picture.extent, out);
        if (h.w.picture.format != c.VK_FORMAT_B8G8R8A8_UNORM) return;
        var i: usize = 0;
        while (i < out.len) : (i += 4) std.mem.swap(u8, &out[i], &out[i + 2]);
    }
};

fn at(px: []const u8, width: u32, x: usize, y: usize) [4]u8 {
    return px[(y * width + x) * 4 ..][0..4].*;
}

const blue = [4]u8{ 0, 0, 255, 255 };
const red = [4]u8{ 255, 0, 0, 255 };

test "window: a red list damaged in a 32 x 32 rect is red there and the blue frame elsewhere" {
    var h: Headless = undefined;
    try h.init(64, 48);
    defer h.deinit();
    try h.present(h.fill(.rgb(0, 0, 255)), .everything);
    const list = h.fill(.rgb(255, 0, 0));
    list.damage = .empty;
    list.damage.add(.{ 8, 8, 40, 40 });
    try h.present(list, list.damage);
    var px: [64 * 48 * 4]u8 = undefined;
    try h.read(&px);
    for (0..48) |y| for (0..64) |x| {
        const inside = x >= 8 and x < 40 and y >= 8 and y < 40;
        try testing.expectEqual(if (inside) red else blue, at(&px, 64, x, y));
    };
}

test "window: a frame with no new list uploads nothing and draws its damage from the rows kept" {
    var h: Headless = undefined;
    try h.init(64, 48);
    defer h.deinit();
    try h.present(h.fill(.rgb(0, 0, 255)), .everything);
    const list = h.fill(.rgb(255, 0, 0));
    list.damage = .empty;
    list.damage.add(.{ 8, 8, 40, 40 });
    try h.present(list, list.damage);
    var before: [64 * 48 * 4]u8 = undefined;
    try h.read(&before);
    const ring = try testing.allocator.dupe(u8, h.g.gfx.ring.mapped);
    defer testing.allocator.free(ring);

    // Nothing damaged: the same pixels, and not a byte of either ring slot written.
    try h.present(null, .empty);
    var px: [64 * 48 * 4]u8 = undefined;
    try h.read(&px);
    try testing.expectEqualSlices(u8, &before, &px);
    try testing.expectEqualSlices(u8, ring, h.g.gfx.ring.mapped);

    // A rect damaged with no new list (a surface's, in a later stage) is drawn from the red
    // rows still on the GPU; the rest keeps its pixels.
    var surface: Region = .empty;
    surface.add(.{ 48, 0, 64, 16 });
    try h.present(null, surface);
    try h.read(&px);
    try testing.expectEqualSlices(u8, ring, h.g.gfx.ring.mapped);
    try testing.expectEqual(red, at(&px, 64, 48, 0));
    try testing.expectEqual(red, at(&px, 64, 63, 15));
    try testing.expectEqual(blue, at(&px, 64, 47, 0));
    try testing.expectEqual(blue, at(&px, 64, 48, 16));
    try testing.expectEqual(red, at(&px, 64, 8, 8));
    try testing.expectEqual(blue, at(&px, 64, 0, 0));
}

test "window: a resize makes the picture again and draws all of it, whatever the damage" {
    var h: Headless = undefined;
    try h.init(64, 48);
    defer h.deinit();
    try h.present(h.fill(.rgb(0, 0, 255)), .everything);
    h.in.viewport = .{ 80, 60 };
    const list = h.fill(.rgb(255, 0, 0));
    try h.present(list, .empty);
    try testing.expectEqual(@as(u32, 80), h.w.picture.extent.width);
    var px: [80 * 60 * 4]u8 = undefined;
    try h.read(&px);
    for (0..60) |y| for (0..80) |x| try testing.expectEqual(red, at(&px, 80, x, y));
}

/// The bytes of dma-buf `s`, mapped for reading, or null when it cannot be mapped.
fn mapShared(s: *const Exported.Shared) ?[]const u8 {
    const linux = std.os.linux;
    const prot: linux.PROT = .{ .READ = true };
    const addr = linux.mmap(null, @intCast(s.size), prot, .{ .TYPE = .SHARED }, s.fd, 0);
    if (linux.errno(addr) != .SUCCESS) return null;
    return @as([*]const u8, @ptrFromInt(addr))[0..@intCast(s.size)];
}

test "exported: a frame drawn into a shared image is in its dma-buf, damage and all" {
    var g: Setup = undefined;
    const exts = &Exported.device_extensions;
    g.initOffscreen("test", exts, Exported.format, .{}) catch |e| switch (e) {
        error.NoDevice => return error.SkipZigTest,
        else => return e,
    };
    defer g.deinit();
    var e = Exported.init(&g, .{ .width = 64, .height = 48 }) catch |err| switch (err) {
        // No dma-buf export here (lavapipe without /dev/udmabuf).
        error.InitializationFailed, error.OutOfMemory, error.Unknown => return error.SkipZigTest,
        else => return err,
    };
    defer e.deinit(&g);
    var ctx = try Context.init(&Headless.buffer, Headless.limits);
    const in: lcgf.input.Input = .{ .viewport = .{ 64, 48 } };
    const Fill = struct {
        fn list(cx: *Context, i: *const lcgf.input.Input, color: Color) *DrawList {
            var f = cx.begin(i);
            _ = f.leaf(.none, .{ .size = .{ .fill, .fill }, .fill = color });
            _ = f.end(.{});
            return &cx.draw;
        }
    };
    const clear: [4]f32 = .{ 0, 0, 0, 1 };
    var f = try e.begin(&g);
    const blue_list = Fill.list(&ctx, &in, .rgb(0, 0, 255));
    const vp = in.viewport;
    var rows: Window.Rows = .{ .list = blue_list, .glyphs = .{}, .viewport = vp, .scale = 1 };
    try e.present(&g, &f, .{ .rows = rows, .damage = .everything, .clear = clear }, 0);
    const red_list = Fill.list(&ctx, &in, .rgb(255, 0, 0));
    var damage: Region = .empty;
    damage.add(.{ 8, 8, 40, 40 });
    rows.list = red_list;
    f = try e.begin(&g);
    try e.present(&g, &f, .{ .rows = rows, .damage = damage, .clear = clear }, 1);
    const s = &e.images[1];
    const bytes = mapShared(s) orelse return error.SkipZigTest;
    defer _ = std.os.linux.munmap(bytes.ptr, bytes.len);
    try testing.expect(s.stride >= 64 * 4);
    for (0..48) |y| for (0..64) |x| {
        const p = bytes[@intCast(s.offset + y * s.stride + x * 4)..][0..4];
        const inside = x >= 8 and x < 40 and y >= 8 and y < 40;
        // B, G, R, X: XRGB8888 as little-endian words.
        const want: [3]u8 = if (inside) .{ 0, 0, 255 } else .{ 255, 0, 0 };
        try testing.expectEqualSlices(u8, &want, p[0..3]);
    };
}
