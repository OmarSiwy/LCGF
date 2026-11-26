// language: metal1.0
#include <metal_stdlib>
#include <simd/simd.h>

using metal::uint;

struct _mslBufferSizes {
    uint size2;
};

struct type_6 {
    metal::uint4 inner[256];
};
struct type_7 {
    metal::uint4 inner[64];
};
struct Draw {
    metal::int2 origin;
    metal::float2 base;
    float scale;
    float line;
    float px;
    uint zoom_scale;
    metal::float4 rect;
    metal::float4 clip;
    metal::float2 size;
    float opacity;
    uint row_base;
    uint vert_base;
    uint vert_len;
    uint overrides;
    uint layers;
    metal::float4 inv;
    metal::float2 inv_t;
    metal::float2 fwd_t;
    metal::float4 fwd;
    metal::float4 radii;
    metal::float4 clip_box;
    float px_scale;
    float inv_scale;
    uint rounded;
    char _pad24[4];
    type_6 palette;
    type_7 marks;
};
struct Row {
    metal::int4 pos;
    metal::uint4 look;
    uint row;
    char _pad3[12];
};
struct Frag {
    metal::float4 position;
    metal::float4 p;
    metal::float4 m0_;
    metal::float4 m1_;
    metal::float4 m2_;
    metal::float4 m3_;
    metal::float4 stroke;
    metal::float4 base;
    metal::uint4 k;
    metal::float2 uv;
    char _pad10[8];
};
struct type_12 {
    float inner[4];
};
typedef metal::int2 type_14[1];

float wx(
    int w,
    constant Draw& u
) {
    float _e4 = u.base.x;
    int _e8 = u.origin.x;
    float _e13 = u.scale;
    return _e4 + (static_cast<float>(as_type<int>(as_type<uint>(w) - as_type<uint>(_e8))) * _e13);
}

float wy(
    int w_1,
    constant Draw& u
) {
    float _e4 = u.base.y;
    int _e8 = u.origin.y;
    float _e13 = u.scale;
    return _e4 + (static_cast<float>(as_type<int>(as_type<uint>(w_1) - as_type<uint>(_e8))) * _e13);
}

metal::float4 rgba(
    uint c
) {
    return metal::float4(static_cast<float>(c & 255u), static_cast<float>((c >> 8u) & 255u), static_cast<float>((c >> 16u) & 255u), static_cast<float>(c >> 24u)) / metal::float4(255.0);
}

float unorm16_(
    uint v
) {
    return static_cast<float>(v & 65535u) / 65535.0;
}

uint override_of(
    uint i,
    uint colour_1,
    constant Draw& u
) {
    uint found = {};
    uint j = 0u;
    found = colour_1;
    uint2 loop_bound = uint2(4294967295u);
    bool loop_init = true;
    while(true) {
        if (metal::all(loop_bound == uint2(0u))) { break; }
        loop_bound -= uint2(loop_bound.y == 0u, 1u);
        if (!loop_init) {
            uint _e25 = j;
            j = _e25 + 1u;
        }
        loop_init = false;
        uint _e5 = j;
        uint _e8 = u.overrides;
        if (_e5 < metal::min(_e8, 64u)) {
        } else {
            break;
        }
        {
            uint _e14 = j;
            metal::uint4 o = u.marks.inner[_e14];
            uint _e17 = found;
            found = ((i - o.x) < o.y) ? o.z : _e17;
        }
    }
    uint _e27 = found;
    return _e27;
}

metal::float2 screen(
    metal::float2 p_1,
    constant Draw& u
) {
    float _e4 = u.fwd.x;
    float _e10 = u.fwd.z;
    float _e17 = u.fwd_t.x;
    float _e22 = u.fwd.y;
    float _e28 = u.fwd.w;
    float _e35 = u.fwd_t.y;
    return metal::float2(((_e4 * p_1.x) + (_e10 * p_1.y)) + _e17, ((_e22 * p_1.x) + (_e28 * p_1.y)) + _e35);
}

float corner_radius(
    metal::float2 p_2,
    metal::float2 half_,
    metal::float4 radii
) {
    float right = (p_2.y > 0.0) ? radii.z : radii.y;
    float left = (p_2.y > 0.0) ? radii.w : radii.x;
    return metal::min((p_2.x > 0.0) ? right : left, metal::min(half_.x, half_.y));
}

