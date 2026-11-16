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
};
const uint k_shadow = 3u;
const uint k_linear = 1u;
const uint k_radial = 2u;
const uint k_nine = 4u;
const uint k_dashed = 5u;
const uint k_dotted = 6u;

layout(std140) uniform Globals_block_0Vertex { Globals _group_0_binding_0_vs; };

layout(location = 0) in vec4 _p2vs_location0;
layout(location = 1) in vec4 _p2vs_location1;
layout(location = 2) in uvec4 _p2vs_location2;
layout(location = 3) in vec4 _p2vs_location3;
layout(location = 4) in vec4 _p2vs_location4;
layout(location = 5) in vec4 _p2vs_location5;
layout(location = 6) in vec4 _p2vs_location6;
layout(location = 7) in float _p2vs_location7;
layout(location = 8) in float _p2vs_location8;
layout(location = 9) in vec4 _p2vs_location9;
layout(location = 10) in vec2 _p2vs_location10;
layout(location = 11) in vec4 _p2vs_location11;
smooth out vec2 _vs2fs_location0;
smooth out vec2 _vs2fs_location1;
smooth out vec2 _vs2fs_location2;
flat out vec2 _vs2fs_location3;
flat out vec4 _vs2fs_location4;
flat out vec4 _vs2fs_location5;
flat out vec4 _vs2fs_location6;
flat out vec4 _vs2fs_location7;
flat out uvec4 _vs2fs_location8;
flat out vec4 _vs2fs_location9;
flat out float _vs2fs_location10;
flat out float _vs2fs_location11;
flat out vec4 _vs2fs_location12;

float corner_radius(vec2 p, vec2 half_, vec4 radii) {
    float right = ((p.y > 0.0) ? radii.z : radii.y);
    float left = ((p.y > 0.0) ? radii.w : radii.x);
    return min(((p.x > 0.0) ? right : left), min(half_.x, half_.y));
}

float rounded_box(vec2 p_1, vec2 half_1, float r) {
    vec2 q = ((abs(p_1) - half_1) + vec2(r));
    return ((length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0)) - r);
}

vec4 gradient(Frag in_1) {
    bool local = false;
    uint _e2 = in_1.params.y;
    vec4 to = (vec4(_e2 & 0xFFu, _e2 >> 8 & 0xFFu, _e2 >> 16 & 0xFFu, _e2 >> 24) / 255.0);
    float a = uintBitsToFloat(in_1.params.z);
    vec2 dir = vec2(cos(a), sin(a));
    float reach = (abs((in_1.half_.x * dir.x)) + abs((in_1.half_.y * dir.y)));
    float t_lin = (((dot(in_1.local, dir) / max(reach, 1e-6)) * 0.5) + 0.5);
    vec2 centre = (((unpackHalf2x16(in_1.params.z) * 2.0) - vec2(1.0)) * in_1.half_);
    float t_rad = (length((in_1.local - centre)) / max(uintBitsToFloat(in_1.params.w), 1e-6));
    float t = clamp(((in_1.params.x == k_radial) ? t_rad : t_lin), 0.0, 1.0);
    if (!((in_1.params.x == k_linear))) {
        local = (in_1.params.x == k_radial);
    } else {
        local = true;
    }
    bool graded = local;
    return (graded ? mix(in_1.fill, to, t) : in_1.fill);
}

float shadow_coverage(float d, float sigma) {
    float x = (d / (max(sigma, 0.001) * 1.4142135));
    float x2_ = (x * x);
    float e = (sign(x) * sqrt((1.0 - exp(((-(x2_) * (1.2732395 + (0.147 * x2_))) / (1.0 + (0.147 * x2_)))))));
    return (0.5 - (0.5 * e));
}

float nine_axis(float pos, float size, float lo, float hi, float src_lo, float src_hi) {
    float start = ((pos / max(lo, 1e-6)) * src_lo);
    float end = (1.0 - (((size - pos) / max(hi, 1e-6)) * src_hi));
    float mid = (src_lo + (((pos - lo) / max(((size - lo) - hi), 1e-6)) * ((1.0 - src_lo) - src_hi)));
    return ((pos < lo) ? start : ((pos > (size - hi)) ? end : mid));
}

