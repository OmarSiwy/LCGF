//! Textures and samplers on a Metal device: what the renderer needs for `Texture.white` and
//! what a host uses for the glyph atlas, its own images and the window's picture, and the
//! copy that writes a rectangle of one on the GPU's timeline.

const std = @import("std");
const objc = @import("objc.zig");
const mtl = @import("mtl.zig");
const Id = objc.Id;
const msg = objc.msg;
const U = objc.NSUInteger;

pub const Error = error{TextureFailed};

/// An RGBA8 texture of `w` x `h` texels, sampled by shaders, with `rgba` (tightly packed rows)
/// uploaded when given. Caller releases it.
pub fn rgba8(device: Id, w: u32, h: u32, rgba: ?[]const u8) Error!Id {
    const desc = msg(Id, objc.class("MTLTextureDescriptor"), "texture2DDescriptorWithPixelFormat:width:height:mipmapped:", .{ mtl.PixelFormat.rgba8_unorm, @as(U, w), @as(U, h), @as(objc.BOOL, false) });
    msg(void, desc, "setUsage:", .{mtl.texture_usage_shader_read});
    const t = msg(?Id, device, "newTextureWithDescriptor:", .{desc}) orelse return error.TextureFailed;
    if (rgba) |px| {
        std.debug.assert(px.len == @as(usize, w) * h * 4);
        const region: mtl.Region = .{ .size = .{ .width = w, .height = h, .depth = 1 } };
        msg(void, t, "replaceRegion:mipmapLevel:withBytes:bytesPerRow:", .{ region, @as(U, 0), px.ptr, @as(U, w * 4) });
    }
    return t;
}

/// A sampled R8 texture read as white with its byte as alpha (`sw.Image.alpha8`, the glyph and
/// label atlases, `lcgf_app.Image.alpha`), private to the GPU: written with `writeRegion`.
/// Caller releases it.
pub fn coverage(device: Id, w: u32, h: u32) Error!Id {
    std.debug.assert(w > 0);
    std.debug.assert(h > 0);
    const desc = descriptor(.r8_unorm, w, h);
    msg(void, desc, "setUsage:", .{mtl.texture_usage_shader_read});
    msg(void, desc, "setStorageMode:", .{mtl.storage_mode_private});
    const alpha: mtl.SwizzleChannels = .{ .r = .one, .g = .one, .b = .one, .a = .red };
    msg(void, desc, "setSwizzle:", .{alpha});
    return msg(?Id, device, "newTextureWithDescriptor:", .{desc}) orelse error.TextureFailed;
}

/// A render target of `format`, `w` x `h`, private to the GPU, that a blit may copy from: a
/// window's picture. Caller releases it.
pub fn target(device: Id, format: mtl.PixelFormat, w: u32, h: u32) Error!Id {
    std.debug.assert(w > 0);
    std.debug.assert(h > 0);
    const desc = descriptor(format, w, h);
    msg(void, desc, "setUsage:", .{mtl.texture_usage_render_target});
    msg(void, desc, "setStorageMode:", .{mtl.storage_mode_private});
    return msg(?Id, device, "newTextureWithDescriptor:", .{desc}) orelse error.TextureFailed;
}

/// Records on blit encoder `blit` a copy of `region` of `tex` from `buffer` at byte `offset`,
/// `bytes_per_row` apart (the texel size times the region's width, at least). The copy runs
/// in the command buffer's order, after the frames before it have sampled `tex`: Metal tracks
/// the hazard, so a texture in use is written in place. `buffer` must hold the bytes until the
/// command buffer completes.
// tidy: allow(line-too-long) the API index reads one-line signatures
pub fn writeRegion(blit: Id, buffer: Id, offset: usize, bytes_per_row: u32, tex: Id, region: mtl.Region) void {
    std.debug.assert(region.size.width > 0);
    std.debug.assert(region.size.height > 0);
    const image_bytes: U = @as(U, bytes_per_row) * region.size.height;
    const args = .{
        buffer, @as(U, offset), @as(U, bytes_per_row), image_bytes,   region.size,
        tex,    @as(U, 0),      @as(U, 0),             region.origin,
    };
    msg(void, blit, copy_region, args);
}

const copy_region = "copyFromBuffer:sourceOffset:sourceBytesPerRow:sourceBytesPerImage:" ++
    "sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:";

/// A sampler with `filter` for both magnification and minification, clamped to the edge.
/// Caller releases it.
pub fn sampler(device: Id, filter: mtl.SamplerFilter) Error!Id {
    const desc = msg(Id, objc.class("MTLSamplerDescriptor"), "new", .{});
    defer objc.release(desc);
    msg(void, desc, "setMinFilter:", .{filter});
    msg(void, desc, "setMagFilter:", .{filter});
    msg(void, desc, "setSAddressMode:", .{mtl.SamplerAddressMode.clamp_to_edge});
    msg(void, desc, "setTAddressMode:", .{mtl.SamplerAddressMode.clamp_to_edge});
    return msg(?Id, device, "newSamplerStateWithDescriptor:", .{desc}) orelse error.TextureFailed;
}

// ---- private ----

/// A 2D texture descriptor of `format`, `w` x `h`, no mipmaps (autoreleased).
fn descriptor(format: mtl.PixelFormat, w: u32, h: u32) Id {
    const sel = "texture2DDescriptorWithPixelFormat:width:height:mipmapped:";
    const args = .{ format, @as(U, w), @as(U, h), @as(objc.BOOL, false) };
    return msg(Id, objc.class("MTLTextureDescriptor"), sel, args);
}

const testing = std.testing;

test "texture: an atlas samples white with its byte as alpha, and a region copies on a blit" {
    if (@import("builtin").os.tag == .macos) return error.SkipZigTest;
    objc.Fake.install();
    defer objc.Fake.uninstall();
    _ = try coverage(objc.Fake.object, 64, 32);
    try testing.expectEqual(1, objc.Fake.count("setSwizzle:"));
    try testing.expectEqual(1, objc.Fake.count("newTextureWithDescriptor:"));
    const band: mtl.Region = .{ .origin = .{ .x = 8 }, .size = .{ .width = 16, .height = 4 } };
    writeRegion(objc.Fake.object, objc.Fake.object, 0, 16, objc.Fake.object, band);
    try testing.expectEqual(1, objc.Fake.count(copy_region));
    objc.Fake.nil = &.{"newTextureWithDescriptor:"};
    try testing.expectError(error.TextureFailed, target(objc.Fake.object, .bgra8_unorm, 4, 4));
}
