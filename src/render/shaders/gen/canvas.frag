#version 300 es

precision highp float;
precision highp int;

struct Draw {
    ivec2 origin;
    vec2 base;
    float scale;
    float px;
    uint pad0_;
    uint pad1_;
    vec4 rect;
    vec4 clip;
    vec2 size;
    float opacity;
    uint row_base;
    uint vert_base;
    uint vert_len;
    uint overrides;
    uint layers;
    vec4 inv;
    vec2 inv_t;
    vec2 fwd_t;
    vec4 fwd;
    vec4 radii;
    vec4 clip_box;
    float px_scale;
    float inv_scale;
    uint rounded;
    uvec4 palette[256];
    uvec4 override_rows[512];
};
struct Row {
    ivec4 pos;
    uvec4 look;
    uint row;
    uint mark;
};
struct Frag {
    vec4 position;
    vec4 p;
    vec4 m0_;
    vec4 m1_;
    vec4 m2_;
    vec4 m3_;
    vec4 stroke;
    vec4 base;
    uvec4 k;
    vec2 uv;
};
layout(std140) uniform Draw_block_0Fragment { Draw _group_0_binding_0_fs; };

uniform highp sampler2D _group_1_binding_0_fs;

uniform highp usampler2D _group_0_binding_1_fs;

flat in vec4 _vs2fs_location0;
flat in vec4 _vs2fs_location1;
flat in vec4 _vs2fs_location2;
flat in vec4 _vs2fs_location3;
flat in vec4 _vs2fs_location4;
flat in vec4 _vs2fs_location5;
flat in vec4 _vs2fs_location6;
flat in uvec4 _vs2fs_location7;
flat in vec2 _vs2fs_location8;
layout(location = 0) out vec4 _fs2p_location0;

float wx(int w) {
    float _e4 = _group_0_binding_0_fs.base.x;
    int _e8 = _group_0_binding_0_fs.origin.x;
    float _e13 = _group_0_binding_0_fs.scale;
    return (_e4 + (float((w - _e8)) * _e13));
}

float wy(int w_1) {
    float _e4 = _group_0_binding_0_fs.base.y;
    int _e8 = _group_0_binding_0_fs.origin.y;
    float _e13 = _group_0_binding_0_fs.scale;
    return (_e4 + (float((w_1 - _e8)) * _e13));
}

vec4 rgba(uint c) {
    return (vec4(float((c & 255u)), float(((c >> 8u) & 255u)), float(((c >> 16u) & 255u)), float((c >> 24u))) / vec4(255.0));
}

float unorm16_(uint v) {
    return (float((v & 65535u)) / 65535.0);
}

uint override_of(uint i, uint colour_1) {
    uint found = 0u;
    uint j = 0u;
    found = colour_1;
    bool loop_init = true;
    while(true) {
        if (!loop_init) {
            uint _e25 = j;
            j = (_e25 + 1u);
        }
        loop_init = false;
        uint _e5 = j;
        uint _e8 = _group_0_binding_0_fs.overrides;
        if ((_e5 < min(_e8, 512u))) {
        } else {
            break;
        }
        {
            uint _e14 = j;
            uvec4 o = _group_0_binding_0_fs.override_rows[_e14];
            uint _e17 = found;
            found = (((i - o.x) < o.y) ? o.z : _e17);
        }
    }
    uint _e27 = found;
    return _e27;
}

vec2 screen(vec2 p_1) {
    float _e4 = _group_0_binding_0_fs.fwd.x;
    float _e10 = _group_0_binding_0_fs.fwd.z;
    float _e17 = _group_0_binding_0_fs.fwd_t.x;
    float _e22 = _group_0_binding_0_fs.fwd.y;
    float _e28 = _group_0_binding_0_fs.fwd.w;
    float _e35 = _group_0_binding_0_fs.fwd_t.y;
    return vec2((((_e4 * p_1.x) + (_e10 * p_1.y)) + _e17), (((_e22 * p_1.x) + (_e28 * p_1.y)) + _e35));
}