float len2_(
    float x,
    float y
) {
    return metal::sqrt((x * x) + (y * y));
}

float rounded_box(
    metal::float2 p_3,
    metal::float2 half_1,
    float r_1
) {
    metal::float2 q = (metal::abs(p_3) - half_1) + metal::float2(r_1);
    float _e13 = len2_(metal::max(q.x, 0.0), metal::max(q.y, 0.0));
    return (_e13 + metal::min(metal::max(q.x, q.y), 0.0)) - r_1;
}

float dash_cover(
    float at,
    float on,
    float period
) {
    if (period == 0.0) {
        return 1.0;
    }
    float m = at - (metal::floor(at / period) * period);
    return metal::min(metal::max(metal::min(m, on - m) + 0.5, 0.0), 1.0);
}

float box_dist(
    float qx,
    float qy
) {
    float _e6 = len2_(metal::max(qx, 0.0), metal::max(qy, 0.0));
    return _e6 + metal::min(metal::max(qx, qy), 0.0);
}

float coverage(
    float d_1
) {
    return metal::min(metal::max(0.5 - d_1, 0.0), 1.0);
}

float rect_dist(
    float px,
    float py,
    Frag in_1
) {
    float hx = metal::abs(in_1.p.z - in_1.p.x) * 0.5;
    float hy = metal::abs(in_1.p.w - in_1.p.y) * 0.5;
    float r_2 = metal::min(in_1.m0_.y, metal::min(hx, hy));
    float qx_1 = (metal::abs(px - ((in_1.p.x + in_1.p.z) * 0.5)) - hx) + r_2;
    float qy_1 = (metal::abs(py - ((in_1.p.y + in_1.p.w) * 0.5)) - hy) + r_2;
    float _e45 = box_dist(qx_1, qy_1);
    return _e45 - r_2;
}

metal::int2 vert(
    uint i_1,
    device type_14 const& verts,
    constant _mslBufferSizes& _buffer_sizes
) {
    metal::int2 _e3 = verts[i_1];
    return _e3;
}

float polygon_dist(
    float px_1,
    float py_1,
    uint first,
    uint count,
    constant Draw& u,
    device type_14 const& verts,
    constant _mslBufferSizes& _buffer_sizes
) {
    float best = 300000000000000000000000000000000000000.0;
    int winding = 0;
    float ax = {};
    float ay = {};
    uint j_1 = 0u;
    bool local_16 = {};
    bool local_17 = {};
    bool local_18 = {};
    bool local_19 = {};
    uint _e6 = u.vert_len;
    uint f = metal::min(first, _e6);
    uint _e10 = u.vert_len;
    uint n = metal::min(count, _e10 - f);
    if (n == 0u) {
        return 300000000000000000000000000000000000000.0;
    }
    uint _e22 = u.vert_base;
    metal::int2 _e27 = vert(((_e22 + f) + n) - 1u, verts, _buffer_sizes);
    float _e29 = wx(_e27.x, u);
    ax = _e29;
    float _e32 = wy(_e27.y, u);
    ay = _e32;
    uint2 loop_bound_1 = uint2(4294967295u);
    bool loop_init_1 = true;
    while(true) {
        if (metal::all(loop_bound_1 == uint2(0u))) { break; }
        loop_bound_1 -= uint2(loop_bound_1.y == 0u, 1u);
        if (!loop_init_1) {
            uint _e116 = j_1;
            j_1 = _e116 + 1u;
        }
        loop_init_1 = false;
        uint _e36 = j_1;
        if (_e36 < n) {
        } else {
            break;
        }
        {
            uint _e40 = u.vert_base;
            uint _e42 = j_1;
            metal::int2 _e44 = vert((_e40 + f) + _e42, verts, _buffer_sizes);
            float _e46 = wx(_e44.x, u);
            float _e48 = wy(_e44.y, u);
            float _e49 = ax;
            float ex = _e46 - _e49;
            float _e51 = ay;
            float ey = _e48 - _e51;
            float _e53 = ax;
            float ox = px_1 - _e53;
            float _e55 = ay;
            float oy = py_1 - _e55;
            float t = metal::min(metal::max(((ox * ex) + (oy * ey)) * (1.0 / metal::max((ex * ex) + (ey * ey), 0.000000000001)), 0.0), 1.0);
            float dx = ox - (ex * t);
            float dy = oy - (ey * t);
            float _e76 = best;
            best = metal::min(_e76, (dx * dx) + (dy * dy));
            float left_1 = (ex * oy) - (ey * ox);
            float _e84 = ay;
            if (_e84 <= py_1) {
                local_16 = _e48 > py_1;
            } else {
                local_16 = false;
            }
            bool _e90 = local_16;
            if (_e90) {
                local_17 = left_1 > 0.0;
            } else {
                local_17 = false;
            }
            bool up = local_17;
            float _e97 = ay;
            if (_e97 > py_1) {
                local_18 = _e48 <= py_1;
            } else {
                local_18 = false;
            }
            bool _e103 = local_18;
            if (_e103) {
                local_19 = left_1 < 0.0;
            } else {
                local_19 = false;
            }
            bool down = local_19;
            int _e110 = winding;
            winding = as_type<int>(as_type<uint>(_e110) + as_type<uint>(as_type<int>(as_type<uint>(static_cast<int>(up)) - as_type<uint>(static_cast<int>(down)))));
            ax = _e46;
            ay = _e48;
        }
    }
    float _e118 = best;
    float d_2 = metal::sqrt(_e118);
    int _e121 = winding;
    return (_e121 != 0) ? -(d_2) : d_2;
}

