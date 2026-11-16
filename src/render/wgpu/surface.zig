//! A window surface for the wgpu back end: configure it, follow the window's size, acquire and
//! present frames. The host (a shell) creates the `WGPUSurface` from its window and owns it and
//! the loop; this only keeps the configuration in step with the size the host reports.
//!
//!     var surface = Surface.init(raw_surface, adapter, device);
//!     surface.resize(w, h);                         // on every size event, physical pixels
//!     if (surface.acquire()) |frame| {               // null: minimised, or try again next frame
//!         gfx.prepare(queue, draw, glyphs, .{ w / scale, h / scale }, scale);
//!         ... begin a pass on frame.view, draw, submit ...
//!         surface.present(frame);
//!     }
//!
//! Resizing never touches the renderer: its pipelines depend on the format only, and the size
//! reaches the shader through `prepare`'s viewport and scale (`Globals`) every frame.

const std = @import("std");
const c = @import("wgpu_c");

pub const Frame = struct { texture: c.WGPUTexture, view: c.WGPUTextureView, reconfigure: bool };

pub const Surface = struct {
    surface: c.WGPUSurface,
    device: c.WGPUDevice,
    /// The format to create the renderer's pipelines with (`Renderer.Desc.format`).
    format: c.WGPUTextureFormat,
    /// Size the surface is configured at, in physical pixels; 0 before the first configure.
    width: u32 = 0,
    height: u32 = 0,
    /// Size the host last reported.
    wanted: [2]u32 = .{ 0, 0 },

    pub fn init(surface: c.WGPUSurface, adapter: c.WGPUAdapter, device: c.WGPUDevice) Surface {
        var caps: c.WGPUSurfaceCapabilities = .{};
        _ = c.wgpuSurfaceGetCapabilities(surface, adapter, &caps);
        defer c.wgpuSurfaceCapabilitiesFreeMembers(caps);
        const formats: []const c.WGPUTextureFormat = if (caps.formats) |f| f[0..caps.formatCount] else &.{};
        return .{ .surface = surface, .device = device, .format = pickFormat(formats) };
    }

    /// Records the window's new size; the surface is reconfigured on the next `acquire`, so a
    /// burst of size events costs one configure.
    pub fn resize(s: *Surface, width: u32, height: u32) void {
        s.wanted = .{ width, height };
    }

    pub fn configure(s: *Surface) void {
        c.wgpuSurfaceConfigure(s.surface, &.{
            .device = s.device,
            .format = s.format,
            .usage = c.WGPUTextureUsage_RenderAttachment,
            .width = s.wanted[0],
            .height = s.wanted[1],
            .alphaMode = c.WGPUCompositeAlphaMode_Auto,
            .presentMode = c.WGPUPresentMode_Fifo,
        });
        s.width = s.wanted[0];
        s.height = s.wanted[1];
    }

    /// The frame to draw into, or null when there is nothing to draw this time: a zero-sized
    /// (minimised) window, a timeout, or a surface that had to be reconfigured first.
    pub fn acquire(s: *Surface) ?Frame {
        if (s.wanted[0] == 0 or s.wanted[1] == 0) return null;
        if (s.wanted[0] != s.width or s.wanted[1] != s.height) s.configure();
        var st: c.WGPUSurfaceTexture = .{};
        c.wgpuSurfaceGetCurrentTexture(s.surface, &st);
        switch (step(st.status)) {
            .draw, .draw_then_reconfigure => |k| return .{
                .texture = st.texture,
                .view = c.wgpuTextureCreateView(st.texture, null),
                .reconfigure = k == .draw_then_reconfigure,
            },
            .reconfigure => {
                if (st.texture != null) c.wgpuTextureRelease(st.texture);
                s.configure();
                return null;
            },
            .skip => return null,
            .fatal => std.debug.panic("wgpu surface: status {d}", .{st.status}),
        }
    }

    /// Presents `frame` and releases it. A suboptimal frame reconfigures the surface after.
    pub fn present(s: *Surface, frame: Frame) void {
        _ = c.wgpuSurfacePresent(s.surface);
        c.wgpuTextureViewRelease(frame.view);
        c.wgpuTextureRelease(frame.texture);
        if (frame.reconfigure) s.configure();
    }

    pub fn deinit(s: *Surface) void {
        if (s.width != 0) c.wgpuSurfaceUnconfigure(s.surface);
    }
};

pub const Step = enum { draw, draw_then_reconfigure, reconfigure, skip, fatal };

/// What to do with a `wgpuSurfaceGetCurrentTexture` status.
pub fn step(status: c.WGPUSurfaceGetCurrentTextureStatus) Step {
    return switch (status) {
        c.WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal => .draw,
        // The window changed under the swapchain (a resize the host has not reported yet).
        c.WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal => .draw_then_reconfigure,
        c.WGPUSurfaceGetCurrentTextureStatus_Outdated, c.WGPUSurfaceGetCurrentTextureStatus_Lost => .reconfigure,
        c.WGPUSurfaceGetCurrentTextureStatus_Timeout, c.WGPUSurfaceGetCurrentTextureStatus_Occluded => .skip,
        else => .fatal,
    };
}

/// The first 8-bit unorm format the surface offers: the quad shader writes premultiplied values
/// meant to be stored as they are, as the golden images were. Otherwise the surface's first.
pub fn pickFormat(formats: []const c.WGPUTextureFormat) c.WGPUTextureFormat {
    for (formats) |f| if (f == c.WGPUTextureFormat_BGRA8Unorm or f == c.WGPUTextureFormat_RGBA8Unorm) return f;
    return if (formats.len > 0) formats[0] else c.WGPUTextureFormat_BGRA8Unorm;
}

const testing = std.testing;

test "surface: every status maps to one action" {
    try testing.expectEqual(Step.draw, step(c.WGPUSurfaceGetCurrentTextureStatus_SuccessOptimal));
    try testing.expectEqual(Step.draw_then_reconfigure, step(c.WGPUSurfaceGetCurrentTextureStatus_SuccessSuboptimal));
    try testing.expectEqual(Step.reconfigure, step(c.WGPUSurfaceGetCurrentTextureStatus_Outdated));
    try testing.expectEqual(Step.reconfigure, step(c.WGPUSurfaceGetCurrentTextureStatus_Lost));
    try testing.expectEqual(Step.skip, step(c.WGPUSurfaceGetCurrentTextureStatus_Timeout));
    try testing.expectEqual(Step.skip, step(c.WGPUSurfaceGetCurrentTextureStatus_Occluded));
    try testing.expectEqual(Step.fatal, step(c.WGPUSurfaceGetCurrentTextureStatus_Error));
}

test "surface: unorm formats are preferred over sRGB ones" {
    try testing.expect(pickFormat(&.{ c.WGPUTextureFormat_BGRA8UnormSrgb, c.WGPUTextureFormat_BGRA8Unorm }) == c.WGPUTextureFormat_BGRA8Unorm);
    try testing.expect(pickFormat(&.{c.WGPUTextureFormat_RGBA8UnormSrgb}) == c.WGPUTextureFormat_RGBA8UnormSrgb);
    try testing.expect(pickFormat(&.{}) == c.WGPUTextureFormat_BGRA8Unorm);
    // Compiled though no window exists here to create a surface from.
    std.testing.refAllDecls(Surface);
}