float distance_at(float fx, float fy, vec2 n) {
    float gx = (fx - 0.5);
    float gy = (fy - 0.5);
    float x0_ = floor(gx);
    float y0_ = floor(gy);
    float ax_1 = (gx - x0_);
    float ay_1 = (gy - y0_);
    uint xa = uint(min(max(x0_, 0.0), (n.x - 1.0)));
    uint xb = uint(min(max((x0_ + 1.0), 0.0), (n.x - 1.0)));
    uint ya = uint(min(max(y0_, 0.0), (n.y - 1.0)));
    uint yb = uint(min(max((y0_ + 1.0), 0.0), (n.y - 1.0)));
    vec4 _e46 = texelFetch(_group_1_binding_0_fs, ivec2(uvec2(xa, ya)), 0);
    float t0_ = roundEven((_e46.w * 255.0));
    vec4 _e54 = texelFetch(_group_1_binding_0_fs, ivec2(uvec2(xb, ya)), 0);
    float t1_ = roundEven((_e54.w * 255.0));
    vec4 _e62 = texelFetch(_group_1_binding_0_fs, ivec2(uvec2(xa, yb)), 0);
    float t2_ = roundEven((_e62.w * 255.0));
    vec4 _e70 = texelFetch(_group_1_binding_0_fs, ivec2(uvec2(xb, yb)), 0);
    float t3_ = roundEven((_e70.w * 255.0));
    float top = (t0_ + ((t1_ - t0_) * ax_1));
    float bottom = (t2_ + ((t3_ - t2_) * ax_1));
    return (top + ((bottom - top) * ay_1));
}

float corner_radius(vec2 p_2, vec2 half_, vec4 radii) {
    float right = ((p_2.y > 0.0) ? radii.z : radii.y);
    float left = ((p_2.y > 0.0) ? radii.w : radii.x);
    return min(((p_2.x > 0.0) ? right : left), min(half_.x, half_.y));
}

float len2_(float x, float y) {
    return sqrt(((x * x) + (y * y)));
}

float rounded_box(vec2 p_3, vec2 half_1, float r_1) {
    vec2 q = ((abs(p_3) - half_1) + vec2(r_1));
    float _e13 = len2_(max(q.x, 0.0), max(q.y, 0.0));
    return ((_e13 + min(max(q.x, q.y), 0.0)) - r_1);
}

float dash_cover(float at, float on, float period) {
    if ((period == 0.0)) {
        return 1.0;
    }
    float m = (at - (floor((at / period)) * period));
    return min(max((min(m, (on - m)) + 0.5), 0.0), 1.0);
}

float box_dist(float qx, float qy) {
    float _e6 = len2_(max(qx, 0.0), max(qy, 0.0));
    return (_e6 + min(max(qx, qy), 0.0));
}

float coverage(float d_1) {
    return min(max((0.5 - d_1), 0.0), 1.0);
}

float rect_dist(float px, float py, Frag in_1) {
    float hx = (abs((in_1.p.z - in_1.p.x)) * 0.5);
    float hy = (abs((in_1.p.w - in_1.p.y)) * 0.5);
    float r_2 = min(in_1.m0_.y, min(hx, hy));
    float qx_1 = ((abs((px - ((in_1.p.x + in_1.p.z) * 0.5))) - hx) + r_2);
    float qy_1 = ((abs((py - ((in_1.p.y + in_1.p.w) * 0.5))) - hy) + r_2);
    float _e45 = box_dist(qx_1, qy_1);
    return (_e45 - r_2);
}

ivec2 vert(uint i_1) {
    uint j_2 = (2u * i_1);
    uvec4 _e10 = texelFetch(_group_0_binding_1_fs, ivec2(uvec2((j_2 & 2047u), (j_2 >> 11u))), 0);
    uint x_1 = _e10.x;
    uvec4 _e23 = texelFetch(_group_0_binding_1_fs, ivec2(uvec2(((j_2 + 1u) & 2047u), ((j_2 + 1u) >> 11u))), 0);
    uint y_1 = _e23.x;
    return ivec2(int(x_1), int(y_1));
}

