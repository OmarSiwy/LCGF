struct Globals {
    float2 viewport;
    float scale;
    float pad;
};

struct Instance {
    float4 rect : LOC0;
    float4 clip_ : LOC1;
    uint4 params : LOC2;
    float4 uv : LOC3;
    float4 fill : LOC4;
    float4 border_color : LOC5;
    float4 radii : LOC6;
    float border : LOC7;
    float opacity : LOC8;
    float4 xform_abcd : LOC9;
    float2 xform_t : LOC10;
    float4 clip_radii : LOC11;
};

struct Frag {
    float4 position : SV_Position;
    float2 local : LOC0;
    float2 uv : LOC1;
    float2 pixel : LOC2;
    nointerpolation float2 half_ : LOC3;
    nointerpolation float4 radii : LOC4;
    nointerpolation float4 fill : LOC5;
    nointerpolation float4 border_color : LOC6;
    nointerpolation float4 clip_ : LOC7;
    nointerpolation uint4 params : LOC8;
    nointerpolation float4 uv_rect : LOC9;
    nointerpolation float border : LOC10;
    nointerpolation float opacity : LOC11;
    nointerpolation float4 clip_radii : LOC12;
    nointerpolation float4 to_rect : LOC13;
    nointerpolation float2 to_rect_off : LOC14;
};

static const uint k_shadow = 3u;
static const uint k_linear = 1u;
static const uint k_radial = 2u;
static const uint k_nine = 4u;
static const uint k_dashed = 5u;
static const uint k_dotted = 6u;
static const uint k_ramp = 7u;

cbuffer globals : register(b0) { Globals globals; }
Texture2D<float4> tex : register(t0, space1);
SamplerState nagaSamplerHeap[2048]: register(s0, space0);
SamplerComparisonState nagaComparisonSamplerHeap[2048]: register(s0, space1);
StructuredBuffer<uint> nagaGroup1SamplerIndexArray : register(t1, space255);
static const SamplerState samp = nagaSamplerHeap[nagaGroup1SamplerIndexArray[1]];

struct VertexOutput_vs {
    float2 local_2 : LOC0;
    float2 uv : LOC1;
    float2 pixel : LOC2;
    nointerpolation float2 half_2 : LOC3;
    nointerpolation float4 radii_1 : LOC4;
    nointerpolation float4 fill : LOC5;
    nointerpolation float4 border_color : LOC6;
    nointerpolation float4 clip_ : LOC7;
    nointerpolation uint4 params : LOC8;
    nointerpolation float4 uv_rect : LOC9;
    nointerpolation float border : LOC10;
    nointerpolation float opacity : LOC11;
    nointerpolation float4 clip_radii : LOC12;
    nointerpolation float4 to_rect : LOC13;
    nointerpolation float2 to_rect_off : LOC14;
    float4 position : SV_Position;
};

struct FragmentInput_fs {
    float2 local_3 : LOC0;
    float2 uv_1 : LOC1;
    float2 pixel_1 : LOC2;
    nointerpolation float2 half_3 : LOC3;
    nointerpolation float4 radii_2 : LOC4;
    nointerpolation float4 fill_1 : LOC5;
    nointerpolation float4 border_color_1 : LOC6;
    nointerpolation float4 clip_1 : LOC7;
    nointerpolation uint4 params_1 : LOC8;
    nointerpolation float4 uv_rect_1 : LOC9;
    nointerpolation float border_1 : LOC10;
    nointerpolation float opacity_1 : LOC11;
    nointerpolation float4 clip_radii_1 : LOC12;
    nointerpolation float4 to_rect_1 : LOC13;
    nointerpolation float2 to_rect_off_1 : LOC14;
    float4 position_1 : SV_Position;
};

float corner_radius(float2 p, float2 half_, float4 radii)
{
    float right = ((p.y > 0.0) ? radii.z : radii.y);
    float left = ((p.y > 0.0) ? radii.w : radii.x);
    return min(((p.x > 0.0) ? right : left), min(half_.x, half_.y));
}

float rounded_box(float2 p_1, float2 half_1, float r)
{
    float2 q = ((abs(p_1) - half_1) + (r).xx);
    return ((length(max(q, (0.0).xx)) + min(max(q.x, q.y), 0.0)) - r);
}

float2 rect_pos(Frag in_1)
{
    return (((in_1.to_rect.xy * in_1.position.x) + (in_1.to_rect.zw * in_1.position.y)) + in_1.to_rect_off);
}

float floor_div(float num, float den)
{
    float q_1 = floor((num / den));
    return ((q_1 + ((((q_1 + 1.0) * den) <= num) ? 1.0 : 0.0)) - (((q_1 * den) > num) ? 1.0 : 0.0));
}