struct vsInput {
    metal::int4 pos [[attribute(0)]];
    metal::uint4 look [[attribute(1)]];
    uint row [[attribute(2)]];
};
struct vsOutput {
    metal::float4 position [[position]];
    metal::float4 p [[user(loc0), flat]];
    metal::float4 m0_ [[user(loc1), flat]];
    metal::float4 m1_ [[user(loc2), flat]];
    metal::float4 m2_ [[user(loc3), flat]];
    metal::float4 m3_ [[user(loc4), flat]];
    metal::float4 stroke [[user(loc5), flat]];
    metal::float4 base [[user(loc6), flat]];
    metal::uint4 k [[user(loc7), flat]];
    metal::float2 uv [[user(loc8), flat]];
};
vertex vsOutput vs(
  vsInput varyings [[stage_in]]
, uint vi [[vertex_id]]
, constant Draw& u [[user(fake0)]]
) {
    const Row r = { varyings.pos, varyings.look, varyings.row };
    Frag out = {};
    bool local = {};
    bool local_1 = {};
    bool local_2 = {};
    bool local_3 = {};
    metal::float4 p = {};
    float radius = {};
    float grow = {};
    metal::float4 m1_ = metal::float4(0.0, 0.0, 1.0, 0.0);
    metal::float4 m2_ = metal::float4(0.0, 1.0, 0.0, 0.0);
    metal::float4 m3_ = metal::float4(0.0);
    float chain = 0.0;
    metal::float4 box = metal::float4(0.0);
    bool local_4 = {};
    uint h = r.look.x;
    uint layer = h >> 24u;
    metal::uint4 row = u.palette.inner[metal::min(layer, 255u)];
    out.position = metal::float4(-2.0, -2.0, 0.0, 1.0);
    if (!(((h & 512u) != 0u))) {
        uint _e28 = u.layers;
        local = layer >= _e28;
    } else {
        local = true;
    }
    bool _e31 = local;
    if (!(_e31)) {
        local_1 = (row.w & 2u) == 0u;
    } else {
        local_1 = true;
    }
    bool _e41 = local_1;
    if (_e41) {
        Frag _e42 = out;
        const auto _tmp = _e42;
        return vsOutput { _tmp.position, _tmp.p, _tmp.m0_, _tmp.m1_, _tmp.m2_, _tmp.m3_, _tmp.stroke, _tmp.base, _tmp.k, _tmp.uv };
    }
    uint kind = h & 15u;
    uint cap = (h >> 4u) & 3u;
    float weight = static_cast<float>(((h >> 14u) & 3u) + 1u);
    float _e61 = u.line;
    float _e68 = u.scale;
    float width = ((h & 256u) != 0u) ? (static_cast<float>(r.look.w) * _e68) : ((weight * as_type<float>(row.z)) * _e61);
    float _e77 = wx(r.pos.x, u);
    float _e80 = wy(r.pos.y, u);
    float _e83 = wx(r.pos.z, u);
    float _e86 = wy(r.pos.w, u);
    metal::float4 corner = metal::float4(_e77, _e80, _e83, _e86);
    float dash = static_cast<float>((h >> 10u) & 15u);
    float half_2 = width * 0.5;
    if (!(((h & 128u) != 0u))) {
        local_2 = kind == 0u;
    } else {
        local_2 = true;
    }
    bool _e105 = local_2;
    if (!(_e105)) {
        local_3 = kind == 2u;
    } else {
        local_3 = true;
    }
    bool stroked = local_3;
    p = corner;
    float _e119 = u.scale;
    radius = static_cast<float>(r.look.y) * _e119;
    grow = half_2 * static_cast<float>(stroked);
    if (kind == 0u) {
        grow = half_2 * 1.4142135;
        float _e154 = u.scale;
        chain = static_cast<float>(r.look.y) * _e154;
        float _e160 = u.px;
        float on_1 = (2.0 * dash) * _e160;
        m1_ = metal::float4(on_1, 2.0 * on_1, 1.0, 0.0);
        float dx_1 = corner.z - corner.x;
        float dy_1 = corner.w - corner.y;
        float l = metal::sqrt((dx_1 * dx_1) + (dy_1 * dy_1));
        float kk = 1.0 / metal::max(l, 0.000001);
        m3_ = metal::float4((l > 0.000001) ? (dx_1 * kk) : 1.0, dy_1 * kk, l * 0.5, 0.0);
    }
    if (kind == 2u) {
        float _e199 = u.scale;
        float rr = static_cast<float>(as_type<uint>(r.pos.z)) * _e199;
        float start = static_cast<float>(r.look.z & 65535u);
        float sweep = (static_cast<float>(r.look.z >> 16u) / 65535.0) * 6.2831855;
        float m_1 = ((start / 65536.0) * 6.2831855) + (sweep / 2.0);
        radius = rr;
        float _e227 = u.scale;
        chain = static_cast<float>(r.look.y) * _e227;
        float _e233 = u.px;
        float on_2 = (2.0 * dash) * _e233;
        m1_ = metal::float4(on_2, 2.0 * on_2, metal::cos(m_1), metal::sin(m_1));
        m3_ = metal::float4(sweep / 2.0, 0.0, 0.0, 0.0);
        m2_ = metal::float4(metal::max(metal::sin(sweep / 2.0), 0.0), metal::cos(sweep / 2.0), static_cast<float>((r.look.z >> 16u) == 65535u), 0.0);
        p = metal::float4(corner.x, corner.y, 0.0, 0.0);
        float e = rr + half_2;
        box = metal::float4((corner.x - e) - 1.0, (corner.y - e) - 1.0, (corner.x + e) + 1.0, (corner.y + e) + 1.0);
    } else {
        if (kind == 4u) {
            float _e294 = u.scale;
            float gw = static_cast<float>(as_type<uint>(r.pos.z)) * _e294;
            float _e302 = u.scale;
            float gh = static_cast<float>(as_type<uint>(r.pos.w)) * _e302;
            uint q_1 = (h >> 16u) & 3u;
            type_12 c_1 = type_12 {{1.0, 0.0, -1.0, 0.0}};
            m1_ = metal::float4(0.0, 0.0, c_1.inner[q_1], c_1.inner[(q_1 + 3u) & 3u]);
            p = metal::float4(corner.x, corner.y, gw, gh);
            float e_1 = metal::max(gw, gh);
            box = metal::float4((corner.x - e_1) - 1.0, (corner.y - e_1) - 1.0, (corner.x + e_1) + 1.0, (corner.y + e_1) + 1.0);
            float _e345 = unorm16_(r.look.y);
            float _e350 = unorm16_(r.look.y >> 16u);
            out.uv = metal::float2(_e345, _e350);
            float _e355 = unorm16_(r.look.z);
            float _e364 = unorm16_(r.look.z >> 16u);
            m3_ = metal::float4((_e355 - _e345) / metal::max(gw, 0.000001), (_e364 - _e350) / metal::max(gh, 0.000001), 0.0, 0.0);
        } else {
            float _e375 = grow;
            float _e382 = grow;
            float _e389 = grow;
            float _e396 = grow;
            box = metal::float4((metal::min(corner.x, corner.z) - _e375) - 1.0, (metal::min(corner.y, corner.w) - _e382) - 1.0, (metal::max(corner.x, corner.z) + _e389) + 1.0, (metal::max(corner.y, corner.w) + _e396) + 1.0);
        }
    }
    uint _e404 = u.row_base;
    uint _e407 = override_of(r.row - _e404, row.x, u);
    uint _e411 = u.row_base;
    uint _e414 = override_of(r.row - _e411, row.y, u);
    if ((h & 64u) != 0u) {
        local_4 = (row.w & 1u) != 0u;
    } else {
        local_4 = false;
    }
    bool filled = local_4;
    metal::float4 _e429 = rgba(_e407);
    out.stroke = _e429;
    metal::float4 _e432 = out.stroke;
    metal::float4 _e436 = rgba(_e414);
    out.base = filled ? _e436 : metal::float4(_e432.xyz, 0.0);
    metal::float4 _e439 = p;
    out.p = _e439;
    float _e441 = radius;
    float _e445 = chain;
    out.m0_ = metal::float4(half_2, _e441, static_cast<float>(cap == 1u), _e445);
    metal::float4 _e448 = m1_;
    out.m1_ = _e448;
    float _e451 = m2_.x;
    float _e453 = m2_.y;
    float _e456 = m2_.z;
    out.m2_ = metal::float4(_e451, _e453, (kind == 2u) ? _e456 : static_cast<float>(stroked), half_2 * static_cast<float>(stroked));
    metal::float4 _e464 = m3_;
    out.m3_ = _e464;
    out.k = metal::uint4(kind, static_cast<uint>(cap == 2u), r.look.y, r.look.z);
    metal::float4 _e474 = box;
    metal::float2 _e476 = screen(_e474.xy, u);
    metal::float4 _e477 = box;
    metal::float2 _e479 = screen(_e477.zy, u);
    metal::float4 _e480 = box;
    metal::float2 _e482 = screen(_e480.xw, u);
    metal::float4 _e483 = box;
    metal::float2 _e485 = screen(_e483.zw, u);
    metal::float2 lo = metal::clamp(metal::floor(metal::min(metal::min(_e476, _e479), metal::min(_e482, _e485))), metal::float2(0.0), metal::float2(16777216.0));
    metal::float2 hi = metal::clamp(metal::ceil(metal::max(metal::max(_e476, _e479), metal::max(_e482, _e485))), metal::float2(0.0), metal::float2(16777216.0));
    metal::float2 at_1 = metal::select(lo, hi, metal::bool2((vi & 1u) != 0u, (vi & 2u) != 0u));
    metal::float2 _e517 = u.size;
    out.position = metal::float4(((at_1 / _e517) * metal::float2(2.0, -2.0)) + metal::float2(-1.0, 1.0), 0.0, 1.0);
    Frag _e530 = out;
    const auto _tmp_1 = _e530;
    return vsOutput { _tmp_1.position, _tmp_1.p, _tmp_1.m0_, _tmp_1.m1_, _tmp_1.m2_, _tmp_1.m3_, _tmp_1.stroke, _tmp_1.base, _tmp_1.k, _tmp_1.uv };
}

