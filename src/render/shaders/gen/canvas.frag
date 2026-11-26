#version 300 es

precision highp float;
precision highp int;

struct Draw {
    ivec2 origin;
    vec2 base;
    float scale;
    float line;
    float px;
    uint zoom_scale;
    vec4 rect;
    vec4 clip;
    vec2 size;
    float opacity;
    uint row_base;
    uint vert_base;
    uint vert_len;
    uint overrides;
    uint layers;
    uvec4 palette[256];
    uvec4 marks[64];
};
struct Row {
    ivec4 pos;
    uvec4 look;
    uint row;
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
        if ((_e5 < min(_e8, 64u))) {
        } else {
            break;
        }
        {
            uint _e14 = j;
            uvec4 o = _group_0_binding_0_fs.marks[_e14];
            uint _e17 = found;
            found = (((i - o.x) < o.y) ? o.z : _e17);
        }
    }
    uint _e27 = found;
    return _e27;
}

float len2_(float x, float y) {
    return sqrt(((x * x) + (y * y)));
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
    float r_1 = min(in_1.m0_.y, min(hx, hy));
    float qx_1 = ((abs((px - ((in_1.p.x + in_1.p.z) * 0.5))) - hx) + r_1);
    float qy_1 = ((abs((py - ((in_1.p.y + in_1.p.w) * 0.5))) - hy) + r_1);
    float _e45 = box_dist(qx_1, qy_1);
    return (_e45 - r_1);
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
    bool local_16 = false;
    bool local_17 = false;
    bool local_18 = false;
    bool local_19 = false;
    uint _e6 = _group_0_binding_0_fs.vert_len;
    uint f = min(first, _e6);
    uint _e10 = _group_0_binding_0_fs.vert_len;
    uint n = min(count, (_e10 - f));
    if ((n == 0u)) {
        return 3e38;
    }
    uint _e22 = _group_0_binding_0_fs.vert_base;
    ivec2 _e27 = vert((((_e22 + f) + n) - 1u));
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
        if ((_e36 < n)) {
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
            float left = ((ex * oy) - (ey * ox));
            float _e84 = ay;
            if ((_e84 <= py_1)) {
                local_16 = (_e48 > py_1);
            } else {
                local_16 = false;
            }
            bool _e90 = local_16;
            if (_e90) {
                local_17 = (left > 0.0);
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
                local_19 = (left < 0.0);
            } else {
                local_19 = false;
            }
            bool down = local_19;
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
    bool local_5 = false;
    bool local_6 = false;
    bool local_7 = false;
    bool local_8 = false;
    bool local_9 = false;
    bool local_10 = false;
    bool local_11 = false;
    vec4 colour = vec4(0.0);
    float alpha = 0.0;
    float dash = 1.0;
    bool local_12 = false;
    float d = 0.0;
    bool local_13 = false;
    bool local_14 = false;
    bool local_15 = false;
    float px_2 = in_.position.x;
    float py_2 = in_.position.y;
    float _e8 = _group_0_binding_0_fs.rect.x;
    if ((px_2 >= _e8)) {
        float _e15 = _group_0_binding_0_fs.rect.z;
        local_5 = (px_2 < _e15);
    } else {
        local_5 = false;
    }
    bool _e18 = local_5;
    if (_e18) {
        float _e24 = _group_0_binding_0_fs.rect.y;
        local_6 = (py_2 >= _e24);
    } else {
        local_6 = false;
    }
    bool _e27 = local_6;
    if (_e27) {
        float _e33 = _group_0_binding_0_fs.rect.w;
        local_7 = (py_2 < _e33);
    } else {
        local_7 = false;
    }
    bool _e36 = local_7;
    if (_e36) {
        float _e42 = _group_0_binding_0_fs.clip.x;
        local_8 = (px_2 >= _e42);
    } else {
        local_8 = false;
    }
    bool _e45 = local_8;
    if (_e45) {
        float _e51 = _group_0_binding_0_fs.clip.z;
        local_9 = (px_2 <= _e51);
    } else {
        local_9 = false;
    }
    bool _e54 = local_9;
    if (_e54) {
        float _e60 = _group_0_binding_0_fs.clip.y;
        local_10 = (py_2 >= _e60);
    } else {
        local_10 = false;
    }
    bool _e63 = local_10;
    if (_e63) {
        float _e69 = _group_0_binding_0_fs.clip.w;
        local_11 = (py_2 <= _e69);
    } else {
        local_11 = false;
    }
    bool inside = local_11;
    float half_ = in_.m0_.x;
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
        float _e115 = len2_(max((along - h), 0.0), across);
        float capsule = (_e115 - half_);
        float _e121 = box_dist(((along - h) - (half_ * square)), (across - half_));
        float d_3 = (round_ ? capsule : _e121);
        float period = in_.m1_.y;
        if ((period != 0.0)) {
            float at = (t_1 + in_.m0_.w);
            float m = (at - (floor((at / period)) * period));
            dash = min(max((min(m, (in_.m1_.x - m)) + 0.5), 0.0), 1.0);
        }
        float _e146 = coverage(d_3);
        float _e147 = dash;
        alpha = (_e146 * _e147);
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
            float _e174 = len2_(x_2, y_2);
            float ring = (abs((_e174 - radius_1)) - half_);
            float past = ((in_.m2_.z != 0.0) ? -1e30 : ((x_2 * ca) - (y_2 * sa)));
            float _e191 = len2_((x_2 - (sa * radius_1)), (y_2 - (ca * radius_1)));
            float disc = (_e191 - half_);
            float flat_end = max(ring, (past - (half_ * square)));
            float _e200 = coverage((round_ ? ((past > 0.0) ? disc : ring) : flat_end));
            alpha = _e200;
        } else {
            if (!((kind == 1u))) {
                local_12 = (kind == 3u);
            } else {
                local_12 = true;
            }
            bool _e209 = local_12;
            if (_e209) {
                if ((kind == 1u)) {
                    float _e214 = rect_dist(px_2, py_2, in_);
                    d = _e214;
                } else {
                    float _e219 = polygon_dist(px_2, py_2, in_.k.z, in_.k.w);
                    d = _e219;
                }
                float _e220 = d;
                float _e222 = coverage((_e220 - hw));
                float _e223 = d;
                float _e225 = coverage((_e223 + hw));
                float on = ((1.0 - _e225) * in_.m2_.z);
                colour = (in_.base + ((in_.stroke - in_.base) * on));
                alpha = _e222;
            } else {
                float dx_1 = (px_2 - in_.p.x);
                float dy_1 = (py_2 - in_.p.y);
                float c_1 = in_.m1_.z;
                float s = in_.m1_.w;
                float lx_1 = ((c_1 * dx_1) + (s * dy_1));
                float ly_1 = ((c_1 * dy_1) - (s * dx_1));
                if ((lx_1 >= 0.0)) {
                    local_13 = (lx_1 < in_.p.z);
                } else {
                    local_13 = false;
                }
                bool _e261 = local_13;
                if (_e261) {
                    local_14 = (ly_1 >= 0.0);
                } else {
                    local_14 = false;
                }
                bool _e267 = local_14;
                if (_e267) {
                    local_15 = (ly_1 < in_.p.w);
                } else {
                    local_15 = false;
                }
                bool hit = local_15;
                vec2 n_1 = vec2(uvec2(textureSize(_group_1_binding_0_fs, 0).xy));
                float tu = (in_.uv.x + (lx_1 * in_.m3_.x));
                float tv = (in_.uv.y + (ly_1 * in_.m3_.y));
                uint tx = uint(min(max(floor((tu * n_1.x)), 0.0), (n_1.x - 1.0)));
                uint ty = uint(min(max(floor((tv * n_1.y)), 0.0), (n_1.y - 1.0)));
                vec4 _e314 = texelFetch(_group_1_binding_0_fs, ivec2(uvec2(tx, ty)), 0);
                colour = (in_.stroke * _e314);
                alpha = (hit ? 1.0 : 0.0);
            }
        }
    }
    float _e320 = colour.w;
    float _e321 = alpha;
    float _e324 = _group_0_binding_0_fs.opacity;
    float a = (clamp((_e320 * (_e321 * _e324)), 0.0, 1.0) * float(inside));
    vec4 _e332 = colour;
    _fs2p_location0 = vec4((clamp(_e332.xyz, vec3(0.0), vec3(1.0)) * a), a);
    return;
}

