// language: metal1.0
#include <metal_stdlib>
#include <simd/simd.h>

using metal::uint;

struct Globals {
    metal::float2 viewport;
    float scale;
    float pad;
};
struct Instance {
    metal::float4 rect;
    metal::float4 clip;
    metal::uint4 params;
    metal::float4 uv;
    metal::float4 fill;
    metal::float4 border_color;
    metal::float4 radii;
    float border;
    float opacity;
    char _pad9[8];
    metal::float4 xform_abcd;
    metal::float2 xform_t;
    char _pad11[8];
    metal::float4 clip_radii;
};
struct Frag {
    metal::float4 position;
    metal::float2 local;
    metal::float2 uv;
    metal::float2 pixel;
    metal::float2 half_;
    metal::float4 radii;
    metal::float4 fill;
    metal::float4 border_color;
    metal::float4 clip;
    metal::uint4 params;
    metal::float4 uv_rect;
    float border;
    float opacity;
    char _pad13[8];
    metal::float4 clip_radii;
    metal::float4 to_rect;
    metal::float2 to_rect_off;
    char _pad16[8];
};
constant uint k_shadow = 3u;
constant uint k_linear = 1u;
constant uint k_radial = 2u;
constant uint k_nine = 4u;
constant uint k_dashed = 5u;
constant uint k_dotted = 6u;

float corner_radius(
    metal::float2 p,
    metal::float2 half_,
    metal::float4 radii
) {
    float right = (p.y > 0.0) ? radii.z : radii.y;
    float left = (p.y > 0.0) ? radii.w : radii.x;
    return metal::min((p.x > 0.0) ? right : left, metal::min(half_.x, half_.y));
}

float rounded_box(
    metal::float2 p_1,
    metal::float2 half_1,
    float r
) {
    metal::float2 q = (metal::abs(p_1) - half_1) + metal::float2(r);
    return (metal::length(metal::max(q, metal::float2(0.0))) + metal::min(metal::max(q.x, q.y), 0.0)) - r;
}

metal::float2 rect_pos(
    Frag in_1
) {
    return ((in_1.to_rect.xy * in_1.position.x) + (in_1.to_rect.zw * in_1.position.y)) + in_1.to_rect_off;
}

float floor_div(
    float num,
    float den
) {
    float q_1 = metal::floor(num / den);
    return (q_1 + ((((q_1 + 1.0) * den) <= num) ? 1.0 : 0.0)) - (((q_1 * den) > num) ? 1.0 : 0.0);
}

float texel_centre(
    float pos,
    float size,
    float uv0_,
    float uv1_,
    float n
) {
    float s = metal::max(size, 0.000001);
    float a = uv0_ * n;
    float whole = metal::floor(a);
    float _e15 = floor_div(((a - whole) * s) + (((uv1_ - uv0_) * n) * pos), s);
    float k = whole + _e15;
    return (metal::clamp(k, 0.0, n - 1.0) + 0.5) / n;
}

metal::float2 nearest_uv(
    Frag in_2,
    metal::texture2d<float, metal::access::sample> tex
) {
    metal::float2 _e1 = rect_pos(in_2);
    metal::float2 n_1 = static_cast<metal::float2>(metal::uint2(tex.get_width(), tex.get_height()));
    metal::float2 size_2 = in_2.half_ * 2.0;
    float _e15 = texel_centre(_e1.x, size_2.x, in_2.uv_rect.x, in_2.uv_rect.z, n_1.x);
    float _e23 = texel_centre(_e1.y, size_2.y, in_2.uv_rect.y, in_2.uv_rect.w, n_1.y);
    return metal::float2(_e15, _e23);
}

metal::float4 gradient(
    Frag in_3
) {
    bool local_1 = {};
    metal::float4 to = metal::unpack_unorm4x8_to_float(in_3.params.y);
    float a_1 = as_type<float>(in_3.params.z);
    metal::float2 dir = metal::float2(metal::cos(a_1), metal::sin(a_1));
    float reach = metal::abs(in_3.half_.x * dir.x) + metal::abs(in_3.half_.y * dir.y);
    float t_lin = ((metal::dot(in_3.local, dir) / metal::max(reach, 0.000001)) * 0.5) + 0.5;
    metal::float2 centre = ((float2(as_type<half2>(in_3.params.z)) * 2.0) - metal::float2(1.0)) * in_3.half_;
    float t_rad = metal::length(in_3.local - centre) / metal::max(as_type<float>(in_3.params.w), 0.000001);
    float t = metal::clamp((in_3.params.x == k_radial) ? t_rad : t_lin, 0.0, 1.0);
    if (!((in_3.params.x == k_linear))) {
        local_1 = in_3.params.x == k_radial;
    } else {
        local_1 = true;
    }
    bool graded = local_1;
    return graded ? metal::mix(in_3.fill, to, t) : in_3.fill;
}