float texel_centre(float pos, float size, float uv0_, float uv1_, float n)
{
    float s = max(size, 1e-6);
    float a = (uv0_ * n);
    float whole = floor(a);
    const float _e15 = floor_div((((a - whole) * s) + (((uv1_ - uv0_) * n) * pos)), s);
    float k = (whole + _e15);
    return ((clamp(k, 0.0, (n - 1.0)) + 0.5) / n);
}

uint2 NagaDimensions2D(Texture2D<float4> tex)
{
    uint4 ret;
    tex.GetDimensions(0, ret.x, ret.y, ret.z);
    return ret.xy;
}

float2 nearest_uv(Frag in_2)
{
    const float2 _e1 = rect_pos(in_2);
    float2 n_1 = float2(NagaDimensions2D(tex));
    float2 size_2 = (in_2.half_ * 2.0);
    const float _e15 = texel_centre(_e1.x, size_2.x, in_2.uv_rect.x, in_2.uv_rect.z, n_1.x);
    const float _e23 = texel_centre(_e1.y, size_2.y, in_2.uv_rect.y, in_2.uv_rect.w, n_1.y);
    return float2(_e15, _e23);
}

float4 gradient(Frag in_3)
{
    bool local_1 = (bool)0;

    uint _e2 = in_3.params.y;
    float4 to = (float4(_e2 & 0xFF, _e2 >> 8 & 0xFF, _e2 >> 16 & 0xFF, _e2 >> 24) / 255.0);
    float a_1 = asfloat(in_3.params.z);
    float2 dir = float2(cos(a_1), sin(a_1));
    float reach = (abs((in_3.half_.x * dir.x)) + abs((in_3.half_.y * dir.y)));
    float t_lin = (((dot(in_3.local, dir) / max(reach, 1e-6)) * 0.5) + 0.5);
    uint _e31 = in_3.params.z;
    float2 centre = (((float2(f16tof32(_e31), f16tof32((_e31) >> 16)) * 2.0) - (1.0).xx) * in_3.half_);
    float t_rad = (length((in_3.local - centre)) / max(asfloat(in_3.params.w), 1e-6));
    float t = clamp(((in_3.params.x == k_radial) ? t_rad : t_lin), 0.0, 1.0);
    if (!((in_3.params.x == k_linear))) {
        local_1 = (in_3.params.x == k_radial);
    } else {
        local_1 = true;
    }
    bool graded = local_1;
    return (graded ? lerp(in_3.fill, to, t) : in_3.fill);
}

int naga_f2i32(float value) {
    return int(clamp(value, -2147483600.0, 2147483500.0));
}

float4 ramp(Frag in_4)
{
    float a_2 = asfloat(in_4.params.z);
    float2 dir_1 = float2(cos(a_2), sin(a_2));
    float reach_1 = (abs((in_4.half_.x * dir_1.x)) + abs((in_4.half_.y * dir_1.y)));
    float t_lin_1 = (((dot(in_4.local, dir_1) / max(reach_1, 1e-6)) * 0.5) + 0.5);
    uint _e28 = in_4.params.z;
    float2 centre_1 = (((float2(f16tof32(_e28), f16tof32((_e28) >> 16)) * 2.0) - (1.0).xx) * in_4.half_);
    float t_rad_1 = (length((in_4.local - centre_1)) / max(asfloat(in_4.params.w), 1e-6));
    float t_1 = clamp(((in_4.params.y == 1u) ? t_rad_1 : t_lin_1), 0.0, 1.0);
    float2 n_2 = float2(NagaDimensions2D(tex));
    float x = (((in_4.uv_rect.x + ((in_4.uv_rect.z - in_4.uv_rect.x) * t_1)) * n_2.x) - 0.5);
    float i0_ = clamp(floor(x), 0.0, (n_2.x - 1.0));
    float i1_ = min((i0_ + 1.0), (n_2.x - 1.0));
    int row = naga_f2i32(clamp(floor((((in_4.uv_rect.y + in_4.uv_rect.w) * 0.5) * n_2.y)), 0.0, (n_2.y - 1.0)));
    float4 lo_1 = tex.Load(int3(int2(naga_f2i32(i0_), row), int(0)));
    float4 hi_1 = tex.Load(int3(int2(naga_f2i32(i1_), row), int(0)));
    return (in_4.fill * (lo_1 + ((hi_1 - lo_1) * clamp((x - i0_), 0.0, 1.0))));
}

float shadow_coverage(float d, float sigma)
{
    float x_1 = (d / (max(sigma, 0.001) * 1.4142135));
    float x2_ = (x_1 * x_1);
    float e = (sign(x_1) * sqrt((1.0 - exp(((-(x2_) * (1.2732395 + (0.147 * x2_))) / (1.0 + (0.147 * x2_)))))));
    return (0.5 - (0.5 * e));
}