float polygon_dist(float px_1, float py_1, uint first, uint count) {
    float best = 3e38;
    int winding = 0;
    float ax = 0.0;
    float ay = 0.0;
    uint j_1 = 0u;
    bool local_18 = false;
    bool local_19 = false;
    bool local_20 = false;
    bool local_21 = false;
    uint _e6 = _group_0_binding_0_fs.vert_len;
    uint f = min(first, _e6);
    uint _e10 = _group_0_binding_0_fs.vert_len;
    uint n_1 = min(count, (_e10 - f));
    if ((n_1 == 0u)) {
        return 3e38;
    }
    uint _e22 = _group_0_binding_0_fs.vert_base;
    ivec2 _e27 = vert((((_e22 + f) + n_1) - 1u));
    float _e29 = wx(_e27.x);
    ax = _e29;
    float _e32 = wy(_e27.y);
    ay = _e32;
    bool loop_init_1 = true;
    while(true) {
        if (!loop_init_1) {
            uint _e116 = j_1;
            j_1 = (_e116 + 1u);
        }
        loop_init_1 = false;
        uint _e36 = j_1;
        if ((_e36 < n_1)) {
        } else {
            break;
        }
        {
            uint _e40 = _group_0_binding_0_fs.vert_base;
            uint _e42 = j_1;
            ivec2 _e44 = vert(((_e40 + f) + _e42));
            float _e46 = wx(_e44.x);
            float _e48 = wy(_e44.y);
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
                local_18 = (_e48 > py_1);
            } else {
                local_18 = false;
            }
            bool _e90 = local_18;
            if (_e90) {
                local_19 = (left_1 > 0.0);
            } else {
                local_19 = false;
            }
            bool up = local_19;
            float _e97 = ay;
            if ((_e97 > py_1)) {
                local_20 = (_e48 <= py_1);
            } else {
                local_20 = false;
            }
            bool _e103 = local_20;
            if (_e103) {
                local_21 = (left_1 < 0.0);
            } else {
                local_21 = false;
            }
            bool down = local_21;
            int _e110 = winding;
            winding = (_e110 + (int(up) - int(down)));
            ax = _e46;
            ay = _e48;
        }
    }
    float _e118 = best;
    float d_2 = sqrt(_e118);
    int _e121 = winding;
    return ((_e121 != 0) ? -(d_2) : d_2);
}

