// lcgf_render.gpu's own test shader: a vertex buffer, a uniform buffer, a sampled texture.
// Positions come in as 0..1 over the target, rows from the top, like framebuffer pixels.
struct Params { tint: vec4f };
@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var tex: texture_2d<f32>;
@group(0) @binding(2) var smp: sampler;

struct V { @builtin(position) pos: vec4f, @location(0) uv: vec2f };

@vertex
fn vs(@location(0) at: vec2f) -> V {
    return V(vec4f(at.x * 2.0 - 1.0, 1.0 - at.y * 2.0, 0.0, 1.0), at);
}

@fragment
fn fs(v: V) -> @location(0) vec4f {
    return textureSample(tex, smp, v.uv) * params.tint;
}
