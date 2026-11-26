struct Draw {
    int2 origin;
    float2 base;
    float scale;
    float line_;
    float px;
    uint zoom_scale;
    float4 rect;
    float4 clip_;
    float2 size;
    float opacity;
    uint row_base;
    uint vert_base;
    uint vert_len;
    uint overrides;
    uint layers;
    float4 inv;
    float2 inv_t;
    float2 fwd_t;
    float4 fwd;
    float4 radii;
    float4 clip_box;
    float px_scale;
    float inv_scale;
    uint rounded;
    int _pad24_0;
    uint4 palette[256];
    uint4 marks[64];
};

struct Row {
    int4 pos : LOC0;
    uint4 look : LOC1;
    uint row : LOC2;
};

struct Frag {
    float4 position : SV_Position;
    nointerpolation float4 p : LOC0;
    nointerpolation float4 m0_ : LOC1;
    nointerpolation float4 m1_ : LOC2;
    nointerpolation float4 m2_ : LOC3;
    nointerpolation float4 m3_ : LOC4;
    nointerpolation float4 stroke : LOC5;
    nointerpolation float4 base : LOC6;
    nointerpolation uint4 k : LOC7;
    nointerpolation float2 uv : LOC8;
};

cbuffer u : register(b0) { Draw u; }
Texture2D<float4> atlas : register(t0, space1);
ByteAddressBuffer verts : register(t1);

struct VertexOutput_vs {
    nointerpolation float4 p_4 : LOC0;
    nointerpolation float4 m0_ : LOC1;
    nointerpolation float4 m1_1 : LOC2;
    nointerpolation float4 m2_1 : LOC3;
    nointerpolation float4 m3_1 : LOC4;
    nointerpolation float4 stroke : LOC5;
    nointerpolation float4 base : LOC6;
    nointerpolation uint4 k : LOC7;
    nointerpolation float2 uv : LOC8;
    float4 position : SV_Position;
};

struct FragmentInput_fs {
    nointerpolation float4 p_5 : LOC0;
    nointerpolation float4 m0_1 : LOC1;
    nointerpolation float4 m1_2 : LOC2;
    nointerpolation float4 m2_2 : LOC3;
    nointerpolation float4 m3_2 : LOC4;
    nointerpolation float4 stroke_1 : LOC5;
    nointerpolation float4 base_1 : LOC6;
    nointerpolation uint4 k_1 : LOC7;
    nointerpolation float2 uv_1 : LOC8;
    float4 position_1 : SV_Position;
};

float wx(int w)
{
    float _e4 = u.base.x;
    int _e8 = u.origin.x;
    float _e13 = u.scale;
    return (_e4 + (float(asint(asuint(w) - asuint(_e8))) * _e13));
}

float wy(int w_1)
{
    float _e4 = u.base.y;
    int _e8 = u.origin.y;
    float _e13 = u.scale;
    return (_e4 + (float(asint(asuint(w_1) - asuint(_e8))) * _e13));
}

float4 rgba(uint c)
{
    return (float4(float((c & 255u)), float(((c >> 8u) & 255u)), float(((c >> 16u) & 255u)), float((c >> 24u))) / (255.0).xxxx);
}

float unorm16_(uint v)
{
    return (float((v & 65535u)) / 65535.0);
}

uint override_of(uint i, uint colour_1)
{
    uint found = (uint)0;
    uint j = 0u;

    found = colour_1;
    uint2 loop_bound = uint2(4294967295u, 4294967295u);
    bool loop_init = true;
    while(true) {
        if (all(loop_bound == uint2(0u, 0u))) { break; }
        loop_bound -= uint2(loop_bound.y == 0u, 1u);
        if (!loop_init) {
            uint _e25 = j;
            j = (_e25 + 1u);
        }
        loop_init = false;
        uint _e5 = j;
        uint _e8 = u.overrides;
        if ((_e5 < min(_e8, 64u))) {
        } else {
            break;
        }
        {
            uint _e14 = j;
            uint4 o = u.marks[_e14];
            uint _e17 = found;
            found = (((i - o.x) < o.y) ? o.z : _e17);
        }
    }
    uint _e27 = found;
    return _e27;
}

