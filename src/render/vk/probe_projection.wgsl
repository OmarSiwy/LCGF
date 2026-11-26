// The custom node of src/render/vk/probe_projection.zig: the application drawing the wgpu-native
// guest experiment timed (docs/research/custom-webgpu/), the same WGSL, now through
// lcgf_render.gpu. A full-target triangle samples a texture, scaled by a tint.
@group(0) @binding(0) var<uniform> tint: vec4f;
@group(0) @binding(1) var tex: texture_2d<f32>;
@group(0) @binding(2) var smp: sampler;

struct V { @builtin(position) pos: vec4f, @location(0) uv: vec2f };

@vertex
fn vs(@builtin(vertex_index) i: u32) -> V {
    let uv = vec2f(f32((i << 1u) & 2u), f32(i & 2u));
    return V(vec4f(uv * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0), 0.0, 1.0), uv);
}

@fragment
fn fs(v: V) -> @location(0) vec4f {
    return textureSample(tex, smp, v.uv) * tint;
}
