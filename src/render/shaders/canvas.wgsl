// The canvas batch (src/draw/canvas.zig) on the GPU: one instance per row, a triangle strip of
// four vertices over the pixel box the row can touch, shaded by its distance function. The
// software back end's twin is src/render/sw/canvas.zig; the canvas goldens hold the two to the
// same pixels, so every expression below repeats sw's (canvas.zig `Shape.of`, `segmentDist`,
// `rectDist`, `arcDist`, `polygonDist`, `glyphLocal`, `coverage`) in the same order. Per-row
// constants are worked out once in the vertex stage and passed flat.
//
// Rows come from two instance-step buffers, `pos` (sint32x4) and `look` (uint32x4), a third
// that holds each row's own index (uint32), so overrides find the row without
// @builtin(instance_index) (docs/guide/gpu.md: GL ES emulates the first instance by offsetting
// the buffers), and a fourth of colours (uint32; zeros for a batch without). Polygon vertices
// are read by `vert`, which canvas.zig `shader` appends: from a storage buffer, or on GL ES 3.0
// (no storage buffers in the fragment stage) from an r32uint texture of two texels a vertex.

// The canvas.zig `View`, then the node and the draw's own values, then the palette and the
// overrides: canvas.zig `Uniforms`.
struct Draw {
    origin: vec2i,
    base: vec2f,
    scale: f32,
    px: f32,
    pad0: u32,
    pad1: u32,
    // The node's rect and clip in physical pixels: a pixel is drawn when its centre is in the
    // half-open rect and in the closed clip, as sw's `draw` decides.
    rect: vec4f,
    clip: vec4f,
    // The target, physical pixels.
    size: vec2f,
    opacity: f32,
    // Where the batch starts in the row buffers and the vertex buffer, its vertex count, the
    // number of overrides and of palette layers.
    row_base: u32,
    vert_base: u32,
    vert_len: u32,
    overrides: u32,
    layers: u32,
    // The node's transform (sw canvas.zig `Space`): `inv` and `inv_t` take a pixel centre to
    // the node's own physical space, where `rect`, the instances and their distances are;
    // `fwd` and `fwd_t` take that space to the screen. Identity for most nodes.
    inv: vec4f,
    inv_t: vec2f,
    fwd_t: vec2f,
    fwd: vec4f,
    // The clip's corner radii (tl, tr, br, bl), its centre and half size, logical pixels;
    // `rounded` when a radius is above 0.
    radii: vec4f,
    clip_box: vec4f,
    px_scale: f32,
    inv_scale: f32,
    rounded: u32,
    // stroke, fill, width (f32 bits), flags.
    palette: array<vec4u, 256>,
    // first, count, colour, 0.
    override_rows: array<vec4u, 512>,
}
@group(0) @binding(0) var<uniform> u: Draw;
@group(1) @binding(0) var atlas: texture_2d<f32>;

struct Row {
    @location(0) pos: vec4i,
    @location(1) look: vec4u,
    @location(2) row: u32,
    // The row's own colour (canvas.zig `Instances.colors`): 0, or a colour over everything else.
    @location(3) mark: u32,
}

struct Frag {
    @builtin(position) position: vec4f,
    // Segment: a, b. Rect: x0, y0, x1, y1. Arc: centre. Polygon: its box. Glyph: anchor, w, h.
    @location(0) @interpolate(flat) p: vec4f,
    // half, radius, square, chain distance at a
    @location(1) @interpolate(flat) m0: vec4f,
    // dash on length, period, mid (cos, sin)
    @location(2) @interpolate(flat) m1: vec4f,
    // aperture (sin, cos), 1 for a full ring (rect, polygon: 1 when stroked), the stroke's
    // half width (0 unstroked)
    @location(3) @interpolate(flat) m2: vec4f,
    // segment: ux, uy, half length; glyph: texel steps du, dv, 1 for a distance glyph
    @location(4) @interpolate(flat) m3: vec4f,
    @location(5) @interpolate(flat) stroke: vec4f,
    // inside an outline: the fill, or the stroke at alpha 0 when unfilled
    @location(6) @interpolate(flat) base: vec4f,
    // kind, round, polygon first vertex, vertex count
    @location(7) @interpolate(flat) k: vec4u,
    // glyph: u0, v0
    @location(8) @interpolate(flat) uv: vec2f,
}

const sqrt2 = 1.41421356237309504880;
// canvas.zig `distance_spread`.
const spread = 4.0;
const tau = 6.28318530717958647692;