float2 screen(float2 p_1)
{
    float _e4 = u.fwd.x;
    float _e10 = u.fwd.z;
    float _e17 = u.fwd_t.x;
    float _e22 = u.fwd.y;
    float _e28 = u.fwd.w;
    float _e35 = u.fwd_t.y;
    return float2((((_e4 * p_1.x) + (_e10 * p_1.y)) + _e17), (((_e22 * p_1.x) + (_e28 * p_1.y)) + _e35));
}

float corner_radius(float2 p_2, float2 half_, float4 radii)
{
    float right = ((p_2.y > 0.0) ? radii.z : radii.y);
    float left = ((p_2.y > 0.0) ? radii.w : radii.x);
    return min(((p_2.x > 0.0) ? right : left), min(half_.x, half_.y));
}

float len2_(float x, float y)
{
    return sqrt(((x * x) + (y * y)));
}

float rounded_box(float2 p_3, float2 half_1, float r_1)
{
    float2 q = ((abs(p_3) - half_1) + (r_1).xx);
    const float _e13 = len2_(max(q.x, 0.0), max(q.y, 0.0));
    return ((_e13 + min(max(q.x, q.y), 0.0)) - r_1);
}

float dash_cover(float at, float on, float period)
{
    if ((period == 0.0)) {
        return 1.0;
    }
    float m = (at - (floor((at / period)) * period));
    return min(max((min(m, (on - m)) + 0.5), 0.0), 1.0);
}

float box_dist(float qx, float qy)
{
    const float _e6 = len2_(max(qx, 0.0), max(qy, 0.0));
    return (_e6 + min(max(qx, qy), 0.0));
}

float coverage(float d_1)
{
    return min(max((0.5 - d_1), 0.0), 1.0);
}

float rect_dist(float px, float py, Frag in_1)
{
    float hx = (abs((in_1.p.z - in_1.p.x)) * 0.5);
    float hy = (abs((in_1.p.w - in_1.p.y)) * 0.5);
    float r_2 = min(in_1.m0_.y, min(hx, hy));
    float qx_1 = ((abs((px - ((in_1.p.x + in_1.p.z) * 0.5))) - hx) + r_2);
    float qy_1 = ((abs((py - ((in_1.p.y + in_1.p.w) * 0.5))) - hy) + r_2);
    const float _e45 = box_dist(qx_1, qy_1);
    return (_e45 - r_2);
}

int2 vert(uint i_1)
{
    int2 _e3 = asint(verts.Load2(i_1*8));
    return _e3;
}

