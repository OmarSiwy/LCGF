//! Textures and samplers on a Metal device: what the renderer needs for `Texture.white` and
//! what a host uses for the glyph atlas or its own images.

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