float shadow_coverage(
    float d,
    float sigma
) {
    float x = d / (metal::max(sigma, 0.001) * 1.4142135);
    float x2_ = x * x;
    float e = metal::sign(x) * metal::sqrt(1.0 - metal::exp((-(x2_) * (1.2732395 + (0.147 * x2_))) / (1.0 + (0.147 * x2_))));
    return 0.5 - (0.5 * e);
}

float nine_axis(
    float pos_1,
    float size_1,
    float lo,
    float hi,
    float src_lo,
    float src_hi
) {
    float start = (pos_1 / metal::max(lo, 0.000001)) * src_lo;
    float end = 1.0 - (((size_1 - pos_1) / metal::max(hi, 0.000001)) * src_hi);
    float mid = src_lo + (((pos_1 - lo) / metal::max((size_1 - lo) - hi, 0.000001)) * ((1.0 - src_lo) - src_hi));
    return (pos_1 < lo) ? start : ((pos_1 > (size_1 - hi)) ? end : mid);
}

metal::float2 nine_uv(
    Frag in_4
) {
    metal::float4 dst = metal::unpack_unorm4x8_to_float(in_4.params.y) * 255.0;
    metal::float4 src = metal::float4(metal::unpack_unorm2x16_to_float(in_4.params.z), metal::unpack_unorm2x16_to_float(in_4.params.w));
    metal::float2 pos_2 = in_4.local + in_4.half_;
    metal::float2 size_3 = in_4.half_ * 2.0;
    float _e25 = nine_axis(pos_2.x, size_3.x, dst.x, dst.z, src.x, src.z);
    float _e32 = nine_axis(pos_2.y, size_3.y, dst.y, dst.w, src.y, src.w);
    metal::float2 f = metal::float2(_e25, _e32);
    return metal::mix(in_4.uv_rect.xy, in_4.uv_rect.zw, f);
}

float border_pattern(
    Frag in_5,
    constant Globals& globals
) {
    metal::float2 _e1 = rect_pos(in_5);
    metal::float2 edge = in_5.half_ - metal::abs(_e1 - in_5.half_);
    bool along_y = edge.x < edge.y;
    float s_1 = along_y ? _e1.y : _e1.x;
    float across = metal::min(edge.x, edge.y);
    float dash = (in_5.params.x == k_dotted) ? in_5.border : as_type<float>(in_5.params.y);
    float period = metal::max(dash + as_type<float>(in_5.params.z), 0.001);
    float _e31 = floor_div(s_1, period);
    float at = s_1 - (_e31 * period);
    float _e40 = globals.scale;
    float dashed = metal::clamp((metal::min(at, dash - at) + 0.5) * _e40, 0.0, 1.0);
    float r_1 = in_5.border * 0.5;
    float _e55 = globals.scale;
    float dotted = metal::clamp(0.5 - ((metal::length(metal::float2(at - r_1, across - r_1)) - r_1) * _e55), 0.0, 1.0);
    return (in_5.params.x == k_dotted) ? dotted : ((in_5.params.x == k_dashed) ? dashed : 1.0);
}

metal::float4 material(
    Frag in_6
) {
    float width = metal::max(as_type<float>(in_6.params.z), 1.0);
    float band = metal::fract((in_6.local.x + in_6.local.y) / (2.0 * width));
    return (band > 0.5) ? metal::unpack_unorm4x8_to_float(in_6.params.y) : in_6.fill;
}

