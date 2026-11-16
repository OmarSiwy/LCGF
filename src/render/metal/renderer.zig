//! The Metal back end proper: draws a `DrawList` into the render command encoder the host
//! opened. Meets the contract in src/render/iface.zig, as the wgpu, Vulkan and GL ES back ends
//! do.
//!
//! WHO OWNS WHAT
//!   You:       device, queue, layer or target texture, command buffer, render pass and its
//!              encoder, synchronisation and presentation.
//!   Renderer:  the quad pipeline states it compiled on your device.

const std = @import("std");
const builtin = @import("builtin");
const lcgr = @import("lcgr");
const objc = @import("objc.zig");
const mtl = @import("mtl.zig");
const msl = @import("msl.zig");
const pipeline = @import("pipeline.zig");
const types = lcgr.types;
const quad_shader = lcgr.quad_shader;
const Id = objc.Id;

pub const max_materials = quad_shader.max_materials;

pub const Desc = struct {
    /// Format of the targets the passes draw into.
    format: mtl.PixelFormat = .bgra8_unorm,
    sample_count: objc.NSUInteger = 1,
};

pub const Error = pipeline.Error;

pub const Renderer = struct {
    device: Id,
    desc: Desc,
    pipelines: [max_materials]Id = undefined,
    material_count: u16 = 0,

    pub fn init(device: Id, desc: Desc) Error!Renderer {
        var r: Renderer = .{ .device = device, .desc = desc };
        errdefer r.deinit();
        _ = try r.addMaterial(msl.stock); // Material.solid
        return r;
    }

    pub fn deinit(r: *Renderer) void {
        for (r.pipelines[0..r.material_count]) |p| objc.release(p);
        r.material_count = 0;
    }

    /// A quad pipeline with your fragment logic: `quad_shader.shader(your_wgsl_fn)` translated to
    /// MSL (src/render/shaders/translate.sh) and passed through `msl.bind`. Past `max_materials`
    /// the last entry is replaced, as the prototype does.
    pub fn addMaterial(r: *Renderer, source: [:0]const u8) Error!types.Material {
        const i: u16 = @min(r.material_count, max_materials - 1);
        const p = try pipeline.quad(r.device, source, .{ .format = r.desc.format, .sample_count = r.desc.sample_count });
        if (i < r.material_count) objc.release(r.pipelines[i]);
        r.pipelines[i] = p;
        r.material_count = i + 1;
        return @fromBackingInt(i);
    }
};

const testing = std.testing;
const dev_mod = @import("device.zig");

test "renderer: quad pipelines compile from the committed MSL on a real device" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try objc.load();
    const pool = objc.Pool.push();
    defer pool.pop();
    var dev = try dev_mod.Device.init();
    defer dev.deinit();
    var r = try Renderer.init(dev.device, .{ .format = .rgba8_unorm });
    defer r.deinit();
    try testing.expectEqual(@as(u16, 1), r.material_count);
    try testing.expectEqual(@as(u16, 1), @backingInt(try r.addMaterial(msl.example)));
    for (0..max_materials + 2) |_| _ = try r.addMaterial(msl.example);
    try testing.expectEqual(@as(u16, max_materials), r.material_count);
    try testing.expectError(error.ShaderCompile, r.addMaterial("not msl"));
}