fn wx(w: i32) -> f32 {
    return u.base.x + f32(w - u.origin.x) * u.scale;
}

fn wy(w: i32) -> f32 {
    return u.base.y + f32(w - u.origin.y) * u.scale;
}

// sw's rgba(): a colour's bytes in 0..1.
fn rgba(c: u32) -> vec4f {
    return vec4f(f32(c & 255u), f32((c >> 8u) & 255u), f32((c >> 16u) & 255u), f32(c >> 24u)) / 255.0;
}

fn unorm16(v: u32) -> f32 {
    return f32(v & 0xffffu) / 65535.0;
}

// The colour of row i: the last override whose range holds it, if any.
fn override_of(i: u32, colour: u32) -> u32 {
    var found = colour;
    for (var j = 0u; j < min(u.overrides, 512u); j++) {
        let o = u.override_rows[j];
        found = select(found, o.z, i - o.x < o.y);
    }
    return found;
}

@vertex
fn vs(@builtin(vertex_index) vi: u32, r: Row) -> Frag {
    var out: Frag;
    let h = r.look.x;
    let layer = h >> 24u;
    // An empty palette: every row has `Layer.default` (white, 1 px, solid, fills drawn).
    let none = vec4u(0xffffffffu, 0xffffffffu, bitcast<u32>(1.0), 3u);
    let row = select(u.palette[min(layer, 255u)], none, u.layers == 0u);
    out.position = vec4f(-2.0, -2.0, 0.0, 1.0);
    // Dead, on a hidden layer or past the palette: no pixels (canvas.zig `shown`).
    if ((h & 512u) != 0u || (layer >= u.layers && u.layers != 0u) || (row.w & 2u) == 0u) {
        return out;
    }
    let kind = h & 15u;
    let cap = (h >> 4u) & 3u;
    let width = select(bitcast<f32>(row.z) * u.px, f32(r.look.w) * u.scale, (h & 256u) != 0u);
    let corner = vec4f(wx(r.pos.x), wy(r.pos.y), wx(r.pos.z), wy(r.pos.w));
    // The layer's dash (canvas.zig `Layer.dashLengths`): on, and the period (0: solid).
    let dash_on = f32((row.w >> 2u) & 32767u) / 16.0;
    let dash_off = f32(row.w >> 17u) / 16.0;
    let on = dash_on * u.px;
    let period = select(0.0, on + dash_off * u.px, dash_on > 0.0 && dash_off > 0.0);
    let half = width * 0.5;
    let stroked = (h & 128u) != 0u || kind == 0u || kind == 2u;
    var p = corner;
    var radius = f32(r.look.y) * u.scale;
    var grow = half * f32(stroked);
    var m1 = vec4f(0.0, 0.0, 1.0, 0.0);
    var m2 = vec4f(0.0, 1.0, 0.0, 0.0);
    var m3 = vec4f(0.0);
    var chain = 0.0;
    var box = vec4f(0.0);
    if (kind == 0u) {
        // Segment: the constants of `segmentDist`.
        grow = half * sqrt2;
        chain = f32(r.look.y) * u.scale;
        m1 = vec4f(on, period, 1.0, 0.0);
        let dx = corner.z - corner.x;
        let dy = corner.w - corner.y;
        let l = sqrt(dx * dx + dy * dy);
        let kk = 1.0 / max(l, 1e-6);
        m3 = vec4f(select(1.0, dx * kk, l > 1e-6), dy * kk, l * 0.5, 0.0);
    }
    if (kind == 2u) {
        let rr = f32(bitcast<u32>(r.pos.z)) * u.scale;
        let start = f32(r.look.z & 0xffffu);
        let sweep = f32(r.look.z >> 16u) / 65535.0 * tau;
        let m = start / 65536.0 * tau + sweep / 2.0;
        radius = rr;
        chain = f32(r.look.y) * u.scale;
        m1 = vec4f(on, period, cos(m), sin(m));
        m3 = vec4f(sweep / 2.0, 0.0, 0.0, 0.0);
        m2 = vec4f(max(sin(sweep / 2.0), 0.0), cos(sweep / 2.0), f32((r.look.z >> 16u) == 0xffffu), 0.0);
        p = vec4f(corner.x, corner.y, 0.0, 0.0);
        let e = rr + half;
        box = vec4f(corner.x - e - 1.0, corner.y - e - 1.0, corner.x + e + 1.0, corner.y + e + 1.0);
    } else if (kind == 4u) {
        let gw = f32(bitcast<u32>(r.pos.z)) * u.scale;
        let gh = f32(bitcast<u32>(r.pos.w)) * u.scale;
        // canvas.zig `turn`: cos and sin of q quarter turns.
        let q = (h >> 16u) & 3u;
        let c = array<f32, 4>(1.0, 0.0, -1.0, 0.0);
        m1 = vec4f(0.0, 0.0, c[q], c[(q + 3u) & 3u]);
        p = vec4f(corner.x, corner.y, gw, gh);
        // canvas.zig: the turned box, its x axis (c w, s w) from the anchor, its y (-s h, c h).
        let ax = m1.z * gw;
        let ay = m1.w * gw;
        let bx = -m1.w * gh;
        let by = m1.z * gh;
        box = vec4f(corner.x + min(ax, 0.0) + min(bx, 0.0) - 1.0, corner.y + min(ay, 0.0) + min(by, 0.0) - 1.0,
                    corner.x + max(ax, 0.0) + max(bx, 0.0) + 1.0, corner.y + max(ay, 0.0) + max(by, 0.0) + 1.0);
        let tu0 = unorm16(r.look.y);
        let tv0 = unorm16(r.look.y >> 16u);
        out.uv = vec2f(tu0, tv0);
        let distance = f32((h & 262144u) != 0u);
        m3 = vec4f((unorm16(r.look.z) - tu0) / max(gw, 1e-6), (unorm16(r.look.z >> 16u) - tv0) / max(gh, 1e-6), distance, 0.0);
    } else {
        box = vec4f(min(corner.x, corner.z) - grow - 1.0, min(corner.y, corner.w) - grow - 1.0,
                    max(corner.x, corner.z) + grow + 1.0, max(corner.y, corner.w) + grow + 1.0);
    }
    let own = r.mark != 0u;
    let colour = select(override_of(r.row - u.row_base, row.x), r.mark, own);
    let fill = select(override_of(r.row - u.row_base, row.y), r.mark, own);
    let filled = (h & 64u) != 0u && (row.w & 1u) != 0u;
    out.stroke = rgba(colour);
    out.base = select(vec4f(out.stroke.rgb, 0.0), rgba(fill), filled);
    out.p = p;
    out.m0 = vec4f(half, radius, f32(cap == 1u), chain);
    out.m1 = m1;
    // m2.z: an arc's full-ring flag, a rect's or polygon's stroked flag.
    out.m2 = vec4f(m2.x, m2.y, select(f32(stroked), m2.z, kind == 2u), half * f32(stroked));
    out.m3 = m3;
    out.k = vec4u(kind, u32(cap == 2u), r.look.y, r.look.z);
    // Whole pixels, as sw's `pixels` rounds the box: the strip covers exactly the pixels sw
    // shades, and the clip below cuts them to the node.
    // On screen: the bounds of the box's four corners under the node's transform (the box
    // itself for an untransformed node, exactly).
    let c0 = screen(box.xy);
    let c1 = screen(box.zy);
    let c2 = screen(box.xw);
    let c3 = screen(box.zw);
    let lo = clamp(floor(min(min(c0, c1), min(c2, c3))), vec2f(0.0), vec2f(16777216.0));
    let hi = clamp(ceil(max(max(c0, c1), max(c2, c3))), vec2f(0.0), vec2f(16777216.0));
    let at = select(lo, hi, vec2<bool>((vi & 1u) != 0u, (vi & 2u) != 0u));
    out.position = vec4f(at / u.size * vec2f(2.0, -2.0) + vec2f(-1.0, 1.0), 0.0, 1.0);
    return out;
}

