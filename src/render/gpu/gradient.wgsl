// The goldens' host draw for a custom command (src/render/conformance/render.py `scene_pipe`),
// written once for every back end: one triangle over the target, a gradient over the pixel
// position. The target size comes in a uniform buffer (WebGPU has no push constants).
@group(0) @binding(0) var<uniform> screen: vec4f;

@vertex
fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
    return vec4f(f32(i & 1u) * 4.0 - 1.0, f32(i >> 1u) * 4.0 - 1.0, 0.0, 1.0);
}

@fragment
fn fs(@builtin(position) p: vec4f) -> @location(0) vec4f {
    return vec4f(p.x / screen.x * 0.5, 0.25, p.y / screen.y * 0.6, 1.0);
}