float polygon_dist(float px_1, float py_1, uint first, uint count)
{
    float best = 3e38;
    int winding = int(0);
    float ax = (float)0;
    float ay = (float)0;
    uint j_1 = 0u;
    bool local_16 = (bool)0;
    bool local_17 = (bool)0;
    bool local_18 = (bool)0;
    bool local_19 = (bool)0;

    uint _e6 = u.vert_len;
    uint f = min(first, _e6);
    uint _e10 = u.vert_len;
    uint n = min(count, (_e10 - f));
    if ((n == 0u)) {
        return 3e38;
    }
    uint _e22 = u.vert_base;
    const int2 _e27 = vert((((_e22 + f) + n) - 1u));
    const float _e29 = wx(_e27.x);
    ax = _e29;
    const float _e32 = wy(_e27.y);
    ay = _e32;
    uint2 loop_bound_1 = uint2(4294967295u, 4294967295u);
    bool loop_init_1 = true;
    while(true) {
        if (all(loop_bound_1 == uint2(0u, 0u))) { break; }
        loop_bound_1 -= uint2(loop_bound_1.y == 0u, 1u);
        if (!loop_init_1) {
            uint _e116 = j_1;
            j_1 = (_e116 + 1u);
        }
        loop_init_1 = false;
        uint _e36 = j_1;
        if ((_e36 < n)) {
        } else {
            break;
        }
        {
            uint _e40 = u.vert_base;
            uint _e42 = j_1;
            const int2 _e44 = vert(((_e40 + f) + _e42));
            const float _e46 = wx(_e44.x);
            const float _e48 = wy(_e44.y);
            float _e49 = ax;
            float ex = (_e46 - _e49);
            float _e51 = ay;
            float ey = (_e48 - _e51);
            float _e53 = ax;
            float ox = (px_1 - _e53);
            float _e55 = ay;
            float oy = (py_1 - _e55);
            float t = min(max((((ox * ex) + (oy * ey)) * (1.0 / max(((ex * ex) + (ey * ey)), 1e-12))), 0.0), 1.0);
            float dx = (ox - (ex * t));
            float dy = (oy - (ey * t));
            float _e76 = best;
            best = min(_e76, ((dx * dx) + (dy * dy)));
            float left_1 = ((ex * oy) - (ey * ox));
            float _e84 = ay;
            if ((_e84 <= py_1)) {
                local_16 = (_e48 > py_1);
            } else {
                local_16 = false;
            }
            bool _e90 = local_16;
            if (_e90) {
                local_17 = (left_1 > 0.0);
            } else {
                local_17 = false;
            }
            bool up = local_17;
            float _e97 = ay;
            if ((_e97 > py_1)) {
                local_18 = (_e48 <= py_1);
            } else {
                local_18 = false;
            }
            bool _e103 = local_18;
            if (_e103) {
                local_19 = (left_1 < 0.0);
            } else {
                local_19 = false;
            }
            bool down = local_19;
            int _e110 = winding;
            winding = asint(asuint(_e110) + asuint(asint(asuint(int(up)) - asuint(int(down)))));
            ax = _e46;
            ay = _e48;
        }
    }
    float _e118 = best;
    float d_2 = sqrt(_e118);
    int _e121 = winding;
    return ((_e121 != int(0)) ? -(d_2) : d_2);
}

typedef float ret_Constructarray4_float_[4];
ret_Constructarray4_float_ Constructarray4_float_(float arg0, float arg1, float arg2, float arg3) {
    float ret[4] = { arg0, arg1, arg2, arg3 };
    return ret;
}