// The atlas's alpha byte at texel position (fx, fy), texel centres at halves, between the four
// nearest texels, each clamped to the atlas: sw canvas.zig's `bilinear`.
fn distance_at(fx: f32, fy: f32, n: vec2f) -> f32 {
    let gx = fx - 0.5;
    let gy = fy - 0.5;
    let x0 = floor(gx);
    let y0 = floor(gy);
    let ax = gx - x0;
    let ay = gy - y0;
    let xa = u32(min(max(x0, 0.0), n.x - 1.0));
    let xb = u32(min(max(x0 + 1.0, 0.0), n.x - 1.0));
    let ya = u32(min(max(y0, 0.0), n.y - 1.0));
    let yb = u32(min(max(y0 + 1.0, 0.0), n.y - 1.0));
    let t0 = round(textureLoad(atlas, vec2u(xa, ya), 0).a * 255.0);
    let t1 = round(textureLoad(atlas, vec2u(xb, ya), 0).a * 255.0);
    let t2 = round(textureLoad(atlas, vec2u(xa, yb), 0).a * 255.0);
    let t3 = round(textureLoad(atlas, vec2u(xb, yb), 0).a * 255.0);
    let top = t0 + (t1 - t0) * ax;
    let bottom = t2 + (t3 - t2) * ax;
    return top + (bottom - top) * ay;
}