void main() {
    Frag in_ = Frag(gl_FragCoord, _vs2fs_location0, _vs2fs_location1, _vs2fs_location2, _vs2fs_location3, _vs2fs_location4, _vs2fs_location5, _vs2fs_location6, _vs2fs_location7, _vs2fs_location8);
    bool local_7 = false;
    bool local_8 = false;
    bool local_9 = false;
    bool local_10 = false;
    bool local_11 = false;
    bool local_12 = false;
    bool local_13 = false;
    float keep = 0.0;
    vec4 colour = vec4(0.0);
    float alpha = 0.0;
    bool local_14 = false;
    float d = 0.0;
    bool local_15 = false;
    bool local_16 = false;
    bool local_17 = false;
    float sx = in_.position.x;
    float sy = in_.position.y;
    float _e8 = _group_0_binding_0_fs.inv.x;
    float _e13 = _group_0_binding_0_fs.inv.z;
    float _e19 = _group_0_binding_0_fs.inv_t.x;
    float px_2 = (((_e8 * sx) + (_e13 * sy)) + _e19);
    float _e24 = _group_0_binding_0_fs.inv.y;
    float _e29 = _group_0_binding_0_fs.inv.w;
    float _e35 = _group_0_binding_0_fs.inv_t.y;
    float py_2 = (((_e24 * sx) + (_e29 * sy)) + _e35);
    float _e40 = _group_0_binding_0_fs.rect.x;
    if ((px_2 >= _e40)) {
        float _e47 = _group_0_binding_0_fs.rect.z;
        local_7 = (px_2 < _e47);
    } else {
        local_7 = false;
    }
    bool _e50 = local_7;
    if (_e50) {
        float _e56 = _group_0_binding_0_fs.rect.y;
        local_8 = (py_2 >= _e56);
    } else {
        local_8 = false;
    }
    bool _e59 = local_8;
    if (_e59) {
        float _e65 = _group_0_binding_0_fs.rect.w;
        local_9 = (py_2 < _e65);
    } else {
        local_9 = false;
    }
    bool _e68 = local_9;
    if (_e68) {
        float _e74 = _group_0_binding_0_fs.clip.x;
        local_10 = (sx >= _e74);
    } else {
        local_10 = false;
    }
    bool _e77 = local_10;
    if (_e77) {
        float _e83 = _group_0_binding_0_fs.clip.z;
        local_11 = (sx <= _e83);
    } else {
        local_11 = false;
    }
    bool _e86 = local_11;
    if (_e86) {
        float _e92 = _group_0_binding_0_fs.clip.y;
        local_12 = (sy >= _e92);
    } else {
        local_12 = false;
    }
    bool _e95 = local_12;
    if (_e95) {
        float _e101 = _group_0_binding_0_fs.clip.w;
        local_13 = (sy <= _e101);
    } else {
        local_13 = false;
    }
    bool inside = local_13;
    keep = float(inside);
    uint _e109 = _group_0_binding_0_fs.rounded;
    if ((_e109 != 0u)) {
        float _e114 = _group_0_binding_0_fs.inv_scale;
        float _e119 = _group_0_binding_0_fs.clip_box.x;
        float _e123 = _group_0_binding_0_fs.inv_scale;
        float _e128 = _group_0_binding_0_fs.clip_box.y;
        vec2 l = vec2(((sx * _e114) - _e119), ((sy * _e123) - _e128));
        vec4 _e133 = _group_0_binding_0_fs.clip_box;
        vec4 _e137 = _group_0_binding_0_fs.clip_box;
        vec4 _e141 = _group_0_binding_0_fs.radii;
        float _e142 = corner_radius(l, _e137.zw, _e141);
        float _e143 = rounded_box(l, _e133.zw, _e142);
        float _e146 = _group_0_binding_0_fs.px_scale;
        float corner = (_e143 * _e146);
        float _e148 = keep;
        keep = (_e148 * min(max((0.5 - corner), 0.0), 1.0));
    }
    float half_2 = in_.m0_.x;
    float square = in_.m0_.z;
    float hw = in_.m2_.w;
    colour = in_.stroke;
    uint kind = in_.k.x;
    bool round_ = (in_.k.y != 0u);
    if ((kind == 0u)) {
        float ux = in_.m3_.x;
        float uy = in_.m3_.y;
        float h = in_.m3_.z;
        float ox_1 = (px_2 - in_.p.x);
        float oy_1 = (py_2 - in_.p.y);
        float t_1 = ((ox_1 * ux) + (oy_1 * uy));
        float along = abs((t_1 - h));
        float across = abs(((oy_1 * ux) - (ox_1 * uy)));
        float _e198 = len2_(max((along - h), 0.0), across);
        float capsule = (_e198 - half_2);
        float _e204 = box_dist(((along - h) - (half_2 * square)), (across - half_2));
        float d_3 = (round_ ? capsule : _e204);
        float _e206 = coverage(d_3);
        float _e214 = dash_cover((t_1 + in_.m0_.w), in_.m1_.x, in_.m1_.y);
        alpha = (_e206 * _e214);
    } else {
        if ((kind == 2u)) {
            float lx = (px_2 - in_.p.x);
            float ly = (py_2 - in_.p.y);
            float mc = in_.m1_.z;
            float ms = in_.m1_.w;
            float y_2 = ((lx * mc) + (ly * ms));
            float x_2 = abs(((ly * mc) - (lx * ms)));
            float sa = in_.m2_.x;
            float ca = in_.m2_.y;
            float radius_1 = in_.m0_.y;
            float _e241 = len2_(x_2, y_2);
            float ring = (abs((_e241 - radius_1)) - half_2);
            float past = ((in_.m2_.z != 0.0) ? -1e30 : ((x_2 * ca) - (y_2 * sa)));
            float _e258 = len2_((x_2 - (sa * radius_1)), (y_2 - (ca * radius_1)));
            float disc = (_e258 - half_2);
            float flat_end = max(ring, (past - (half_2 * square)));
            float along_1 = (((atan(((ly * mc) - (lx * ms)), y_2) + in_.m3_.x) * radius_1) + in_.m0_.w);
            float _e278 = coverage((round_ ? ((past > 0.0) ? disc : ring) : flat_end));
            float _e283 = dash_cover(along_1, in_.m1_.x, in_.m1_.y);
            alpha = (_e278 * _e283);
        } else {
            if (!((kind == 1u))) {
                local_14 = (kind == 3u);
            } else {
                local_14 = true;
            }
            bool _e293 = local_14;
            if (_e293) {
                if ((kind == 1u)) {
                    float _e298 = rect_dist(px_2, py_2, in_);
                    d = _e298;
                } else {
                    float _e303 = polygon_dist(px_2, py_2, in_.k.z, in_.k.w);
                    d = _e303;
                }
                float _e304 = d;
                float _e306 = coverage((_e304 - hw));
                float _e307 = d;
                float _e309 = coverage((_e307 + hw));
                float on_1 = ((1.0 - _e309) * in_.m2_.z);
                colour = (in_.base + ((in_.stroke - in_.base) * on_1));
                alpha = _e306;
            } else {
                float dx_1 = (px_2 - in_.p.x);
                float dy_1 = (py_2 - in_.p.y);
                float c_1 = in_.m1_.z;
                float s = in_.m1_.w;
                float lx_1 = ((c_1 * dx_1) + (s * dy_1));
                float ly_1 = ((c_1 * dy_1) - (s * dx_1));
                if ((lx_1 >= 0.0)) {
                    local_15 = (lx_1 < in_.p.z);
                } else {
                    local_15 = false;
                }
                bool _e345 = local_15;
                if (_e345) {
                    local_16 = (ly_1 >= 0.0);
                } else {
                    local_16 = false;
                }
                bool _e351 = local_16;
                if (_e351) {
                    local_17 = (ly_1 < in_.p.w);
                } else {
                    local_17 = false;
                }
                bool hit = local_17;
                vec2 n_2 = vec2(uvec2(textureSize(_group_1_binding_0_fs, 0).xy));
                float tu = (in_.uv.x + (lx_1 * in_.m3_.x));
                float tv = (in_.uv.y + (ly_1 * in_.m3_.y));
                uint tx = uint(min(max(floor((tu * n_2.x)), 0.0), (n_2.x - 1.0)));
                uint ty = uint(min(max(floor((tv * n_2.y)), 0.0), (n_2.y - 1.0)));
                vec4 _e398 = texelFetch(_group_1_binding_0_fs, ivec2(uvec2(tx, ty)), 0);
                colour = (in_.stroke * _e398);
                if ((in_.m3_.z > 0.5)) {
                    float _e408 = distance_at((tu * n_2.x), (tv * n_2.y), n_2);
                    float d_4 = ((_e408 - 128.0) * 0.031496063);
                    float ppt = max((1.0 / (in_.m3_.x * n_2.x)), 0.125);
                    colour = vec4(in_.stroke.xyz, (in_.stroke.w * min(max(((d_4 * ppt) + 0.5), 0.0), 1.0)));
                }
                alpha = (hit ? 1.0 : 0.0);
            }
        }
    }
    float _e438 = colour.w;
    float _e439 = alpha;
    float _e440 = keep;
    float _e444 = _group_0_binding_0_fs.opacity;
    float a = clamp((_e438 * ((_e439 * _e440) * _e444)), 0.0, 1.0);
    vec4 _e450 = colour;
    _fs2p_location0 = vec4((clamp(_e450.xyz, vec3(0.0), vec3(1.0)) * a), a);
    return;
}