float nine_axis(float pos_1, float size_1, float lo, float hi, float src_lo, float src_hi)
{
    float start = ((pos_1 / max(lo, 1e-6)) * src_lo);
    float end = (1.0 - (((size_1 - pos_1) / max(hi, 1e-6)) * src_hi));
    float mid = (src_lo + (((pos_1 - lo) / max(((size_1 - lo) - hi), 1e-6)) * ((1.0 - src_lo) - src_hi)));
    return ((pos_1 < lo) ? start : ((pos_1 > (size_1 - hi)) ? end : mid));
}

float2 nine_uv(Frag in_5)
{
    uint _e2 = in_5.params.y;
    float4 dst_ = ((float4(_e2 & 0xFF, _e2 >> 8 & 0xFF, _e2 >> 16 & 0xFF, _e2 >> 24) / 255.0) * 255.0);
    uint _e7 = in_5.params.z;
    uint _e10 = in_5.params.w;
    float4 src = float4((float2(_e7 & 0xFFFF, _e7 >> 16) / 65535.0), (float2(_e10 & 0xFFFF, _e10 >> 16) / 65535.0));
    float2 pos_2 = (in_5.local + in_5.half_);
    float2 size_3 = (in_5.half_ * 2.0);
    const float _e25 = nine_axis(pos_2.x, size_3.x, dst_.x, dst_.z, src.x, src.z);
    const float _e32 = nine_axis(pos_2.y, size_3.y, dst_.y, dst_.w, src.y, src.w);
    float2 f = float2(_e25, _e32);
    return lerp(in_5.uv_rect.xy, in_5.uv_rect.zw, f);
}

float border_pattern(Frag in_6)
{
    const float2 _e1 = rect_pos(in_6);
    float2 edge = (in_6.half_ - abs((_e1 - in_6.half_)));
    bool along_y = (edge.x < edge.y);
    float s_1 = (along_y ? _e1.y : _e1.x);
    float across = min(edge.x, edge.y);
    float dash = ((in_6.params.x == k_dotted) ? in_6.border : asfloat(in_6.params.y));
    float period = max((dash + asfloat(in_6.params.z)), 0.001);
    const float _e31 = floor_div(s_1, period);
    float at = (s_1 - (_e31 * period));
    float _e40 = globals.scale;
    float dashed = clamp(((min(at, (dash - at)) + 0.5) * _e40), 0.0, 1.0);
    float r_1 = (in_6.border * 0.5);
    float _e55 = globals.scale;
    float dotted = clamp((0.5 - ((length(float2((at - r_1), (across - r_1))) - r_1) * _e55)), 0.0, 1.0);
    return ((in_6.params.x == k_dotted) ? dotted : ((in_6.params.x == k_dashed) ? dashed : 1.0));
}

float4 material(Frag in_7)
{
    float strength = clamp(asfloat(in_7.params.x), 0.0, 1.0);
    float t_2 = clamp((0.5 - (in_7.local.y / max((2.0 * in_7.half_.y), 1.0))), 0.0, 1.0);
    float edge_1 = ((in_7.local.y < (1.0 - in_7.half_.y)) ? 0.5 : 0.0);
    float lift = (strength * ((t_2 * t_2) + edge_1));
    float3 rgb = lerp(in_7.fill.xyz, (in_7.fill.w).xxx, clamp(lift, 0.0, 1.0));
    return float4(rgb, in_7.fill.w);
}