VertexOutput_vs vs(uint vi : SV_VertexID, Row r)
{
    Frag out_ = (Frag)0;
    bool local = (bool)0;
    bool local_1 = (bool)0;
    bool local_2 = (bool)0;
    bool local_3 = (bool)0;
    float4 p = (float4)0;
    float radius = (float)0;
    float grow = (float)0;
    float4 m1_ = float4(0.0, 0.0, 1.0, 0.0);
    float4 m2_ = float4(0.0, 1.0, 0.0, 0.0);
    float4 m3_ = (0.0).xxxx;
    float chain = 0.0;
    float4 box = (0.0).xxxx;
    bool local_4 = (bool)0;

    uint h = r.look.x;
    uint layer = (h >> 24u);
    uint4 row = u.palette[min(layer, 255u)];
    out_.position = float4(-2.0, -2.0, 0.0, 1.0);
    if (!(((h & 512u) != 0u))) {
        uint _e28 = u.layers;
        local = (layer >= _e28);
    } else {
        local = true;
    }
    bool _e31 = local;
    if (!(_e31)) {
        local_1 = ((row.w & 2u) == 0u);
    } else {
        local_1 = true;
    }
    bool _e41 = local_1;
    if (_e41) {
        Frag _e42 = out_;
        const Frag frag = _e42;
        const VertexOutput_vs frag_1 = { frag.p, frag.m0_, frag.m1_, frag.m2_, frag.m3_, frag.stroke, frag.base, frag.k, frag.uv, frag.position };
        return frag_1;
    }
    uint kind = (h & 15u);
    uint cap = ((h >> 4u) & 3u);
    float weight = float((((h >> 14u) & 3u) + 1u));
    float _e61 = u.line_;
    float _e68 = u.scale;
    float width = (((h & 256u) != 0u) ? (float(r.look.w) * _e68) : ((weight * asfloat(row.z)) * _e61));
    const float _e77 = wx(r.pos.x);
    const float _e80 = wy(r.pos.y);
    const float _e83 = wx(r.pos.z);
    const float _e86 = wy(r.pos.w);
    float4 corner = float4(_e77, _e80, _e83, _e86);
    float dash = float(((h >> 10u) & 15u));
    float half_2 = (width * 0.5);
    if (!(((h & 128u) != 0u))) {
        local_2 = (kind == 0u);
    } else {
        local_2 = true;
    }
    bool _e105 = local_2;
    if (!(_e105)) {
        local_3 = (kind == 2u);
    } else {
        local_3 = true;
    }
    bool stroked = local_3;
    p = corner;
    float _e119 = u.scale;
    radius = (float(r.look.y) * _e119);
    grow = (half_2 * float(stroked));
    if ((kind == 0u)) {
        grow = (half_2 * 1.4142135);
        float _e154 = u.scale;
        chain = (float(r.look.y) * _e154);
        float _e160 = u.px;
        float on_1 = ((2.0 * dash) * _e160);
        m1_ = float4(on_1, (2.0 * on_1), 1.0, 0.0);
        float dx_1 = (corner.z - corner.x);
        float dy_1 = (corner.w - corner.y);
        float l = sqrt(((dx_1 * dx_1) + (dy_1 * dy_1)));
        float kk = (1.0 / max(l, 1e-6));
        m3_ = float4(((l > 1e-6) ? (dx_1 * kk) : 1.0), (dy_1 * kk), (l * 0.5), 0.0);
    }
    if ((kind == 2u)) {
        float _e199 = u.scale;
        float rr = (float(asuint(r.pos.z)) * _e199);
        float start = float((r.look.z & 65535u));
        float sweep = ((float((r.look.z >> 16u)) / 65535.0) * 6.2831855);
        float m_1 = (((start / 65536.0) * 6.2831855) + (sweep / 2.0));
        radius = rr;
        float _e227 = u.scale;
        chain = (float(r.look.y) * _e227);
        float _e233 = u.px;
        float on_2 = ((2.0 * dash) * _e233);
        m1_ = float4(on_2, (2.0 * on_2), cos(m_1), sin(m_1));
        m3_ = float4((sweep / 2.0), 0.0, 0.0, 0.0);
        m2_ = float4(max(sin((sweep / 2.0)), 0.0), cos((sweep / 2.0)), float(((r.look.z >> 16u) == 65535u)), 0.0);
        p = float4(corner.x, corner.y, 0.0, 0.0);
        float e = (rr + half_2);
        box = float4(((corner.x - e) - 1.0), ((corner.y - e) - 1.0), ((corner.x + e) + 1.0), ((corner.y + e) + 1.0));
    } else {
        if ((kind == 4u)) {
            float _e294 = u.scale;
            float gw = (float(asuint(r.pos.z)) * _e294);
            float _e302 = u.scale;
            float gh = (float(asuint(r.pos.w)) * _e302);
            uint q_1 = ((h >> 16u) & 3u);
            float c_1[4] = Constructarray4_float_(1.0, 0.0, -1.0, 0.0);
            m1_ = float4(0.0, 0.0, c_1[min(uint(q_1), 3u)], c_1[min(uint(((q_1 + 3u) & 3u)), 3u)]);
            p = float4(corner.x, corner.y, gw, gh);
            float e_1 = max(gw, gh);
            box = float4(((corner.x - e_1) - 1.0), ((corner.y - e_1) - 1.0), ((corner.x + e_1) + 1.0), ((corner.y + e_1) + 1.0));
            const float _e345 = unorm16_(r.look.y);
            const float _e350 = unorm16_((r.look.y >> 16u));
            out_.uv = float2(_e345, _e350);
            const float _e355 = unorm16_(r.look.z);
            const float _e364 = unorm16_((r.look.z >> 16u));
            m3_ = float4(((_e355 - _e345) / max(gw, 1e-6)), ((_e364 - _e350) / max(gh, 1e-6)), 0.0, 0.0);
        } else {
            float _e375 = grow;
            float _e382 = grow;
            float _e389 = grow;
            float _e396 = grow;
            box = float4(((min(corner.x, corner.z) - _e375) - 1.0), ((min(corner.y, corner.w) - _e382) - 1.0), ((max(corner.x, corner.z) + _e389) + 1.0), ((max(corner.y, corner.w) + _e396) + 1.0));
        }
    }
    uint _e404 = u.row_base;
    const uint _e407 = override_of((r.row - _e404), row.x);
    uint _e411 = u.row_base;
    const uint _e414 = override_of((r.row - _e411), row.y);
    if (((h & 64u) != 0u)) {
        local_4 = ((row.w & 1u) != 0u);
    } else {
        local_4 = false;
    }
    bool filled = local_4;
    const float4 _e429 = rgba(_e407);
    out_.stroke = _e429;
    float4 _e432 = out_.stroke;
    const float4 _e436 = rgba(_e414);
    out_.base = (filled ? _e436 : float4(_e432.xyz, 0.0));
    float4 _e439 = p;
    out_.p = _e439;
    float _e441 = radius;
    float _e445 = chain;
    out_.m0_ = float4(half_2, _e441, float((cap == 1u)), _e445);
    float4 _e448 = m1_;
    out_.m1_ = _e448;
    float _e451 = m2_.x;
    float _e453 = m2_.y;
    float _e456 = m2_.z;
    out_.m2_ = float4(_e451, _e453, ((kind == 2u) ? _e456 : float(stroked)), (half_2 * float(stroked)));
    float4 _e464 = m3_;
    out_.m3_ = _e464;
    out_.k = uint4(kind, uint((cap == 2u)), r.look.y, r.look.z);
    float4 _e474 = box;
    const float2 _e476 = screen(_e474.xy);
    float4 _e477 = box;
    const float2 _e479 = screen(_e477.zy);
    float4 _e480 = box;
    const float2 _e482 = screen(_e480.xw);
    float4 _e483 = box;
    const float2 _e485 = screen(_e483.zw);
    float2 lo = clamp(floor(min(min(_e476, _e479), min(_e482, _e485))), (0.0).xx, (16777216.0).xx);
    float2 hi = clamp(ceil(max(max(_e476, _e479), max(_e482, _e485))), (0.0).xx, (16777216.0).xx);
    float2 at_1 = (bool2(((vi & 1u) != 0u), ((vi & 2u) != 0u)) ? hi : lo);
    float2 _e517 = u.size;
    out_.position = float4((((at_1 / _e517) * float2(2.0, -2.0)) + float2(-1.0, 1.0)), 0.0, 1.0);
    Frag _e530 = out_;
    const Frag frag_2 = _e530;
    const VertexOutput_vs frag_2_ = { frag_2.p, frag_2.m0_, frag_2.m1_, frag_2.m2_, frag_2.m3_, frag_2.stroke, frag_2.base, frag_2.k, frag_2.uv, frag_2.position };
    return frag_2_;
}