fn screen(p: vec2f) -> vec2f {
    return vec2f(u.fwd.x * p.x + u.fwd.z * p.y + u.fwd_t.x, u.fwd.y * p.x + u.fwd.w * p.y + u.fwd_t.y);
}

// quad.wgsl's clip corners: the radius of the quadrant p is in, capped by the half size.
fn corner_radius(p: vec2f, half: vec2f, radii: vec4f) -> f32 {
    let right = select(radii.y, radii.z, p.y > 0.0);
    let left = select(radii.x, radii.w, p.y > 0.0);
    return min(select(left, right, p.x > 0.0), min(half.x, half.y));
}

fn rounded_box(p: vec2f, half: vec2f, r: f32) -> f32 {
    let q = abs(p) - half + vec2f(r);
    return len2(max(q.x, 0.0), max(q.y, 0.0)) + min(max(q.x, q.y), 0.0) - r;
}

// How much of a dash is on at chain distance `at` (canvas.zig `dashCover`).
fn dash_cover(at: f32, on: f32, period: f32) -> f32 {
    if (period == 0.0) {
        return 1.0;
    }
    let m = at - floor(at / period) * period;
    return min(max(min(m, on - m) + 0.5, 0.0), 1.0);
}

fn len2(x: f32, y: f32) -> f32 {
    return sqrt(x * x + y * y);
}

fn box_dist(qx: f32, qy: f32) -> f32 {
    return len2(max(qx, 0.0), max(qy, 0.0)) + min(max(qx, qy), 0.0);
}

fn coverage(d: f32) -> f32 {
    return min(max(0.5 - d, 0.0), 1.0);
}

fn rect_dist(px: f32, py: f32, in: Frag) -> f32 {
    let hx = abs(in.p.z - in.p.x) * 0.5;
    let hy = abs(in.p.w - in.p.y) * 0.5;
    let r = min(in.m0.y, min(hx, hy));
    let qx = abs(px - (in.p.x + in.p.z) * 0.5) - hx + r;
    let qy = abs(py - (in.p.y + in.p.w) * 0.5) - hy + r;
    return box_dist(qx, qy) - r;
}

fn polygon_dist(px: f32, py: f32, first: u32, count: u32) -> f32 {
    // sw clamps the vertex range to the batch's vertices.
    let f = min(first, u.vert_len);
    let n = min(count, u.vert_len - f);
    if (n == 0u) {
        return 3.0e38;
    }
    var best = 3.0e38;
    var winding = 0i;
    let last = vert(u.vert_base + f + n - 1u);
    var ax = wx(last.x);
    var ay = wy(last.y);
    for (var j = 0u; j < n; j++) {
        let v = vert(u.vert_base + f + j);
        let bx = wx(v.x);
        let by = wy(v.y);
        let ex = bx - ax;
        let ey = by - ay;
        let ox = px - ax;
        let oy = py - ay;
        let t = min(max((ox * ex + oy * ey) * (1.0 / max(ex * ex + ey * ey, 1e-12)), 0.0), 1.0);
        let dx = ox - ex * t;
        let dy = oy - ey * t;
        best = min(best, dx * dx + dy * dy);
        let left = ex * oy - ey * ox;
        let up = ay <= py && by > py && left > 0.0;
        let down = ay > py && by <= py && left < 0.0;
        winding += i32(up) - i32(down);
        ax = bx;
        ay = by;
    }
    let d = sqrt(best);
    return select(d, -d, winding != 0i);
}

