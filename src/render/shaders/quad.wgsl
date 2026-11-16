// The stock quad shader: one instance per `draw_list.Quad`, a triangle strip of four vertices.
// Ported from prototype/ui_wgpu.zig (shader_head, default_material, shader_tail).
//
// The built-in visual features live here, chosen per instance by `params.x` (src/draw/features.zig
// writes the params), so quads with different features still share one pipeline and one batch.
// `params` is read as four u32 bit patterns: features store colours and packed values in it.
// A user material replaces the stock `material`; its params are its own.

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
    @location(6) radii: vec4f,
    @location(7) border: f32,
    @location(8) opacity: f32,
    @location(9) xform_abcd: vec4f,
    @location(10) xform_t: vec2f,
    @location(11) clip_radii: vec4f,
}

struct Frag {
    @builtin(position) position: vec4f,
    @location(0) local: vec2f,
    @location(1) uv: vec2f,
    @location(2) pixel: vec2f,
    @location(3) @interpolate(flat) half: vec2f,
    @location(4) @interpolate(flat) radii: vec4f,
    @location(5) @interpolate(flat) fill: vec4f,
    @location(6) @interpolate(flat) border_color: vec4f,
    @location(7) @interpolate(flat) clip: vec4f,
    @location(8) @interpolate(flat) params: vec4u,
    @location(9) @interpolate(flat) uv_rect: vec4f,
    @location(10) @interpolate(flat) border: f32,
    @location(11) @interpolate(flat) opacity: f32,
    @location(12) @interpolate(flat) clip_radii: vec4f,
    // Maps the pixel centre (`position.xy`, physical pixels) to the offset from the rect's top
    // left in logical pixels: m.xy * x + m.zw * y + off. Discrete decisions (nearest texel, the
    // border side, the dash period) use it instead of `local`: pixel centres are exact on every
    // GPU and on the CPU, interpolated varyings are not, so ties fall the same way everywhere.
    @location(13) @interpolate(flat) to_rect: vec4f,
    @location(14) @interpolate(flat) to_rect_off: vec2f,
}

@vertex
fn vs(@builtin(vertex_index) vi: u32, inst: Instance) -> Frag {
    // Triangle strip: (0,0) (1,0) (0,1) (1,1).
    let corner = vec2f(f32(vi & 1u), f32(vi >> 1u));
    // A shadow draws 3 sigma past its rect on every side, where the blur fades out.
    let grow = select(0.0, 3.0 * bitcast<f32>(inst.params.y), inst.params.x == k_shadow);
    let p = mix(inst.rect.xy - grow, inst.rect.zw + grow, corner);
    var out: Frag;
    // The node's transform moves the corners; local, uv and the distance field stay in the
    // node's own space, so shapes rotate and scale with it.
    let screen = inst.xform_abcd.xy * p.x + inst.xform_abcd.zw * p.y + inst.xform_t;
    out.position = vec4f(screen / globals.viewport * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0), 0.0, 1.0);
    out.local = p - (inst.rect.xy + inst.rect.zw) * 0.5;
    out.uv = mix(inst.uv.xy, inst.uv.zw, (p - inst.rect.xy) / max(inst.rect.zw - inst.rect.xy, vec2f(1e-6)));
    out.pixel = screen;
    out.half = (inst.rect.zw - inst.rect.xy) * 0.5;
    out.radii = inst.radii;
    out.border = inst.border;
    out.opacity = inst.opacity;
    out.clip_radii = inst.clip_radii;
    out.fill = inst.fill;
    out.border_color = inst.border_color;
    out.clip = inst.clip;
    out.params = inst.params;
    out.uv_rect = inst.uv;
    let a = inst.xform_abcd;
    let k = 1.0 / ((a.x * a.w - a.y * a.z) * globals.scale);
    out.to_rect = vec4f(a.w * k, -a.y * k, -a.z * k, a.x * k);
    out.to_rect_off = -(out.to_rect.xy * (inst.xform_t.x * globals.scale) + out.to_rect.zw * (inst.xform_t.y * globals.scale)) - inst.rect.xy;
    return out;
}

// radii: top-left, top-right, bottom-right, bottom-left; y points down. Picks the radius of the
// quadrant p is in, capped by the half size.
fn corner_radius(p: vec2f, half: vec2f, radii: vec4f) -> f32 {
    let right = select(radii.y, radii.z, p.y > 0.0);
    let left = select(radii.x, radii.w, p.y > 0.0);
    return min(select(left, right, p.x > 0.0), min(half.x, half.y));
}

fn rounded_box(p: vec2f, half: vec2f, r: f32) -> f32 {
    let q = abs(p) - half + vec2f(r);
    return length(max(q, vec2f(0.0))) + min(max(q.x, q.y), 0.0) - r;
}

// The pixel centre's offset from the rect's top left, in logical pixels, from exact inputs only.
fn rect_pos(in: Frag) -> vec2f {
    return in.to_rect.xy * in.position.x + in.to_rect.zw * in.position.y + in.to_rect_off;
}

// floor(num / den) for den > 0, settled by products instead of the rounded quotient, so an exact
// multiple gives the same answer on every GPU (WGSL division is only accurate to 2.5 ULP).
fn floor_div(num: f32, den: f32) -> f32 {
    let q = floor(num / den);
    return q + select(0.0, 1.0, (q + 1.0) * den <= num) - select(0.0, 1.0, q * den > num);
}

