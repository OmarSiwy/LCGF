// The stock quad shader: one instance per `draw_list.Quad`, a triangle strip of four vertices.
// Ported from prototype/ui_wgpu.zig (shader_head, default_material, shader_tail).
//
// The built-in visual features live here, chosen per instance by `params.x` (src/draw/features.zig
// writes the params), so quads with different features still share one pipeline and one batch.
// `params` is read as four u32 bit patterns: features store colours and packed values in it.
// A user material replaces `material`; its params are its own.

struct Globals { viewport: vec2f, scale: f32, pad: f32 }
@group(0) @binding(0) var<uniform> globals: Globals;
@group(1) @binding(0) var tex: texture_2d<f32>;
@group(1) @binding(1) var samp: sampler;

struct Instance {
    @location(0) rect: vec4f,
    @location(1) clip: vec4f,
    @location(2) params: vec4u,
    @location(3) uv: vec4f,
    @location(4) fill: vec4f,
    @location(5) border_color: vec4f,
    @location(6) radius_border: vec2f,
}

struct Frag {
    @builtin(position) position: vec4f,
    @location(0) local: vec2f,
    @location(1) uv: vec2f,
    @location(2) pixel: vec2f,
    @location(3) @interpolate(flat) half: vec2f,
    @location(4) @interpolate(flat) radius_border: vec2f,
    @location(5) @interpolate(flat) fill: vec4f,
    @location(6) @interpolate(flat) border_color: vec4f,
    @location(7) @interpolate(flat) clip: vec4f,
    @location(8) @interpolate(flat) params: vec4u,
}

@vertex
fn vs(@builtin(vertex_index) vi: u32, inst: Instance) -> Frag {
    // Triangle strip: (0,0) (1,0) (0,1) (1,1).
    let corner = vec2f(f32(vi & 1u), f32(vi >> 1u));
    // A shadow draws 3 sigma past its rect on every side, where the blur fades out.
    let grow = select(0.0, 3.0 * bitcast<f32>(inst.params.y), inst.params.x == k_shadow);
    let p = mix(inst.rect.xy - grow, inst.rect.zw + grow, corner);
    var out: Frag;
    out.position = vec4f(p / globals.viewport * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0), 0.0, 1.0);
    out.local = p - (inst.rect.xy + inst.rect.zw) * 0.5;
    out.uv = mix(inst.uv.xy, inst.uv.zw, (p - inst.rect.xy) / max(inst.rect.zw - inst.rect.xy, vec2f(1e-6)));
    out.pixel = p;
    out.half = (inst.rect.zw - inst.rect.xy) * 0.5;
    out.radius_border = inst.radius_border;
    out.fill = inst.fill;
    out.border_color = inst.border_color;
    out.clip = inst.clip;
    out.params = inst.params;
    return out;
}

fn rounded_box(p: vec2f, half: vec2f, r: f32) -> f32 {
    let q = abs(p) - half + vec2f(r);
    return length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

// Feature codes in params.x, as in src/draw/features.zig `Kind`.
const k_linear = 1u;
const k_radial = 2u;
const k_shadow = 3u;

// Gradients: fill is the start colour, params.y the end colour (rgba8).
//   linear: params.z = angle in radians (0 runs left to right, y points down). t runs 0..1
//           between the two corners the direction meets, as CSS linear-gradient does.
//   radial: params.z = centre as two f16 fractions of the size, params.w = radius in pixels.
fn gradient(in: Frag) -> vec4f {
    let to = unpack4x8unorm(in.params.y);
    let a = bitcast<f32>(in.params.z);
    let dir = vec2f(cos(a), sin(a));
    let reach = abs(in.half.x * dir.x) + abs(in.half.y * dir.y);
    let t_lin = dot(in.local, dir) / max(reach, 1e-6) * 0.5 + 0.5;
    let centre = (unpack2x16float(in.params.z) * 2.0 - 1.0) * in.half;
    let t_rad = length(in.local - centre) / max(bitcast<f32>(in.params.w), 1e-6);
    let t = clamp(select(t_lin, t_rad, in.params.x == k_radial), 0.0, 1.0);
    let graded = in.params.x == k_linear || in.params.x == k_radial;
    return select(in.fill, mix(in.fill, to, t), graded);
}

// Box shadow: the rounded rect blurred by a Gaussian of sigma = params.y pixels, in the fill
// colour. Analytic: the coverage of a blurred edge at signed distance d is 0.5 - erf(d / (sigma
// sqrt 2)) / 2, applied to the rounded-box distance (exact for straight edges, close at corners).
fn shadow_coverage(d: f32, sigma: f32) -> f32 {
    let x = d / (max(sigma, 1e-3) * 1.41421356);
    // erf, Abramowitz and Stegun 7.1.26 style closed form, max error about 1e-4.
    let a = 0.147;
    let x2 = x * x;
    let e = sign(x) * sqrt(1.0 - exp(-x2 * (1.27323954 + a * x2) / (1.0 + a * x2)));
    return 0.5 - 0.5 * e;
}

// The stock material: the fill (or its gradient) times the bound texture.
fn material(in: Frag) -> vec4f {
    return gradient(in) * textureSample(tex, samp, in.uv);
}

@fragment
fn fs(in: Frag) -> @location(0) vec4f {
    let r = min(in.radius_border.x, min(in.half.x, in.half.y));
    let d = rounded_box(in.local, in.half, r) * globals.scale;
    // Coverage instead of discard: one physical pixel of antialiasing, no branch.
    let shape = clamp(0.5 - d, 0.0, 1.0);
    let inner = clamp(0.5 - (d + in.radius_border.y * globals.scale), 0.0, 1.0);
    let has_border = step(0.001, in.radius_border.y);
    let is_shadow = in.params.x == k_shadow;
    let color = select(mix(in.border_color, material(in), mix(1.0, inner, has_border)), in.fill, is_shadow);
    let cover = select(shape, shadow_coverage(d / globals.scale, bitcast<f32>(in.params.y)), is_shadow);
    // Per-instance clip, also as coverage.
    let inside = step(in.clip.xy, in.pixel) * step(in.pixel, in.clip.zw);
    let alpha = cover * inside.x * inside.y;
    return vec4f(color.rgb * color.a, color.a) * alpha;
}