uint naga_f2u32(float value) {
    return static_cast<uint>(metal::clamp(value, 0.0, 4294967000.0));
}


struct fsInput {
    metal::float4 p_4 [[user(loc0), flat]];
    metal::float4 m0_ [[user(loc1), flat]];
    metal::float4 m1_1 [[user(loc2), flat]];
    metal::float4 m2_1 [[user(loc3), flat]];
    metal::float4 m3_1 [[user(loc4), flat]];
    metal::float4 stroke [[user(loc5), flat]];
    metal::float4 base [[user(loc6), flat]];
    metal::uint4 k [[user(loc7), flat]];
    metal::float2 uv [[user(loc8), flat]];
};
struct fsOutput {
    metal::float4 member_1 [[color(0)]];
};
fragment fsOutput fs(
  fsInput varyings_1 [[stage_in]]
, metal::float4 position [[position]]
, constant Draw& u [[user(fake0)]]
, metal::texture2d<float, metal::access::sample> atlas [[user(fake0)]]
, device type_14 const& verts [[user(fake0)]]
, constant _mslBufferSizes& _buffer_sizes [[user(fake0)]]
) {
    const Frag in = { position, varyings_1.p_4, varyings_1.m0_, varyings_1.m1_1, varyings_1.m2_1, varyings_1.m3_1, varyings_1.stroke, varyings_1.base, varyings_1.k, varyings_1.uv };
    bool local_5 = {};
    bool local_6 = {};
    bool local_7 = {};
    bool local_8 = {};
    bool local_9 = {};
    bool local_10 = {};
    bool local_11 = {};
    float keep = {};
    metal::float4 colour = {};
    float alpha = 0.0;
    bool local_12 = {};
    float d = 0.0;
    bool local_13 = {};
    bool local_14 = {};
    bool local_15 = {};
    float sx = in.position.x;
    float sy = in.position.y;
    float _e8 = u.inv.x;
    float _e13 = u.inv.z;
    float _e19 = u.inv_t.x;
    float px_2 = ((_e8 * sx) + (_e13 * sy)) + _e19;
    float _e24 = u.inv.y;
    float _e29 = u.inv.w;
    float _e35 = u.inv_t.y;
    float py_2 = ((_e24 * sx) + (_e29 * sy)) + _e35;
    float _e40 = u.rect.x;
    if (px_2 >= _e40) {
        float _e47 = u.rect.z;
        local_5 = px_2 < _e47;
    } else {
        local_5 = false;
    }
    bool _e50 = local_5;
    if (_e50) {
        float _e56 = u.rect.y;
        local_6 = py_2 >= _e56;
    } else {
        local_6 = false;
    }
    bool _e59 = local_6;
    if (_e59) {
        float _e65 = u.rect.w;
        local_7 = py_2 < _e65;
    } else {
        local_7 = false;
    }
    bool _e68 = local_7;
    if (_e68) {
        float _e74 = u.clip.x;
        local_8 = sx >= _e74;
    } else {
        local_8 = false;
    }
    bool _e77 = local_8;
    if (_e77) {
        float _e83 = u.clip.z;
        local_9 = sx <= _e83;
    } else {
        local_9 = false;
    }
    bool _e86 = local_9;
    if (_e86) {
        float _e92 = u.clip.y;
        local_10 = sy >= _e92;
    } else {
        local_10 = false;
    }
    bool _e95 = local_10;
    if (_e95) {
        float _e101 = u.clip.w;
        local_11 = sy <= _e101;
    } else {
        local_11 = false;
    }
    bool inside = local_11;
    keep = static_cast<float>(inside);
    uint _e109 = u.rounded;
    if (_e109 != 0u) {
        float _e114 = u.inv_scale;
        float _e119 = u.clip_box.x;
        float _e123 = u.inv_scale;
        float _e128 = u.clip_box.y;
        metal::float2 l_1 = metal::float2((sx * _e114) - _e119, (sy * _e123) - _e128);
        metal::float4 _e133 = u.clip_box;
        metal::float4 _e137 = u.clip_box;
        metal::float4 _e141 = u.radii;
        float _e142 = corner_radius(l_1, _e137.zw, _e141);
        float _e143 = rounded_box(l_1, _e133.zw, _e142);
        float _e146 = u.px_scale;
        float corner_1 = _e143 * _e146;
        float _e148 = keep;
        keep = _e148 * metal::min(metal::max(0.5 - corner_1, 0.0), 1.0);
    }
    float half_3 = in.m0_.x;
    float square = in.m0_.z;
    float hw = in.m2_.w;
    colour = in.stroke;
    uint kind_1 = in.k.x;
    bool round = in.k.y != 0u;
    if (kind_1 == 0u) {
        float ux = in.m3_.x;
        float uy = in.m3_.y;
        float h_1 = in.m3_.z;
        float ox_1 = px_2 - in.p.x;
        float oy_1 = py_2 - in.p.y;
        float t_1 = (ox_1 * ux) + (oy_1 * uy);
        float along = metal::abs(t_1 - h_1);
        float across = metal::abs((oy_1 * ux) - (ox_1 * uy));
        float _e198 = len2_(metal::max(along - h_1, 0.0), across);
        float capsule = _e198 - half_3;
        float _e204 = box_dist((along - h_1) - (half_3 * square), across - half_3);
        float d_3 = round ? capsule : _e204;
        float _e206 = coverage(d_3);
        float _e214 = dash_cover(t_1 + in.m0_.w, in.m1_.x, in.m1_.y);
        alpha = _e206 * _e214;
    } else {
        if (kind_1 == 2u) {
            float lx = px_2 - in.p.x;
            float ly = py_2 - in.p.y;
            float mc = in.m1_.z;
            float ms = in.m1_.w;
            float y_1 = (lx * mc) + (ly * ms);
            float x_1 = metal::abs((ly * mc) - (lx * ms));
            float sa = in.m2_.x;
            float ca = in.m2_.y;
            float radius_1 = in.m0_.y;
            float _e241 = len2_(x_1, y_1);
            float ring = metal::abs(_e241 - radius_1) - half_3;
            float past = (in.m2_.z != 0.0) ? -1000000000000000000000000000000.0 : ((x_1 * ca) - (y_1 * sa));
            float _e258 = len2_(x_1 - (sa * radius_1), y_1 - (ca * radius_1));
            float disc = _e258 - half_3;
            float flat_end = metal::max(ring, past - (half_3 * square));
            float along_1 = ((metal::atan2((ly * mc) - (lx * ms), y_1) + in.m3_.x) * radius_1) + in.m0_.w;
            float _e278 = coverage(round ? ((past > 0.0) ? disc : ring) : flat_end);
            float _e283 = dash_cover(along_1, in.m1_.x, in.m1_.y);
            alpha = _e278 * _e283;
        } else {
            if (!((kind_1 == 1u))) {
                local_12 = kind_1 == 3u;
            } else {
                local_12 = true;
            }
            bool _e293 = local_12;
            if (_e293) {
                if (kind_1 == 1u) {
                    float _e298 = rect_dist(px_2, py_2, in);
                    d = _e298;
                } else {
                    float _e303 = polygon_dist(px_2, py_2, in.k.z, in.k.w, u, verts, _buffer_sizes);
                    d = _e303;
                }
                float _e304 = d;
                float _e306 = coverage(_e304 - hw);
                float _e307 = d;
                float _e309 = coverage(_e307 + hw);
                float on_3 = (1.0 - _e309) * in.m2_.z;
                colour = in.base + ((in.stroke - in.base) * on_3);
                alpha = _e306;
            } else {
                float dx_2 = px_2 - in.p.x;
                float dy_2 = py_2 - in.p.y;
                float c_2 = in.m1_.z;
                float s = in.m1_.w;
                float lx_1 = (c_2 * dx_2) + (s * dy_2);
                float ly_1 = (c_2 * dy_2) - (s * dx_2);
                if (lx_1 >= 0.0) {
                    local_13 = lx_1 < in.p.z;
                } else {
                    local_13 = false;
                }
                bool _e345 = local_13;
                if (_e345) {
                    local_14 = ly_1 >= 0.0;
                } else {
                    local_14 = false;
                }
                bool _e351 = local_14;
                if (_e351) {
                    local_15 = ly_1 < in.p.w;
                } else {
                    local_15 = false;
                }
                bool hit = local_15;
                metal::float2 n_1 = static_cast<metal::float2>(metal::uint2(atlas.get_width(), atlas.get_height()));
                float tu = in.uv.x + (lx_1 * in.m3_.x);
                float tv = in.uv.y + (ly_1 * in.m3_.y);
                uint tx = naga_f2u32(metal::min(metal::max(metal::floor(tu * n_1.x), 0.0), n_1.x - 1.0));
                uint ty = naga_f2u32(metal::min(metal::max(metal::floor(tv * n_1.y), 0.0), n_1.y - 1.0));
                metal::float4 _e398 = atlas.read(metal::uint2(metal::uint2(tx, ty)), 0);
                colour = in.stroke * _e398;
                alpha = hit ? 1.0 : 0.0;
            }
        }
    }
    float _e404 = colour.w;
    float _e405 = alpha;
    float _e406 = keep;
    float _e410 = u.opacity;
    float a = metal::clamp(_e404 * ((_e405 * _e406) * _e410), 0.0, 1.0);
    metal::float4 _e416 = colour;
    return fsOutput { metal::float4(metal::clamp(_e416.xyz, metal::float3(0.0), metal::float3(1.0)) * a, a) };
}
