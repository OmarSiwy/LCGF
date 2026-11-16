#version 300 es

precision highp float;
precision highp int;

struct Globals {
    vec2 viewport;
    float scale;
    float pad;
};
struct Instance {
    vec4 rect;
    vec4 clip;
    uvec4 params;
    vec4 uv;
    vec4 fill;
    vec4 border_color;
    vec4 radii;
    float border;
    float opacity;
    vec4 xform_abcd;
    vec2 xform_t;
    vec4 clip_radii;
};
struct Frag {
    vec4 position;
    vec2 local;
    vec2 uv;
    vec2 pixel;
    vec2 half_;
    vec4 radii;
    vec4 fill;
    vec4 border_color;
    vec4 clip;
    uvec4 params;
    vec4 uv_rect;
    float border;
    float opacity;
    vec4 clip_radii;
    vec4 to_rect;
    vec2 to_rect_off;
};
const uint k_shadow = 3u;
const uint k_linear = 1u;
const uint k_radial = 2u;
const uint k_nine = 4u;
const uint k_dashed = 5u;
const uint k_dotted = 6u;

layout(std140) uniform Globals_block_0Fragment { Globals _group_0_binding_0_fs; };

smooth in vec2 _vs2fs_location0;
smooth in vec2 _vs2fs_location1;
smooth in vec2 _vs2fs_location2;
flat in vec2 _vs2fs_location3;
flat in vec4 _vs2fs_location4;
flat in vec4 _vs2fs_location5;
flat in vec4 _vs2fs_location6;
flat in vec4 _vs2fs_location7;
flat in uvec4 _vs2fs_location8;
flat in vec4 _vs2fs_location9;
flat in float _vs2fs_location10;
flat in float _vs2fs_location11;
flat in vec4 _vs2fs_location12;
flat in vec4 _vs2fs_location13;
flat in vec2 _vs2fs_location14;
layout(location = 0) out vec4 _fs2p_location0;

float corner_radius(vec2 p, vec2 half_, vec4 radii) {
    float right = ((p.y > 0.0) ? radii.z : radii.y);
    float left = ((p.y > 0.0) ? radii.w : radii.x);
    return min(((p.x > 0.0) ? right : left), min(half_.x, half_.y));
}

float rounded_box(vec2 p_1, vec2 half_1, float r) {
    vec2 q = ((abs(p_1) - half_1) + vec2(r));
    return ((length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0)) - r);
}

vec2 rect_pos(Frag in_1) {
    return (((in_1.to_rect.xy * in_1.position.x) + (in_1.to_rect.zw * in_1.position.y)) + in_1.to_rect_off);
}

float floor_div(float num, float den) {
    float q_1 = floor((num / den));
    return ((q_1 + ((((q_1 + 1.0) * den) <= num) ? 1.0 : 0.0)) - (((q_1 * den) > num) ? 1.0 : 0.0));
}

float texel_centre(float pos, float size, float uv0_, float uv1_, float n) {
    float s = max(size, 1e-6);
    float a = (uv0_ * n);
    float whole = floor(a);
    float _e15 = floor_div((((a - whole) * s) + (((uv1_ - uv0_) * n) * pos)), s);
    float k = (whole + _e15);
    return ((clamp(k, 0.0, (n - 1.0)) + 0.5) / n);
}

vec4 gradient(Frag in_3) {
    bool local = false;
    uint _e2 = in_3.params.y;
    vec4 to = (vec4(_e2 & 0xFFu, _e2 >> 8 & 0xFFu, _e2 >> 16 & 0xFFu, _e2 >> 24) / 255.0);
    float a_1 = uintBitsToFloat(in_3.params.z);
    vec2 dir = vec2(cos(a_1), sin(a_1));
    float reach = (abs((in_3.half_.x * dir.x)) + abs((in_3.half_.y * dir.y)));
    float t_lin = (((dot(in_3.local, dir) / max(reach, 1e-6)) * 0.5) + 0.5);
    vec2 centre = (((unpackHalf2x16(in_3.params.z) * 2.0) - vec2(1.0)) * in_3.half_);
    float t_rad = (length((in_3.local - centre)) / max(uintBitsToFloat(in_3.params.w), 1e-6));
    float t = clamp(((in_3.params.x == k_radial) ? t_rad : t_lin), 0.0, 1.0);
    if (!((in_3.params.x == k_linear))) {
        local = (in_3.params.x == k_radial);
    } else {
        local = true;
    }
    bool graded = local;
    return (graded ? mix(in_3.fill, to, t) : in_3.fill);
}

float shadow_coverage(float d, float sigma) {
    float x = (d / (max(sigma, 0.001) * 1.4142135));
    float x2_ = (x * x);
    float e = (sign(x) * sqrt((1.0 - exp(((-(x2_) * (1.2732395 + (0.147 * x2_))) / (1.0 + (0.147 * x2_)))))));
    return (0.5 - (0.5 * e));
}

float nine_axis(float pos_1, float size_1, float lo, float hi, float src_lo, float src_hi) {
    float start = ((pos_1 / max(lo, 1e-6)) * src_lo);
    float end = (1.0 - (((size_1 - pos_1) / max(hi, 1e-6)) * src_hi));
    float mid = (src_lo + (((pos_1 - lo) / max(((size_1 - lo) - hi), 1e-6)) * ((1.0 - src_lo) - src_hi)));
    return ((pos_1 < lo) ? start : ((pos_1 > (size_1 - hi)) ? end : mid));
}