// Nearest sampling decided here: the uv of the centre of the texel that the uv rect puts at pos
// (one axis; size = rect size, n = texels), clamped to the edge. A pixel centre exactly on a
// texel edge takes the texel after it. The whole texels of the uv origin are added after the
// division: an atlas cell starts on a texel, so the products stay small and exact.
fn texel_centre(pos: f32, size: f32, uv0: f32, uv1: f32, n: f32) -> f32 {
    let s = max(size, 1e-6);
    let a = uv0 * n;
    let whole = floor(a);
    let k = whole + floor_div((a - whole) * s + (uv1 - uv0) * n * pos, s);
    return (clamp(k, 0.0, n - 1.0) + 0.5) / n;
}

fn nearest_uv(in: Frag) -> vec2f {
    let pos = rect_pos(in);
    let n = vec2f(textureDimensions(tex));
    let size = in.half * 2.0;
    return vec2f(texel_centre(pos.x, size.x, in.uv_rect.x, in.uv_rect.z, n.x),
                 texel_centre(pos.y, size.y, in.uv_rect.y, in.uv_rect.w, n.y));
}

// Feature codes in params.x, as in src/draw/features.zig `Kind`.
const k_linear = 1u;
const k_radial = 2u;
const k_shadow = 3u;
const k_nine = 4u;
const k_dashed = 5u;
const k_dotted = 6u;

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

// Nine-slice: the image (uv_rect) is cut into a 3x3 grid by insets; corners keep their pixel
// size, edges stretch along one axis, the middle along both.
//   params.y = destination insets left, top, right, bottom in pixels, one byte each
//   params.z, params.w = source insets (left, top), (right, bottom) as unorm16 fractions of the image
fn nine_axis(pos: f32, size: f32, lo: f32, hi: f32, src_lo: f32, src_hi: f32) -> f32 {
    let start = pos / max(lo, 1e-6) * src_lo;
    let end = 1.0 - (size - pos) / max(hi, 1e-6) * src_hi;
    let mid = src_lo + (pos - lo) / max(size - lo - hi, 1e-6) * (1.0 - src_lo - src_hi);
    return select(select(mid, end, pos > size - hi), start, pos < lo);
}

fn nine_uv(in: Frag) -> vec2f {
    let dst = unpack4x8unorm(in.params.y) * 255.0;
    let src = vec4f(unpack2x16unorm(in.params.z), unpack2x16unorm(in.params.w));
    let pos = in.local + in.half;
    let size = in.half * 2.0;
    let f = vec2f(nine_axis(pos.x, size.x, dst.x, dst.z, src.x, src.z),
                  nine_axis(pos.y, size.y, dst.y, dst.w, src.y, src.w));
    return mix(in.uv_rect.xy, in.uv_rect.zw, f);
}

// Dashed and dotted borders: how much of the border is drawn at this pixel, 0 to 1, with one
// pixel of antialiasing. Position along the border is measured on the nearest side from its
// top or left end; on a diagonal, where both sides are as near, the top or bottom side wins.
// params.y = dash length, params.z = gap, in pixels.
//   dashed: dashes of params.y with gaps of params.z
//   dotted: round dots as wide as the border, params.z apart
fn border_pattern(in: Frag) -> f32 {
    let pos = rect_pos(in);
    let edge = in.half - abs(pos - in.half);
    let along_y = edge.x < edge.y;
    let s = select(pos.x, pos.y, along_y);
    let across = min(edge.x, edge.y);
    let dash = select(bitcast<f32>(in.params.y), in.border, in.params.x == k_dotted);
    let period = max(dash + bitcast<f32>(in.params.z), 1e-3);
    let at = s - floor_div(s, period) * period;
    let dashed = clamp((min(at, dash - at) + 0.5) * globals.scale, 0.0, 1.0);
    let r = in.border * 0.5;
    let dotted = clamp(0.5 - (length(vec2f(at - r, across - r)) - r) * globals.scale, 0.0, 1.0);
    return select(select(1.0, dashed, in.params.x == k_dashed), dotted, in.params.x == k_dotted);
}

// The material function is not here: quad.zig `shader` appends one (WGSL resolves
// module-scope names in any order), the stock one from material.wgsl or a user's.

@fragment
fn fs(in: Frag) -> @location(0) vec4f {
    let r = corner_radius(in.local, in.half, in.radii);
    let d = rounded_box(in.local, in.half, r) * globals.scale;
    // Coverage instead of discard: one physical pixel of antialiasing, no branch.
    let shape = clamp(0.5 - d, 0.0, 1.0);
    let inner = clamp(0.5 - (d + in.border * globals.scale), 0.0, 1.0);
    let has_border = step(0.001, in.border);
    let is_shadow = in.params.x == k_shadow;
    let on_border = (1.0 - mix(1.0, inner, has_border)) * border_pattern(in);
    let color = select(mix(material(in), in.border_color, on_border), in.fill, is_shadow);
    let cover = select(shape, shadow_coverage(d / globals.scale, bitcast<f32>(in.params.y)), is_shadow);
    // Per-instance clip, also as coverage: the rect as a step, its rounded corners (when it has
    // any) as a distance field with one pixel of antialiasing. A square clip skips the field,
    // which also keeps an unbounded clip (infinite edges) away from it.
    let inside = step(in.clip.xy, in.pixel) * step(in.pixel, in.clip.zw);
    let clip_centre = (in.clip.xy + in.clip.zw) * 0.5;
    let clip_half = (in.clip.zw - in.clip.xy) * 0.5;
    let to_clip = in.pixel - clip_centre;
    let clip_d = rounded_box(to_clip, clip_half, corner_radius(to_clip, clip_half, in.clip_radii)) * globals.scale;
    let rounded = select(1.0, clamp(0.5 - clip_d, 0.0, 1.0), any(in.clip_radii > vec4f(0.0)));
    let alpha = cover * inside.x * inside.y * rounded * in.opacity;
    return vec4f(color.rgb * color.a, color.a) * alpha;
}
