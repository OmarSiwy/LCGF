//! The glyph atlas on the GPU: the texture behind `Glyphs.texture`, kept in step with a
//! caller's `raster_atlas.Atlas` (8-bit coverage) by uploading only what changed
//! (`Atlas.takeDirty`). The renderer's glyph buffer holds the glyph quads; `drawText` binds this
//! texture through the texture registry like any other:
//!
//!     var atlas_tex = GlyphTexture.init(device, atlas.w, atlas.h);
//!     const handle = gfx.addTexture(&ctx, atlas_tex.view, sampler);   // once
//!     atlas_tex.upload(queue, &atlas);                               // each frame, before prepare
//!     gfx.prepare(queue, draw, .{ ..., .texture = handle }, viewport, scale);
//!
//! Coverage is stored as RGBA8 (255, 255, 255, c). The stock material multiplies the fill by
//! the texel, so a white texel with alpha c gives the fill's colour at coverage c, the same
//! straight-alpha input every other quad has; a one-channel texture would sample as (c, 0, 0, 1)
//! and WebGPU has no swizzle to fix that in the view. The cost is 4 bytes per atlas pixel.

const std = @import("std");
const lcgr = @import("lcgr");
const c = @import("wgpu_c");
const Atlas = lcgr.raster_atlas.Atlas;

pub const GlyphTexture = struct {
    texture: c.WGPUTexture,
    view: c.WGPUTextureView,
    w: u32,
    h: u32,

    pub fn init(device: c.WGPUDevice, w: u32, h: u32) GlyphTexture {
        const texture = c.wgpuDeviceCreateTexture(device, &.{
            .usage = c.WGPUTextureUsage_TextureBinding | c.WGPUTextureUsage_CopyDst,
            .dimension = c.WGPUTextureDimension_2D,
            .size = .{ .width = w, .height = h, .depthOrArrayLayers = 1 },
            .format = c.WGPUTextureFormat_RGBA8Unorm,
            .mipLevelCount = 1,
            .sampleCount = 1,
        });
        return .{ .texture = texture, .view = c.wgpuTextureCreateView(texture, null), .w = w, .h = h };
    }

    pub fn deinit(g: *GlyphTexture) void {
        c.wgpuTextureViewRelease(g.view);
        c.wgpuTextureRelease(g.texture);
    }

    /// Writes the region of `atlas` that changed since the last upload; returns the number of
    /// texels written (0 when nothing changed). Rows are expanded through a stack buffer, as
    /// many per texture write as fit.
    pub fn upload(g: *const GlyphTexture, queue: c.WGPUQueue, atlas: *Atlas) u32 {
        std.debug.assert(atlas.w == g.w and atlas.h == g.h);
        const up = atlas.takeDirty() orelse return 0;
        var rgba: [16 * 1024]u8 = undefined;
        const rows_per_write: u32 = @intCast(@max(rgba.len / (@as(usize, up.w) * 4), 1));
        std.debug.assert(@as(usize, up.w) * 4 <= rgba.len);
        var y: u32 = 0;
        while (y < up.h) : (y += rows_per_write) {
            const rows = @min(rows_per_write, up.h - y);
            for (0..rows) |r| {
                const src = atlas.pixels[up.offset + (y + r) * up.bytes_per_row ..][0..up.w];
                const dst = rgba[r * up.w * 4 ..][0 .. up.w * 4];
                for (src, 0..) |cov, i| dst[i * 4 ..][0..4].* = .{ 255, 255, 255, cov };
            }
            const extent: c.WGPUExtent3D = .{ .width = up.w, .height = rows, .depthOrArrayLayers = 1 };
            c.wgpuQueueWriteTexture(queue, &.{
                .texture = g.texture,
                .origin = .{ .x = up.x, .y = up.y + y },
                .aspect = c.WGPUTextureAspect_All,
            }, &rgba, @as(usize, rows) * up.w * 4, &.{ .bytesPerRow = up.w * 4, .rowsPerImage = rows }, &extent);
        }
        return up.w * up.h;
    }
};