VertexOutput_vs vs(uint vi : SV_VertexID, Instance inst)
{
    Frag out_ = (Frag)0;

    float2 corner = float2(float((vi & 1u)), float((vi >> 1u)));
    float grow = ((inst.params.x == k_shadow) ? (3.0 * asfloat(inst.params.y)) : 0.0);
    float2 p_2 = lerp((inst.rect.xy - (grow).xx), (inst.rect.zw + (grow).xx), corner);
    float2 screen = (((inst.xform_abcd.xy * p_2.x) + (inst.xform_abcd.zw * p_2.y)) + inst.xform_t);
    float2 _e44 = globals.viewport;
    out_.position = float4((((screen / _e44) * float2(2.0, -2.0)) + float2(-1.0, 1.0)), 0.0, 1.0);
    out_.local = (p_2 - ((inst.rect.xy + inst.rect.zw) * 0.5));
    out_.uv = lerp(inst.uv.xy, inst.uv.zw, ((p_2 - inst.rect.xy) / max((inst.rect.zw - inst.rect.xy), (1e-6).xx)));
    out_.pixel = screen;
    out_.half_ = ((inst.rect.zw - inst.rect.xy) * 0.5);
    out_.radii = inst.radii;
    out_.border = inst.border;
    out_.opacity = inst.opacity;
    out_.clip_radii = inst.clip_radii;
    out_.fill = inst.fill;
    out_.border_color = inst.border_color;
    out_.clip_ = inst.clip_;
    out_.params = inst.params;
    out_.uv_rect = inst.uv;
    float4 a_3 = inst.xform_abcd;
    float _e121 = globals.scale;
    float k_1 = (1.0 / (((a_3.x * a_3.w) - (a_3.y * a_3.z)) * _e121));
    out_.to_rect = float4((a_3.w * k_1), (-(a_3.y) * k_1), (-(a_3.z) * k_1), (a_3.x * k_1));
    float4 _e139 = out_.to_rect;
    float _e145 = globals.scale;
    float4 _e149 = out_.to_rect;
    float _e155 = globals.scale;
    out_.to_rect_off = (-(((_e139.xy * (inst.xform_t.x * _e145)) + (_e149.zw * (inst.xform_t.y * _e155)))) - inst.rect.xy);
    Frag _e163 = out_;
    const Frag frag = _e163;
    const VertexOutput_vs frag_1 = { frag.local, frag.uv, frag.pixel, frag.half_, frag.radii, frag.fill, frag.border_color, frag.clip_, frag.params, frag.uv_rect, frag.border, frag.opacity, frag.clip_radii, frag.to_rect, frag.to_rect_off, frag.position };
    return frag_1;
}

float4 fs(FragmentInput_fs fragmentinput_fs) : SV_Target0
{
    Frag in_ = { fragmentinput_fs.position_1, fragmentinput_fs.local_3, fragmentinput_fs.uv_1, fragmentinput_fs.pixel_1, fragmentinput_fs.half_3, fragmentinput_fs.radii_2, fragmentinput_fs.fill_1, fragmentinput_fs.border_color_1, fragmentinput_fs.clip_1, fragmentinput_fs.params_1, fragmentinput_fs.uv_rect_1, fragmentinput_fs.border_1, fragmentinput_fs.opacity_1, fragmentinput_fs.clip_radii_1, fragmentinput_fs.to_rect_1, fragmentinput_fs.to_rect_off_1 };
    float pattern = 1.0;
    bool local = (bool)0;
    float cover = (float)0;
    float rounded = 1.0;

    const float _e4 = corner_radius(in_.local, in_.half_, in_.radii);
    const float _e7 = rounded_box(in_.local, in_.half_, _e4);
    float _e10 = globals.scale;
    float d_1 = (_e7 * _e10);
    float shape = clamp((0.5 - d_1), 0.0, 1.0);
    float _e20 = globals.scale;
    float inner = clamp((0.5 - (d_1 + (in_.border * _e20))), 0.0, 1.0);
    float has_border = step(0.001, in_.border);
    bool is_shadow = (in_.params.x == k_shadow);
    if (!((in_.params.x == k_dashed))) {
        local = (in_.params.x == k_dotted);
    } else {
        local = true;
    }
    bool _e49 = local;
    if (_e49) {
        const float _e50 = border_pattern(in_);
        pattern = _e50;
    }
    float _e55 = pattern;
    float on_border = ((1.0 - lerp(1.0, inner, has_border)) * _e55);
    const float4 _e57 = material(in_);
    float4 color = (is_shadow ? in_.fill : lerp(_e57, in_.border_color, on_border));
    cover = shape;
    if (is_shadow) {
        float _e65 = globals.scale;
        const float _e70 = shadow_coverage((d_1 / _e65), asfloat(in_.params.y));
        cover = _e70;
    }
    float2 inside = (step(in_.clip_.xy, in_.pixel) * step(in_.pixel, in_.clip_.zw));
    if (any((in_.clip_radii > (0.0).xxxx))) {
        float2 clip_centre = ((in_.clip_.xy + in_.clip_.zw) * 0.5);
        float2 clip_half = ((in_.clip_.zw - in_.clip_.xy) * 0.5);
        float2 to_clip = (in_.pixel - clip_centre);
        const float _e104 = corner_radius(to_clip, clip_half, in_.clip_radii);
        const float _e105 = rounded_box(to_clip, clip_half, _e104);
        float _e108 = globals.scale;
        float clip_d = (_e105 * _e108);
        rounded = clamp((0.5 - clip_d), 0.0, 1.0);
    }
    float _e115 = cover;
    float _e120 = rounded;
    float alpha = ((((_e115 * inside.x) * inside.y) * _e120) * in_.opacity);
    return (float4((color.xyz * color.w), color.w) * alpha);
}