vec2 nine_uv(Frag in_2) {
    uint _e2 = in_2.params.y;
    vec4 dst = ((vec4(_e2 & 0xFFu, _e2 >> 8 & 0xFFu, _e2 >> 16 & 0xFFu, _e2 >> 24) / 255.0) * 255.0);
    vec4 src = vec4(unpackUnorm2x16(in_2.params.z), unpackUnorm2x16(in_2.params.w));
    vec2 pos_1 = (in_2.local + in_2.half_);
    vec2 size_1 = (in_2.half_ * 2.0);
    float _e25 = nine_axis(pos_1.x, size_1.x, dst.x, dst.z, src.x, src.z);
    float _e32 = nine_axis(pos_1.y, size_1.y, dst.y, dst.w, src.y, src.w);
    vec2 f = vec2(_e25, _e32);
    return mix(in_2.uv_rect.xy, in_2.uv_rect.zw, f);
}

float border_pattern(Frag in_3) {
    vec2 edge = (in_3.half_ - abs(in_3.local));
    bool along_y = (edge.x < edge.y);
    float s = (along_y ? (in_3.local.y + in_3.half_.y) : (in_3.local.x + in_3.half_.x));
    float across = min(edge.x, edge.y);
    float dash = ((in_3.params.x == k_dotted) ? in_3.border : uintBitsToFloat(in_3.params.y));
    float period = max((dash + uintBitsToFloat(in_3.params.z)), 0.001);
    float at = (s - (floor((s / period)) * period));
    float _e47 = _group_0_binding_0_vs.scale;
    float dashed = clamp(((min(at, (dash - at)) + 0.5) * _e47), 0.0, 1.0);
    float r_1 = (in_3.border * 0.5);
    float _e62 = _group_0_binding_0_vs.scale;
    float dotted = clamp((0.5 - ((length(vec2((at - r_1), (across - r_1))) - r_1) * _e62)), 0.0, 1.0);
    return ((in_3.params.x == k_dotted) ? dotted : ((in_3.params.x == k_dashed) ? dashed : 1.0));
}

void main() {
    uint vi = uint(gl_VertexID);
    Instance inst = Instance(_p2vs_location0, _p2vs_location1, _p2vs_location2, _p2vs_location3, _p2vs_location4, _p2vs_location5, _p2vs_location6, _p2vs_location7, _p2vs_location8, _p2vs_location9, _p2vs_location10, _p2vs_location11);
    Frag out_ = Frag(vec4(0.0), vec2(0.0), vec2(0.0), vec2(0.0), vec2(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), uvec4(0u), vec4(0.0), 0.0, 0.0, vec4(0.0));
    vec2 corner = vec2(float((vi & 1u)), float((vi >> 1u)));
    float grow = ((inst.params.x == k_shadow) ? (3.0 * uintBitsToFloat(inst.params.y)) : 0.0);
    vec2 p_2 = mix((inst.rect.xy - vec2(grow)), (inst.rect.zw + vec2(grow)), corner);
    vec2 screen = (((inst.xform_abcd.xy * p_2.x) + (inst.xform_abcd.zw * p_2.y)) + inst.xform_t);
    vec2 _e44 = _group_0_binding_0_vs.viewport;
    out_.position = vec4((((screen / _e44) * vec2(2.0, -2.0)) + vec2(-1.0, 1.0)), 0.0, 1.0);
    out_.local = (p_2 - ((inst.rect.xy + inst.rect.zw) * 0.5));
    out_.uv = mix(inst.uv.xy, inst.uv.zw, ((p_2 - inst.rect.xy) / max((inst.rect.zw - inst.rect.xy), vec2(1e-6))));
    out_.pixel = screen;
    out_.half_ = ((inst.rect.zw - inst.rect.xy) * 0.5);
    out_.radii = inst.radii;
    out_.border = inst.border;
    out_.opacity = inst.opacity;
    out_.clip_radii = inst.clip_radii;
    out_.fill = inst.fill;
    out_.border_color = inst.border_color;
    out_.clip = inst.clip;
    out_.params = inst.params;
    out_.uv_rect = inst.uv;
    Frag _e111 = out_;
    gl_Position = _e111.position;
    _vs2fs_location0 = _e111.local;
    _vs2fs_location1 = _e111.uv;
    _vs2fs_location2 = _e111.pixel;
    _vs2fs_location3 = _e111.half_;
    _vs2fs_location4 = _e111.radii;
    _vs2fs_location5 = _e111.fill;
    _vs2fs_location6 = _e111.border_color;
    _vs2fs_location7 = _e111.clip;
    _vs2fs_location8 = _e111.params;
    _vs2fs_location9 = _e111.uv_rect;
    _vs2fs_location10 = _e111.border;
    _vs2fs_location11 = _e111.opacity;
    _vs2fs_location12 = _e111.clip_radii;
    gl_Position.yz = vec2(-gl_Position.y, gl_Position.z * 2.0 - gl_Position.w);
    return;
}

