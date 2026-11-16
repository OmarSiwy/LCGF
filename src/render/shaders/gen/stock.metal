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

metal::float4 gradient(
    Frag in_1
) {
    bool local = {};
    metal::float4 to = metal::unpack_unorm4x8_to_float(in_1.params.y);
    float a = as_type<float>(in_1.params.z);
    metal::float2 dir = metal::float2(metal::cos(a), metal::sin(a));
    float reach = metal::abs(in_1.half_.x * dir.x) + metal::abs(in_1.half_.y * dir.y);
    float t_lin = ((metal::dot(in_1.local, dir) / metal::max(reach, 0.000001)) * 0.5) + 0.5;
    metal::float2 centre = ((float2(as_type<half2>(in_1.params.z)) * 2.0) - metal::float2(1.0)) * in_1.half_;
    float t_rad = metal::length(in_1.local - centre) / metal::max(as_type<float>(in_1.params.w), 0.000001);
    float t = metal::clamp((in_1.params.x == k_radial) ? t_rad : t_lin, 0.0, 1.0);
    if (!((in_1.params.x == k_linear))) {
        local = in_1.params.x == k_radial;
    } else {
        local = true;
    }
    bool graded = local;
    return graded ? metal::mix(in_1.fill, to, t) : in_1.fill;
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
    float pos,
    float size,
    float lo,
    float hi,
    float src_lo,
    float src_hi
) {
    float start = (pos / metal::max(lo, 0.000001)) * src_lo;
    float end = 1.0 - (((size - pos) / metal::max(hi, 0.000001)) * src_hi);
    float mid = src_lo + (((pos - lo) / metal::max((size - lo) - hi, 0.000001)) * ((1.0 - src_lo) - src_hi));
    return (pos < lo) ? start : ((pos > (size - hi)) ? end : mid);
}

metal::float2 nine_uv(
    Frag in_2
) {
    metal::float4 dst = metal::unpack_unorm4x8_to_float(in_2.params.y) * 255.0;
    metal::float4 src = metal::float4(metal::unpack_unorm2x16_to_float(in_2.params.z), metal::unpack_unorm2x16_to_float(in_2.params.w));
    metal::float2 pos_1 = in_2.local + in_2.half_;
    metal::float2 size_1 = in_2.half_ * 2.0;
    float _e25 = nine_axis(pos_1.x, size_1.x, dst.x, dst.z, src.x, src.z);
    float _e32 = nine_axis(pos_1.y, size_1.y, dst.y, dst.w, src.y, src.w);
    metal::float2 f = metal::float2(_e25, _e32);
    return metal::mix(in_2.uv_rect.xy, in_2.uv_rect.zw, f);
}

float border_pattern(
    Frag in_3,
    constant Globals& globals
) {
    metal::float2 edge = in_3.half_ - metal::abs(in_3.local);
    bool along_y = edge.x < edge.y;
    float s = along_y ? (in_3.local.y + in_3.half_.y) : (in_3.local.x + in_3.half_.x);
    float across = metal::min(edge.x, edge.y);
    float dash = (in_3.params.x == k_dotted) ? in_3.border : as_type<float>(in_3.params.y);
    float period = metal::max(dash + as_type<float>(in_3.params.z), 0.001);
    float at = s - (metal::floor(s / period) * period);
    float _e47 = globals.scale;
    float dashed = metal::clamp((metal::min(at, dash - at) + 0.5) * _e47, 0.0, 1.0);
    float r_1 = in_3.border * 0.5;
    float _e62 = globals.scale;
    float dotted = metal::clamp(0.5 - ((metal::length(metal::float2(at - r_1, across - r_1)) - r_1) * _e62), 0.0, 1.0);
    return (in_3.params.x == k_dotted) ? dotted : ((in_3.params.x == k_dashed) ? dashed : 1.0);
}

metal::float4 material(
    Frag in_4,
    metal::texture2d<float, metal::access::sample> tex,
    metal::sampler samp
) {
    metal::float2 _e2 = nine_uv(in_4);
    metal::float2 uv = (in_4.params.x == k_nine) ? _e2 : in_4.uv;
    metal::float4 _e8 = gradient(in_4);
    metal::float4 _e11 = tex.sample(samp, uv);
    return _e8 * _e11;
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
    Frag _e111 = out;
    const auto _tmp = _e111;
    return vsOutput { _tmp.position, _tmp.local, _tmp.uv, _tmp.pixel, _tmp.half_, _tmp.radii, _tmp.fill, _tmp.border_color, _tmp.clip, _tmp.params, _tmp.uv_rect, _tmp.border, _tmp.opacity, _tmp.clip_radii };
}


struct fsInput {
    metal::float2 local_1 [[user(loc0), center_perspective]];
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
};
struct fsOutput {
    metal::float4 member_1 [[color(0)]];
};
fragment fsOutput fs(
  fsInput varyings_1 [[stage_in]]
, metal::float4 position [[position]]
, constant Globals& globals [[user(fake0)]]
, metal::texture2d<float, metal::access::sample> tex [[user(fake0)]]
, metal::sampler samp [[user(fake0)]]
) {
    const Frag in = { position, varyings_1.local_1, varyings_1.uv, varyings_1.pixel, varyings_1.half_2, varyings_1.radii_1, varyings_1.fill, varyings_1.border_color, varyings_1.clip, varyings_1.params, varyings_1.uv_rect, varyings_1.border, varyings_1.opacity, {}, varyings_1.clip_radii };
    float _e4 = corner_radius(in.local, in.half_, in.radii);
    float _e7 = rounded_box(in.local, in.half_, _e4);
    float _e10 = globals.scale;
    float d_1 = _e7 * _e10;
    float shape = metal::clamp(0.5 - d_1, 0.0, 1.0);
    float _e20 = globals.scale;
    float inner = metal::clamp(0.5 - (d_1 + (in.border * _e20)), 0.0, 1.0);
    float has_border = metal::step(0.001, in.border);
    bool is_shadow = in.params.x == k_shadow;
    float _e39 = border_pattern(in, globals);
    float on_border = (1.0 - metal::mix(1.0, inner, has_border)) * _e39;
    metal::float4 _e41 = material(in, tex, samp);
    metal::float4 color = is_shadow ? in.fill : metal::mix(_e41, in.border_color, on_border);
    float _e48 = globals.scale;
    float _e53 = shadow_coverage(d_1 / _e48, as_type<float>(in.params.y));
    float cover = is_shadow ? _e53 : shape;
    metal::float2 inside = metal::step(in.clip.xy, in.pixel) * metal::step(in.pixel, in.clip.zw);
    metal::float2 clip_centre = (in.clip.xy + in.clip.zw) * 0.5;
    metal::float2 clip_half = (in.clip.zw - in.clip.xy) * 0.5;
    metal::float2 to_clip = in.pixel - clip_centre;
    float _e81 = corner_radius(to_clip, clip_half, in.clip_radii);
    float _e82 = rounded_box(to_clip, clip_half, _e81);
    float _e85 = globals.scale;
    float clip_d = _e82 * _e85;
    float rounded = metal::any(in.clip_radii > metal::float4(0.0)) ? metal::clamp(0.5 - clip_d, 0.0, 1.0) : 1.0;
    float alpha = (((cover * inside.x) * inside.y) * rounded) * in.opacity;
    return fsOutput { metal::float4(color.xyz * color.w, color.w) * alpha };
}