uint naga_f2u32(float value) {
    return uint(clamp(value, 0.0, 4294967000.0));
}

uint2 NagaDimensions2D(Texture2D<float4> tex)
{
    uint4 ret;
    tex.GetDimensions(0, ret.x, ret.y, ret.z);
    return ret.xy;
}

float4 fs(FragmentInput_fs fragmentinput_fs) : SV_Target0
{
    Frag in_ = { fragmentinput_fs.position_1, fragmentinput_fs.p_5, fragmentinput_fs.m0_1, fragmentinput_fs.m1_2, fragmentinput_fs.m2_2, fragmentinput_fs.m3_2, fragmentinput_fs.stroke_1, fragmentinput_fs.base_1, fragmentinput_fs.k_1, fragmentinput_fs.uv_1 };
    bool local_5 = (bool)0;
    bool local_6 = (bool)0;
    bool local_7 = (bool)0;
    bool local_8 = (bool)0;
    bool local_9 = (bool)0;
    bool local_10 = (bool)0;
    bool local_11 = (bool)0;
    float keep = (float)0;
    float4 colour = (float4)0;
    float alpha = 0.0;
    bool local_12 = (bool)0;
    float d = 0.0;
    bool local_13 = (bool)0;
    bool local_14 = (bool)0;
    bool local_15 = (bool)0;

    float sx = in_.position.x;
    float sy = in_.position.y;
    float _e8 = u.inv.x;
    float _e13 = u.inv.z;
    float _e19 = u.inv_t.x;
    float px_2 = (((_e8 * sx) + (_e13 * sy)) + _e19);
    float _e24 = u.inv.y;
    float _e29 = u.inv.w;
    float _e35 = u.inv_t.y;
    float py_2 = (((_e24 * sx) + (_e29 * sy)) + _e35);
    float _e40 = u.rect.x;
    if ((px_2 >= _e40)) {
        float _e47 = u.rect.z;
        local_5 = (px_2 < _e47);
    } else {
        local_5 = false;
    }
    bool _e50 = local_5;
    if (_e50) {
        float _e56 = u.rect.y;
        local_6 = (py_2 >= _e56);
    } else {
        local_6 = false;
    }
    bool _e59 = local_6;
    if (_e59) {
        float _e65 = u.rect.w;
        local_7 = (py_2 < _e65);
    } else {
        local_7 = false;
    }
    bool _e68 = local_7;
    if (_e68) {
        float _e74 = u.clip_.x;
        local_8 = (sx >= _e74);
    } else {
        local_8 = false;
    }
    bool _e77 = local_8;
    if (_e77) {
        float _e83 = u.clip_.z;
        local_9 = (sx <= _e83);
    } else {
        local_9 = false;
    }
    bool _e86 = local_9;
    if (_e86) {
        float _e92 = u.clip_.y;
        local_10 = (sy >= _e92);
    } else {
        local_10 = false;
    }
    bool _e95 = local_10;
    if (_e95) {
        float _e101 = u.clip_.w;
        local_11 = (sy <= _e101);
    } else {
        local_11 = false;
    }
    bool inside = local_11;
    keep = float(inside);
    uint _e109 = u.rounded;
    if ((_e109 != 0u)) {
        float _e114 = u.inv_scale;
        float _e119 = u.clip_box.x;
        float _e123 = u.inv_scale;
        float _e128 = u.clip_box.y;
        float2 l_1 = float2(((sx * _e114) - _e119), ((sy * _e123) - _e128));
        float4 _e133 = u.clip_box;
        float4 _e137 = u.clip_box;
        float4 _e141 = u.radii;
        const float _e142 = corner_radius(l_1, _e137.zw, _e141);
        const float _e143 = rounded_box(l_1, _e133.zw, _e142);
        float _e146 = u.px_scale;
        float corner_1 = (_e143 * _e146);
        float _e148 = keep;
        keep = (_e148 * min(max((0.5 - corner_1), 0.0), 1.0));
    }
    float half_3 = in_.m0_.x;
    float square = in_.m0_.z;
    float hw = in_.m2_.w;
    colour = in_.stroke;
    uint kind_1 = in_.k.x;
    bool round_ = (in_.k.y != 0u);
    if ((kind_1 == 0u)) {
        float ux = in_.m3_.x;
        float uy = in_.m3_.y;
        float h_1 = in_.m3_.z;
        float ox_1 = (px_2 - in_.p.x);
        float oy_1 = (py_2 - in_.p.y);
        float t_1 = ((ox_1 * ux) + (oy_1 * uy));
        float along = abs((t_1 - h_1));
        float across = abs(((oy_1 * ux) - (ox_1 * uy)));
        const float _e198 = len2_(max((along - h_1), 0.0), across);
        float capsule = (_e198 - half_3);
        const float _e204 = box_dist(((along - h_1) - (half_3 * square)), (across - half_3));
        float d_3 = (round_ ? capsule : _e204);
        const float _e206 = coverage(d_3);
        const float _e214 = dash_cover((t_1 + in_.m0_.w), in_.m1_.x, in_.m1_.y);
        alpha = (_e206 * _e214);
    } else {
        if ((kind_1 == 2u)) {
            float lx = (px_2 - in_.p.x);
            float ly = (py_2 - in_.p.y);
            float mc = in_.m1_.z;
            float ms = in_.m1_.w;
            float y_1 = ((lx * mc) + (ly * ms));
            float x_1 = abs(((ly * mc) - (lx * ms)));
            float sa = in_.m2_.x;
            float ca = in_.m2_.y;
            float radius_1 = in_.m0_.y;
            const float _e241 = len2_(x_1, y_1);
            float ring = (abs((_e241 - radius_1)) - half_3);
            float past = ((in_.m2_.z != 0.0) ? -1e30 : ((x_1 * ca) - (y_1 * sa)));
            const float _e258 = len2_((x_1 - (sa * radius_1)), (y_1 - (ca * radius_1)));
            float disc = (_e258 - half_3);
            float flat_end = max(ring, (past - (half_3 * square)));
            float along_1 = (((atan2(((ly * mc) - (lx * ms)), y_1) + in_.m3_.x) * radius_1) + in_.m0_.w);
            const float _e278 = coverage((round_ ? ((past > 0.0) ? disc : ring) : flat_end));
            const float _e283 = dash_cover(along_1, in_.m1_.x, in_.m1_.y);
            alpha = (_e278 * _e283);
        } else {
            if (!((kind_1 == 1u))) {
                local_12 = (kind_1 == 3u);
            } else {
                local_12 = true;
            }
            bool _e293 = local_12;
            if (_e293) {
                if ((kind_1 == 1u)) {
                    const float _e298 = rect_dist(px_2, py_2, in_);
                    d = _e298;
                } else {
                    const float _e303 = polygon_dist(px_2, py_2, in_.k.z, in_.k.w);
                    d = _e303;
                }
                float _e304 = d;
                const float _e306 = coverage((_e304 - hw));
                float _e307 = d;
                const float _e309 = coverage((_e307 + hw));
                float on_3 = ((1.0 - _e309) * in_.m2_.z);
                colour = (in_.base + ((in_.stroke - in_.base) * on_3));
                alpha = _e306;
            } else {
                float dx_2 = (px_2 - in_.p.x);
                float dy_2 = (py_2 - in_.p.y);
                float c_2 = in_.m1_.z;
                float s = in_.m1_.w;
                float lx_1 = ((c_2 * dx_2) + (s * dy_2));
                float ly_1 = ((c_2 * dy_2) - (s * dx_2));
                if ((lx_1 >= 0.0)) {
                    local_13 = (lx_1 < in_.p.z);
                } else {
                    local_13 = false;
                }
                bool _e345 = local_13;
                if (_e345) {
                    local_14 = (ly_1 >= 0.0);
                } else {
                    local_14 = false;
                }
                bool _e351 = local_14;
                if (_e351) {
                    local_15 = (ly_1 < in_.p.w);
                } else {
                    local_15 = false;
                }
                bool hit = local_15;
                float2 n_1 = float2(NagaDimensions2D(atlas));
                float tu = (in_.uv.x + (lx_1 * in_.m3_.x));
                float tv = (in_.uv.y + (ly_1 * in_.m3_.y));
                uint tx = naga_f2u32(min(max(floor((tu * n_1.x)), 0.0), (n_1.x - 1.0)));
                uint ty = naga_f2u32(min(max(floor((tv * n_1.y)), 0.0), (n_1.y - 1.0)));
                float4 _e398 = atlas.Load(int3(uint2(tx, ty), int(0)));
                colour = (in_.stroke * _e398);
                alpha = (hit ? 1.0 : 0.0);
            }
        }
    }
    float _e404 = colour.w;
    float _e405 = alpha;
    float _e406 = keep;
    float _e410 = u.opacity;
    float a = clamp((_e404 * ((_e405 * _e406) * _e410)), 0.0, 1.0);
    float4 _e416 = colour;
    return float4((clamp(_e416.xyz, (0.0).xxx, (1.0).xxx) * a), a);
}
