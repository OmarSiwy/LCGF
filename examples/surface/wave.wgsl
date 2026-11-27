// examples/surface: rings that move outwards, drawn by the application into its surface. One
// triangle over the target; the size in use and the time come in a uniform buffer.
@group(0) @binding(0) var<uniform> params: vec4f;

@vertex
fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
    return vec4f(f32(i & 1u) * 4.0 - 1.0, f32(i >> 1u) * 4.0 - 1.0, 0.0, 1.0);
}

@fragment
fn fs(@builtin(position) p: vec4f) -> @location(0) vec4f {
    let c = p.xy / params.xy - vec2f(0.5, 0.5);
    let w = 0.5 + 0.5 * sin(length(c) * 40.0 - params.z * 4.0);
    return vec4f(0.1 + 0.6 * w, 0.2 + 0.3 * w, 0.55, 1.0);
}