struct vsInput {
    metal::float4 rect [[attribute(0)]];
    metal::float4 clip [[attribute(1)]];
    metal::uint4 params [[attribute(2)]];
    metal::float4 uv [[attribute(3)]];
    metal::float4 fill [[attribute(4)]];
    metal::float4 border_color [[attribute(5)]];
    metal::float4 radii_1 [[attribute(6)]];
    float border [[attribute(7)]];
    float opacity [[attribute(8)]];
    metal::float4 xform_abcd [[attribute(9)]];
    metal::float2 xform_t [[attribute(10)]];
    metal::float4 clip_radii [[attribute(11)]];
};
struct vsOutput {
    metal::float4 position [[position]];
    metal::float2 local [[user(loc0), center_perspective]];
    metal::float2 uv [[user(loc1), center_perspective]];
    metal::float2 pixel [[user(loc2), center_perspective]];
    metal::float2 half_ [[user(loc3), flat]];
    metal::float4 radii [[user(loc4), flat]];
    metal::float4 fill [[user(loc5), flat]];
    metal::float4 border_color [[user(loc6), flat]];
    metal::float4 clip [[user(loc7), flat]];
    metal::uint4 params [[user(loc8), flat]];
    metal::float4 uv_rect [[user(loc9), flat]];
    float border [[user(loc10), flat]];
    float opacity [[user(loc11), flat]];
    metal::float4 clip_radii [[user(loc12), flat]];
    metal::float4 to_rect [[user(loc13), flat]];
    metal::float2 to_rect_off [[user(loc14), flat]];
};
vertex vsOutput vs(
  vsInput varyings [[stage_in]]
, uint vi [[vertex_id]]
, constant Globals& globals [[user(fake0)]]
) {
    const Instance inst = { varyings.rect, varyings.clip, varyings.params, varyings.uv, varyings.fill, varyings.border_color, varyings.radii_1, varyings.border, varyings.opacity, {}, varyings.xform_abcd, varyings.xform_t, {}, varyings.clip_radii };
    Frag out = {};
    metal::float2 corner = metal::float2(static_cast<float>(vi & 1u), static_cast<float>(vi >> 1u));
    float grow = (inst.params.x == k_shadow) ? (3.0 * as_type<float>(inst.params.y)) : 0.0;
    metal::float2 p_2 = metal::mix(inst.rect.xy - metal::float2(grow), inst.rect.zw + metal::float2(grow), corner);
    metal::float2 screen = ((inst.xform_abcd.xy * p_2.x) + (inst.xform_abcd.zw * p_2.y)) + inst.xform_t;
    metal::float2 _e44 = globals.viewport;
    out.position = metal::float4(((screen / _e44) * metal::float2(2.0, -2.0)) + metal::float2(-1.0, 1.0), 0.0, 1.0);
    out.local = p_2 - ((inst.rect.xy + inst.rect.zw) * 0.5);
    out.uv = metal::mix(inst.uv.xy, inst.uv.zw, (p_2 - inst.rect.xy) / metal::max(inst.rect.zw - inst.rect.xy, metal::float2(0.000001)));
    out.pixel = screen;
    out.half_ = (inst.rect.zw - inst.rect.xy) * 0.5;
    out.radii = inst.radii;
    out.border = inst.border;
    out.opacity = inst.opacity;
    out.clip_radii = inst.clip_radii;
    out.fill = inst.fill;
    out.border_color = inst.border_color;
    out.clip = inst.clip;
    out.params = inst.params;
    out.uv_rect = inst.uv;
    metal::float4 a_2 = inst.xform_abcd;
    float _e121 = globals.scale;
    float k_1 = 1.0 / (((inst.xform_abcd.x * inst.xform_abcd.w) - (inst.xform_abcd.y * inst.xform_abcd.z)) * _e121);
    out.to_rect = metal::float4(inst.xform_abcd.w * k_1, -(inst.xform_abcd.y) * k_1, -(inst.xform_abcd.z) * k_1, inst.xform_abcd.x * k_1);
    metal::float4 _e139 = out.to_rect;
    float _e145 = globals.scale;
    metal::float4 _e149 = out.to_rect;
    float _e155 = globals.scale;
    out.to_rect_off = -(((_e139.xy * (inst.xform_t.x * _e145)) + (_e149.zw * (inst.xform_t.y * _e155)))) - inst.rect.xy;
    Frag _e163 = out;
    const auto _tmp = _e163;
    return vsOutput { _tmp.position, _tmp.local, _tmp.uv, _tmp.pixel, _tmp.half_, _tmp.radii, _tmp.fill, _tmp.border_color, _tmp.clip, _tmp.params, _tmp.uv_rect, _tmp.border, _tmp.opacity, _tmp.clip_radii, _tmp.to_rect, _tmp.to_rect_off };
}