@fragment
fn fs(in: Frag) -> @location(0) vec4f {
    let sx = in.position.x;
    let sy = in.position.y;
    // The pixel in the node's own space; the node's rect is tested there, the clip on screen.
    let px = u.inv.x * sx + u.inv.z * sy + u.inv_t.x;
    let py = u.inv.y * sx + u.inv.w * sy + u.inv_t.y;
    let inside = px >= u.rect.x && px < u.rect.z && py >= u.rect.y && py < u.rect.w &&
                 sx >= u.clip.x && sx <= u.clip.z && sy >= u.clip.y && sy <= u.clip.w;
    var keep = f32(inside);
    if (u.rounded != 0u) {
        let l = vec2f(sx * u.inv_scale - u.clip_box.x, sy * u.inv_scale - u.clip_box.y);
        let corner = rounded_box(l, u.clip_box.zw, corner_radius(l, u.clip_box.zw, u.radii)) * u.px_scale;
        keep *= min(max(0.5 - corner, 0.0), 1.0);
    }
    let half = in.m0.x;
    let square = in.m0.z;
    let hw = in.m2.w;
    var colour = in.stroke;
    var alpha = 0.0;
    let kind = in.k.x;
    let round = in.k.y != 0u;
    if (kind == 0u) {
        let ux = in.m3.x;
        let uy = in.m3.y;
        let h = in.m3.z;
        let ox = px - in.p.x;
        let oy = py - in.p.y;
        let t = ox * ux + oy * uy;
        let along = abs(t - h);
        let across = abs(oy * ux - ox * uy);
        let capsule = len2(max(along - h, 0.0), across) - half;
        let flat_end = box_dist(along - h - half * square, across - half);
        let d = select(flat_end, capsule, round);
        alpha = coverage(d) * dash_cover(t + in.m0.w, in.m1.x, in.m1.y);
    } else if (kind == 2u) {
        let lx = px - in.p.x;
        let ly = py - in.p.y;
        let mc = in.m1.z;
        let ms = in.m1.w;
        let y = lx * mc + ly * ms;
        let x = abs(ly * mc - lx * ms);
        let sa = in.m2.x;
        let ca = in.m2.y;
        let radius = in.m0.y;
        let ring = abs(len2(x, y) - radius) - half;
        // A full ring has no ends: nothing is past them.
        let past = select(x * ca - y * sa, -1.0e30, in.m2.z != 0.0);
        let disc = len2(x - sa * radius, y - ca * radius) - half;
        let flat_end = max(ring, past - half * square);
        // The dash along the centre line (canvas.zig `arcAlong`): the angle from the middle.
        let along = (atan2(ly * mc - lx * ms, y) + in.m3.x) * radius + in.m0.w;
        alpha = coverage(select(flat_end, select(ring, disc, past > 0.0), round)) * dash_cover(along, in.m1.x, in.m1.y);
    } else if (kind == 1u || kind == 3u) {
        var d = 0.0;
        if (kind == 1u) {
            d = rect_dist(px, py, in);
        } else {
            d = polygon_dist(px, py, in.k.z, in.k.w);
        }
        let outer = coverage(d - hw);
        let on = (1.0 - coverage(d + hw)) * in.m2.z;
        colour = in.base + (in.stroke - in.base) * on;
        alpha = outer;
    } else {
        let dx = px - in.p.x;
        let dy = py - in.p.y;
        let c = in.m1.z;
        let s = in.m1.w;
        let lx = c * dx + s * dy;
        let ly = c * dy - s * dx;
        let hit = lx >= 0.0 && lx < in.p.z && ly >= 0.0 && ly < in.p.w;
        let n = vec2f(textureDimensions(atlas));
        let tu = in.uv.x + lx * in.m3.x;
        let tv = in.uv.y + ly * in.m3.y;
        let tx = u32(min(max(floor(tu * n.x), 0.0), n.x - 1.0));
        let ty = u32(min(max(floor(tv * n.y), 0.0), n.y - 1.0));
        colour = in.stroke * textureLoad(atlas, vec2u(tx, ty), 0);
        if (in.m3.z > 0.5) {
            // A distance glyph (canvas.zig `bit.distance`): sw canvas.zig's, in its order.
            let d = (distance_at(tu * n.x, tv * n.y, n) - 128.0) * (spread / 127.0);
            let ppt = max(1.0 / (in.m3.x * n.x), 0.5 / spread);
            colour = vec4f(in.stroke.rgb, in.stroke.a * min(max(d * ppt + 0.5, 0.0), 1.0));
        }
        alpha = select(0.0, 1.0, hit);
    }
    let a = clamp(colour.a * (alpha * keep * u.opacity), 0.0, 1.0);
    return vec4f(clamp(colour.rgb, vec3f(0.0), vec3f(1.0)) * a, a);
}
