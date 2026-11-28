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

/// The most overrides a draw can apply: the uniform array's length, 8 KB, so the whole uniform
/// stays within GL ES 3.0's 16 KB. The renderer's `Desc` sets how many it takes, up to this.
/// ponytail: a loop over them per vertex; a per-row colour column when selections outgrow it.
pub const max_overrides = 512;
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
    inv: [4]f32,
    inv_t: [2]f32,
    fwd_t: [2]f32,
    fwd: [4]f32,
    radii: [4]f32,
    clip_box: [4]f32,
    px_scale: f32,
    inv_scale: f32,
    rounded: u32,
    _pad: u32 = 0,
    palette: [max_layers]canvas.Layer,
    override_rows: [max_overrides][4]u32,

    /// Bytes of the head and the first `layers` palette rows: what `override_rows` does not cover.
    pub fn headBytes(layers: u32) usize {
        return @offsetOf(Uniforms, "palette") + @as(usize, layers) * @sizeOf(canvas.Layer);
    }
};

comptime {
    std.debug.assert(@offsetOf(Uniforms, "rect") == 32 and @offsetOf(Uniforms, "inv") == 96 and @offsetOf(Uniforms, "palette") == 192 and @sizeOf(Uniforms) == 192 + 4096 + 16 * max_overrides);
}

/// Fills the head, palette and overrides of canvas command `k` of `list` at `scale` physical
/// pixels per logical one, on a `target` of physical pixels; the batch starts at `row_base`
/// and `vert_base` in the GPU buffers. Only `headBytes(u.layers)` and `u.overrides` rows of
/// `override_rows` are written. False, and nothing to draw, for a node whose transform has no
/// inverse (sw's `prep` draws nothing then either).
pub fn fill(u: *Uniforms, list: *const draw_list.DrawList, k: u32, scale: f32, target: [2]f32, row_base: u32, vert_base: u32) bool {
    const node = list.customs[k];
    // sw canvas.zig `prep`'s `Space`, in the same arithmetic.
    const a, const b, const cc, const d, const tx, const ty = node.xform;
    const det = a * d - b * cc;
    if (!std.math.isFinite(det) or det == 0) return false;
    u.inv = .{ d / det, -b / det, -cc / det, a / det };
    u.inv_t = .{ -(d * tx - cc * ty) * scale / det, -(a * ty - b * tx) * scale / det };
    u.fwd = .{ a, b, cc, d };
    u.fwd_t = .{ tx * scale, ty * scale };
    u.radii = node.clip_radii;
    u.clip_box = .{ (node.clip[0] + node.clip[2]) * 0.5, (node.clip[1] + node.clip[3]) * 0.5, (node.clip[2] - node.clip[0]) * 0.5, (node.clip[3] - node.clip[1]) * 0.5 };
    u.px_scale = scale;
    u.inv_scale = 1 / scale;
    u.rounded = @intFromBool(@reduce(.Or, @as(@Vector(4, f32), node.clip_radii) > @as(@Vector(4, f32), @splat(0))));
    const c = list.canvases[k];
    const s: @Vector(4, f32) = @splat(scale);
    const layers: u32 = @intCast(@min(c.palette.layers.len, max_layers));
    const table = c.overrides[0..@min(c.overrides.len, max_overrides)];
    u.view = canvas.View.of(c.camera, .{ node.rect[0], node.rect[1] }, scale);
    u.rect = @as(@Vector(4, f32), node.rect) * s;
    u.clip = @as(@Vector(4, f32), node.clip) * s;
    u.size = target;
    u.opacity = node.opacity;
    u.row_base = row_base;
    u.vert_base = vert_base;
    u.vert_len = c.instances.vert_len;
    u.overrides = @intCast(table.len);
    u.layers = layers;
    @memcpy(u.palette[0..layers], c.palette.layers[0..layers]);
    for (table, u.override_rows[0..table.len]) |o, *m| {
        m.* = .{ o.range.first, o.range.count, o.color, 0 };
    }
    return true;
}