vec2 nine_uv(Frag in_4) {
    uint _e2 = in_4.params.y;
    vec4 dst = ((vec4(_e2 & 0xFFu, _e2 >> 8 & 0xFFu, _e2 >> 16 & 0xFFu, _e2 >> 24) / 255.0) * 255.0);
    vec4 src = vec4(unpackUnorm2x16(in_4.params.z), unpackUnorm2x16(in_4.params.w));
    vec2 pos_2 = (in_4.local + in_4.half_);
    vec2 size_2 = (in_4.half_ * 2.0);
    float _e25 = nine_axis(pos_2.x, size_2.x, dst.x, dst.z, src.x, src.z);
    float _e32 = nine_axis(pos_2.y, size_2.y, dst.y, dst.w, src.y, src.w);
    vec2 f = vec2(_e25, _e32);
    return mix(in_4.uv_rect.xy, in_4.uv_rect.zw, f);
}

float border_pattern(Frag in_5) {
    vec2 _e1 = rect_pos(in_5);
    vec2 edge = (in_5.half_ - abs((_e1 - in_5.half_)));
    bool along_y = (edge.x < edge.y);
    float s_1 = (along_y ? _e1.y : _e1.x);
    float across = min(edge.x, edge.y);
    float dash = ((in_5.params.x == k_dotted) ? in_5.border : uintBitsToFloat(in_5.params.y));
    float period = max((dash + uintBitsToFloat(in_5.params.z)), 0.001);
    float _e31 = floor_div(s_1, period);
    float at = (s_1 - (_e31 * period));
    float _e40 = _group_0_binding_0_fs.scale;
    float dashed = clamp(((min(at, (dash - at)) + 0.5) * _e40), 0.0, 1.0);
    float r_1 = (in_5.border * 0.5);
    float _e55 = _group_0_binding_0_fs.scale;
    float dotted = clamp((0.5 - ((length(vec2((at - r_1), (across - r_1))) - r_1) * _e55)), 0.0, 1.0);
    return ((in_5.params.x == k_dotted) ? dotted : ((in_5.params.x == k_dashed) ? dashed : 1.0));
}

vec4 material(Frag in_6) {
    float width = max(uintBitsToFloat(in_6.params.z), 1.0);
    float band = fract(((in_6.local.x + in_6.local.y) / (2.0 * width)));
    uint _e17 = in_6.params.y;
    return ((band > 0.5) ? (vec4(_e17 & 0xFFu, _e17 >> 8 & 0xFFu, _e17 >> 16 & 0xFFu, _e17 >> 24) / 255.0) : in_6.fill);
}

void main() {
    Frag in_ = Frag(gl_FragCoord, _vs2fs_location0, _vs2fs_location1, _vs2fs_location2, _vs2fs_location3, _vs2fs_location4, _vs2fs_location5, _vs2fs_location6, _vs2fs_location7, _vs2fs_location8, _vs2fs_location9, _vs2fs_location10, _vs2fs_location11, _vs2fs_location12, _vs2fs_location13, _vs2fs_location14);
    float _e4 = corner_radius(in_.local, in_.half_, in_.radii);
    float _e7 = rounded_box(in_.local, in_.half_, _e4);
    float _e10 = _group_0_binding_0_fs.scale;
    float d_1 = (_e7 * _e10);
    float shape = clamp((0.5 - d_1), 0.0, 1.0);
    float _e20 = _group_0_binding_0_fs.scale;
    float inner = clamp((0.5 - (d_1 + (in_.border * _e20))), 0.0, 1.0);
    float has_border = step(0.001, in_.border);
    bool is_shadow = (in_.params.x == k_shadow);
    float _e39 = border_pattern(in_);
    float on_border = ((1.0 - mix(1.0, inner, has_border)) * _e39);
    vec4 _e41 = material(in_);
    vec4 color = (is_shadow ? in_.fill : mix(_e41, in_.border_color, on_border));
    float _e48 = _group_0_binding_0_fs.scale;
    float _e53 = shadow_coverage((d_1 / _e48), uintBitsToFloat(in_.params.y));
    float cover = (is_shadow ? _e53 : shape);
    vec2 inside = (step(in_.clip.xy, in_.pixel) * step(in_.pixel, in_.clip.zw));
    vec2 clip_centre = ((in_.clip.xy + in_.clip.zw) * 0.5);
    vec2 clip_half = ((in_.clip.zw - in_.clip.xy) * 0.5);
    vec2 to_clip = (in_.pixel - clip_centre);
    float _e81 = corner_radius(to_clip, clip_half, in_.clip_radii);
    float _e82 = rounded_box(to_clip, clip_half, _e81);
    float _e85 = _group_0_binding_0_fs.scale;
    float clip_d = (_e82 * _e85);
    float rounded = (any(greaterThan(in_.clip_radii, vec4(0.0))) ? clamp((0.5 - clip_d), 0.0, 1.0) : 1.0);
    float alpha = ((((cover * inside.x) * inside.y) * rounded) * in_.opacity);
    _fs2p_location0 = (vec4((color.xyz * color.w), color.w) * alpha);
    return;
}

