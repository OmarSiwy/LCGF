//! The canvas shader (canvas.wgsl) and the uniforms it reads, for every GPU back end. Data
//! only, like quad.zig: no GPU API here. src/render/gpu/canvas.zig draws with it through
//! `lcgf_render.gpu`; src/render/sw/canvas.zig is its software twin.
//!
//! Two variants differ only in where polygon vertices come from: `wgsl` reads a storage buffer,
//! `wgsl_es` an r32uint texture of two texels a vertex, `verts_width` texels a row, since GL ES
//! 3.0 has no storage buffers in the fragment stage.
const std = @import("std");
const canvas = @import("../../draw/canvas.zig");
const draw_list = @import("../../draw/draw_list.zig");

const body = @embedFile("canvas.wgsl");

pub const wgsl: [:0]const u8 = body ++
    \\@group(0) @binding(1) var<storage, read> verts: array<vec2i>;
    \\fn vert(i: u32) -> vec2i {
    \\    return verts[i];
    \\}
    \\
;

/// Texels a row of `wgsl_es`'s vertex texture.
pub const verts_width = 2048;

pub const wgsl_es: [:0]const u8 = body ++
    \\@group(0) @binding(1) var verts: texture_2d<u32>;
    \\fn vert(i: u32) -> vec2i {
    \\    let j = 2u * i;
    \\    let x = textureLoad(verts, vec2u(j & 2047u, j >> 11u), 0).x;
    \\    let y = textureLoad(verts, vec2u((j + 1u) & 2047u, (j + 1u) >> 11u), 0).x;
    \\    return vec2i(bitcast<i32>(x), bitcast<i32>(y));
    \\}
    \\
;

/// Overrides one draw applies; past these, the first ones are dropped.
/// ponytail: a fixed uniform array; a storage buffer when selections outgrow it.
pub const max_overrides = 64;
pub const max_layers = 256;

/// canvas.wgsl's `Draw`.
pub const Uniforms = extern struct {
    view: canvas.View,
    rect: [4]f32,
    clip: [4]f32,
    size: [2]f32,
    opacity: f32,
    row_base: u32,
    vert_base: u32,
    vert_len: u32,
    overrides: u32,
    layers: u32,
    palette: [max_layers]canvas.Layer,
    marks: [max_overrides][4]u32,

    /// Bytes of the head and the first `layers` palette rows: what `marks` does not cover.
    pub fn headBytes(layers: u32) usize {
        return @offsetOf(Uniforms, "palette") + @as(usize, layers) * @sizeOf(canvas.Layer);
    }
};

comptime {
    std.debug.assert(@offsetOf(Uniforms, "rect") == 32 and @offsetOf(Uniforms, "palette") == 96 and @sizeOf(Uniforms) == 96 + 4096 + 1024);
}

/// Fills the head, palette and overrides of canvas command `k` of `list` at `scale` physical
/// pixels per logical one, on a `target` of physical pixels; the batch starts at `row_base`
/// and `vert_base` in the GPU buffers. Only `headBytes(u.layers)` and `u.overrides` rows of
/// `marks` are written.
pub fn fill(u: *Uniforms, list: *const draw_list.DrawList, k: u32, scale: f32, target: [2]f32, row_base: u32, vert_base: u32) void {
    const node = list.customs[k];
    const c = list.canvases[k];
    const s: @Vector(4, f32) = @splat(scale);
    const layers: u32 = @intCast(@min(c.palette.layers.len, max_layers));
    const marks = c.overrides[c.overrides.len - @min(c.overrides.len, max_overrides) ..];
    u.view = canvas.View.of(c.camera, c.palette, .{ node.rect[0], node.rect[1] }, scale);
    u.rect = @as(@Vector(4, f32), node.rect) * s;
    u.clip = @as(@Vector(4, f32), node.clip) * s;
    u.size = target;
    u.opacity = node.opacity;
    u.row_base = row_base;
    u.vert_base = vert_base;
    u.vert_len = c.instances.vert_len;
    u.overrides = @intCast(marks.len);
    u.layers = layers;
    @memcpy(u.palette[0..layers], c.palette.layers[0..layers]);
    for (marks, u.marks[0..marks.len]) |o, *m| m.* = .{ o.range.first, o.range.count, o.color, 0 };
}
