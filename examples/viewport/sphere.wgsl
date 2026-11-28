// examples/viewport: a unit sphere, Lambert-lit, ray-cast per pixel of the surface. The same
// shading as `shade` in app.zig, which draws it on the CPU where there is no GPU.
struct Params {
    // Centre and radius in the surface's pixels; the light's angle around the vertical axis.
    sphere: vec4f,
    // x: 1 to draw bands of latitude dark.
    bands: vec4f,
};
@group(0) @binding(0) var<uniform> params: Params;

@vertex
fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
    return vec4f(f32(i & 1u) * 4.0 - 1.0, f32(i >> 1u) * 4.0 - 1.0, 0.0, 1.0);
}

@fragment
fn fs(@builtin(position) p: vec4f) -> @location(0) vec4f {
    let s = params.sphere;
    // Pixel centres, as the CPU samples them at integer coordinates.
    let n = (floor(p.xy) - s.xy) / s.z;
    let d = 1.0 - dot(n, n);
    if (d < 0.0) {
        return vec4f(16.0, 24.0, 40.0, 255.0) / 255.0;
    }
    let l = vec3f(cos(s.w) * 0.8, -0.4, sin(s.w) * 0.8 + 0.6);
    let lit = max(dot(vec3f(n, sqrt(d)), l) / length(l), 0.0);
    let band = params.bands.x > 0.5 && fract(asin(n.y) * 8.0) < 0.15;
    let k = select(0.15 + 0.85 * lit, 0.2, band);
    return vec4f(vec3f(230.0, 140.0, 60.0) * k / 255.0, 1.0);
}
