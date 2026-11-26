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

float len2_(
    float x,
    float y
) {
    return metal::sqrt((x * x) + (y * y));
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
    float r_1 = metal::min(in_1.m0_.y, metal::min(hx, hy));
    float qx_1 = (metal::abs(px - ((in_1.p.x + in_1.p.z) * 0.5)) - hx) + r_1;
    float qy_1 = (metal::abs(py - ((in_1.p.y + in_1.p.w) * 0.5)) - hy) + r_1;
    float _e45 = box_dist(qx_1, qy_1);
    return _e45 - r_1;
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
            float left = (ex * oy) - (ey * ox);
            float _e84 = ay;
            if (_e84 <= py_1) {
                local_16 = _e48 > py_1;
            } else {
                local_16 = false;
            }
            bool _e90 = local_16;
            if (_e90) {
                local_17 = left > 0.0;
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
                local_19 = left < 0.0;
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
    float dash_1 = static_cast<float>((h >> 10u) & 15u);
    float half_ = width * 0.5;
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
    grow = half_ * static_cast<float>(stroked);
    if (kind == 0u) {
        grow = half_ * 1.4142135;
        float _e154 = u.scale;
        chain = static_cast<float>(r.look.y) * _e154;
        float _e160 = u.px;
        float on = (2.0 * dash_1) * _e160;
        m1_ = metal::float4(on, 2.0 * on, 1.0, 0.0);
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
        float m = ((start / 65536.0) * 6.2831855) + (sweep / 2.0);
        radius = rr;
        m1_ = metal::float4(0.0, 0.0, metal::cos(m), metal::sin(m));
        m2_ = metal::float4(metal::max(metal::sin(sweep / 2.0), 0.0), metal::cos(sweep / 2.0), static_cast<float>((r.look.z >> 16u) == 65535u), 0.0);
        p = metal::float4(corner.x, corner.y, 0.0, 0.0);
        float e = rr + half_;
        box = metal::float4((corner.x - e) - 1.0, (corner.y - e) - 1.0, (corner.x + e) + 1.0, (corner.y + e) + 1.0);
    } else {
        if (kind == 4u) {
            float _e275 = u.scale;
            float gw = static_cast<float>(as_type<uint>(r.pos.z)) * _e275;
            float _e283 = u.scale;
            float gh = static_cast<float>(as_type<uint>(r.pos.w)) * _e283;
            uint q = (h >> 16u) & 3u;
            type_12 c_1 = type_12 {{1.0, 0.0, -1.0, 0.0}};
            m1_ = metal::float4(0.0, 0.0, c_1.inner[q], c_1.inner[(q + 3u) & 3u]);
            p = metal::float4(corner.x, corner.y, gw, gh);
            float e_1 = metal::max(gw, gh);
            box = metal::float4((corner.x - e_1) - 1.0, (corner.y - e_1) - 1.0, (corner.x + e_1) + 1.0, (corner.y + e_1) + 1.0);
            float _e326 = unorm16_(r.look.y);
            float _e331 = unorm16_(r.look.y >> 16u);
            out.uv = metal::float2(_e326, _e331);
            float _e336 = unorm16_(r.look.z);
            float _e345 = unorm16_(r.look.z >> 16u);
            m3_ = metal::float4((_e336 - _e326) / metal::max(gw, 0.000001), (_e345 - _e331) / metal::max(gh, 0.000001), 0.0, 0.0);
        } else {
            float _e356 = grow;
            float _e363 = grow;
            float _e370 = grow;
            float _e377 = grow;
            box = metal::float4((metal::min(corner.x, corner.z) - _e356) - 1.0, (metal::min(corner.y, corner.w) - _e363) - 1.0, (metal::max(corner.x, corner.z) + _e370) + 1.0, (metal::max(corner.y, corner.w) + _e377) + 1.0);
        }
    }
    uint _e385 = u.row_base;
    uint _e388 = override_of(r.row - _e385, row.x, u);
    uint _e392 = u.row_base;
    uint _e395 = override_of(r.row - _e392, row.y, u);
    if ((h & 64u) != 0u) {
        local_4 = (row.w & 1u) != 0u;
    } else {
        local_4 = false;
    }
    bool filled = local_4;
    metal::float4 _e410 = rgba(_e388);
    out.stroke = _e410;
    metal::float4 _e413 = out.stroke;
    metal::float4 _e417 = rgba(_e395);
    out.base = filled ? _e417 : metal::float4(_e413.xyz, 0.0);
    metal::float4 _e420 = p;
    out.p = _e420;
    float _e422 = radius;
    float _e426 = chain;
    out.m0_ = metal::float4(half_, _e422, static_cast<float>(cap == 1u), _e426);
    metal::float4 _e429 = m1_;
    out.m1_ = _e429;
    float _e432 = m2_.x;
    float _e434 = m2_.y;
    float _e437 = m2_.z;
    out.m2_ = metal::float4(_e432, _e434, (kind == 2u) ? _e437 : static_cast<float>(stroked), half_ * static_cast<float>(stroked));
    metal::float4 _e445 = m3_;
    out.m3_ = _e445;
    out.k = metal::uint4(kind, static_cast<uint>(cap == 2u), r.look.y, r.look.z);
    metal::float4 _e455 = box;
    metal::float2 lo = metal::clamp(metal::floor(_e455.xy), metal::float2(0.0), metal::float2(16777216.0));
    metal::float4 _e463 = box;
    metal::float2 hi = metal::clamp(metal::ceil(_e463.zw), metal::float2(0.0), metal::float2(16777216.0));
    metal::float2 at = metal::select(lo, hi, metal::bool2((vi & 1u) != 0u, (vi & 2u) != 0u));
    metal::float2 _e484 = u.size;
    out.position = metal::float4(((at / _e484) * metal::float2(2.0, -2.0)) + metal::float2(-1.0, 1.0), 0.0, 1.0);
    Frag _e497 = out;
    const auto _tmp_1 = _e497;
    return vsOutput { _tmp_1.position, _tmp_1.p, _tmp_1.m0_, _tmp_1.m1_, _tmp_1.m2_, _tmp_1.m3_, _tmp_1.stroke, _tmp_1.base, _tmp_1.k, _tmp_1.uv };
}

uint naga_f2u32(float value) {
    return static_cast<uint>(metal::clamp(value, 0.0, 4294967000.0));
}


struct fsInput {
    metal::float4 p_1 [[user(loc0), flat]];
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
    const Frag in = { position, varyings_1.p_1, varyings_1.m0_, varyings_1.m1_1, varyings_1.m2_1, varyings_1.m3_1, varyings_1.stroke, varyings_1.base, varyings_1.k, varyings_1.uv };
    bool local_5 = {};
    bool local_6 = {};
    bool local_7 = {};
    bool local_8 = {};
    bool local_9 = {};
    bool local_10 = {};
    bool local_11 = {};
    metal::float4 colour = {};
    float alpha = 0.0;
    float dash = 1.0;
    bool local_12 = {};
    float d = 0.0;
    bool local_13 = {};
    bool local_14 = {};
    bool local_15 = {};
    float px_2 = in.position.x;
    float py_2 = in.position.y;
    float _e8 = u.rect.x;
    if (px_2 >= _e8) {
        float _e15 = u.rect.z;
        local_5 = px_2 < _e15;
    } else {
        local_5 = false;
    }
    bool _e18 = local_5;
    if (_e18) {
        float _e24 = u.rect.y;
        local_6 = py_2 >= _e24;
    } else {
        local_6 = false;
    }
    bool _e27 = local_6;
    if (_e27) {
        float _e33 = u.rect.w;
        local_7 = py_2 < _e33;
    } else {
        local_7 = false;
    }
    bool _e36 = local_7;
    if (_e36) {
        float _e42 = u.clip.x;
        local_8 = px_2 >= _e42;
    } else {
        local_8 = false;
    }
    bool _e45 = local_8;
    if (_e45) {
        float _e51 = u.clip.z;
        local_9 = px_2 <= _e51;
    } else {
        local_9 = false;
    }
    bool _e54 = local_9;
    if (_e54) {
        float _e60 = u.clip.y;
        local_10 = py_2 >= _e60;
    } else {
        local_10 = false;
    }
    bool _e63 = local_10;
    if (_e63) {
        float _e69 = u.clip.w;
        local_11 = py_2 <= _e69;
    } else {
        local_11 = false;
    }
    bool inside = local_11;
    float half_1 = in.m0_.x;
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
        float _e115 = len2_(metal::max(along - h_1, 0.0), across);
        float capsule = _e115 - half_1;
        float _e121 = box_dist((along - h_1) - (half_1 * square), across - half_1);
        float d_3 = round ? capsule : _e121;
        float period = in.m1_.y;
        if (period != 0.0) {
            float at_1 = t_1 + in.m0_.w;
            float m_1 = at_1 - (metal::floor(at_1 / period) * period);
            dash = metal::min(metal::max(metal::min(m_1, in.m1_.x - m_1) + 0.5, 0.0), 1.0);
        }
        float _e146 = coverage(d_3);
        float _e147 = dash;
        alpha = _e146 * _e147;
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
            float _e174 = len2_(x_1, y_1);
            float ring = metal::abs(_e174 - radius_1) - half_1;
            float past = (in.m2_.z != 0.0) ? -1000000000000000000000000000000.0 : ((x_1 * ca) - (y_1 * sa));
            float _e191 = len2_(x_1 - (sa * radius_1), y_1 - (ca * radius_1));
            float disc = _e191 - half_1;
            float flat_end = metal::max(ring, past - (half_1 * square));
            float _e200 = coverage(round ? ((past > 0.0) ? disc : ring) : flat_end);
            alpha = _e200;
        } else {
            if (!((kind_1 == 1u))) {
                local_12 = kind_1 == 3u;
            } else {
                local_12 = true;
            }
            bool _e209 = local_12;
            if (_e209) {
                if (kind_1 == 1u) {
                    float _e214 = rect_dist(px_2, py_2, in);
                    d = _e214;
                } else {
                    float _e219 = polygon_dist(px_2, py_2, in.k.z, in.k.w, u, verts, _buffer_sizes);
                    d = _e219;
                }
                float _e220 = d;
                float _e222 = coverage(_e220 - hw);
                float _e223 = d;
                float _e225 = coverage(_e223 + hw);
                float on_1 = (1.0 - _e225) * in.m2_.z;
                colour = in.base + ((in.stroke - in.base) * on_1);
                alpha = _e222;
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
                bool _e261 = local_13;
                if (_e261) {
                    local_14 = ly_1 >= 0.0;
                } else {
                    local_14 = false;
                }
                bool _e267 = local_14;
                if (_e267) {
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
                metal::float4 _e314 = atlas.read(metal::uint2(metal::uint2(tx, ty)), 0);
                colour = in.stroke * _e314;
                alpha = hit ? 1.0 : 0.0;
            }
        }
    }
    float _e320 = colour.w;
    float _e321 = alpha;
    float _e324 = u.opacity;
    float a = metal::clamp(_e320 * (_e321 * _e324), 0.0, 1.0) * static_cast<float>(inside);
    metal::float4 _e332 = colour;
    return fsOutput { metal::float4(metal::clamp(_e332.xyz, metal::float3(0.0), metal::float3(1.0)) * a, a) };
}