struct fsInput {
    metal::float2 local_2 [[user(loc0), center_perspective]];
    metal::float2 uv [[user(loc1), center_perspective]];
    metal::float2 pixel [[user(loc2), center_perspective]];
    metal::float2 half_2 [[user(loc3), flat]];
    metal::float4 radii_1 [[user(loc4), flat]];
    metal::float4 fill [[user(loc5), flat]];
    metal::float4 border_color [[user(loc6), flat]];
    metal::float4 clip [[user(loc7), flat]];
    metal::uint4 params [[user(loc8), flat]];
    metal::float4 uv_rect [[user(loc9), flat]];
    float border [[user(loc10), flat]];
    float opacity [[user(loc11), flat]];
    metal::float4 clip_radii [[user(loc12), flat]];
    metal::float4 to_rect [[user(loc13), flat]];
    metal::float2 to_rect_off [[user(loc14), flat]];
};
struct fsOutput {
    metal::float4 member_1 [[color(0)]];
};
fragment fsOutput fs(
  fsInput varyings_1 [[stage_in]]
, metal::float4 position [[position]]
, constant Globals& globals [[user(fake0)]]
) {
    const Frag in = { position, varyings_1.local_2, varyings_1.uv, varyings_1.pixel, varyings_1.half_2, varyings_1.radii_1, varyings_1.fill, varyings_1.border_color, varyings_1.clip, varyings_1.params, varyings_1.uv_rect, varyings_1.border, varyings_1.opacity, {}, varyings_1.clip_radii, varyings_1.to_rect, varyings_1.to_rect_off };
    float pattern = 1.0;
    bool local = {};
    float cover = {};
    float rounded = 1.0;
    float _e4 = corner_radius(in.local, in.half_, in.radii);
    float _e7 = rounded_box(in.local, in.half_, _e4);
    float _e10 = globals.scale;
    float d_1 = _e7 * _e10;
    float shape = metal::clamp(0.5 - d_1, 0.0, 1.0);
    float _e20 = globals.scale;
    float inner = metal::clamp(0.5 - (d_1 + (in.border * _e20)), 0.0, 1.0);
    float has_border = metal::step(0.001, in.border);
    bool is_shadow = in.params.x == k_shadow;
    if (!((in.params.x == k_dashed))) {
        local = in.params.x == k_dotted;
    } else {
        local = true;
    }
    bool _e49 = local;
    if (_e49) {
        float _e50 = border_pattern(in, globals);
        pattern = _e50;
    }
    float _e55 = pattern;
    float on_border = (1.0 - metal::mix(1.0, inner, has_border)) * _e55;
    metal::float4 _e57 = material(in);
    metal::float4 color = is_shadow ? in.fill : metal::mix(_e57, in.border_color, on_border);
    cover = shape;
    if (is_shadow) {
        float _e65 = globals.scale;
        float _e70 = shadow_coverage(d_1 / _e65, as_type<float>(in.params.y));
        cover = _e70;
    }
    metal::float2 inside = metal::step(in.clip.xy, in.pixel) * metal::step(in.pixel, in.clip.zw);
    if (metal::any(in.clip_radii > metal::float4(0.0))) {
        metal::float2 clip_centre = (in.clip.xy + in.clip.zw) * 0.5;
        metal::float2 clip_half = (in.clip.zw - in.clip.xy) * 0.5;
        metal::float2 to_clip = in.pixel - clip_centre;
        float _e104 = corner_radius(to_clip, clip_half, in.clip_radii);
        float _e105 = rounded_box(to_clip, clip_half, _e104);
        float _e108 = globals.scale;
        float clip_d = _e105 * _e108;
        rounded = metal::clamp(0.5 - clip_d, 0.0, 1.0);
    }
    float _e115 = cover;
    float _e120 = rounded;
    float alpha = (((_e115 * inside.x) * inside.y) * _e120) * in.opacity;
    return fsOutput { metal::float4(color.xyz * color.w, color.w) * alpha };
}
