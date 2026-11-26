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
layout(std140) uniform Draw_block_0Vertex { Draw _group_0_binding_0_vs; };

layout(location = 0) in ivec4 _p2vs_location0;
layout(location = 1) in uvec4 _p2vs_location1;
layout(location = 2) in uint _p2vs_location2;
flat out vec4 _vs2fs_location0;
flat out vec4 _vs2fs_location1;
flat out vec4 _vs2fs_location2;
flat out vec4 _vs2fs_location3;
flat out vec4 _vs2fs_location4;
flat out vec4 _vs2fs_location5;
flat out vec4 _vs2fs_location6;
flat out uvec4 _vs2fs_location7;
flat out vec2 _vs2fs_location8;

float wx(int w) {
    float _e4 = _group_0_binding_0_vs.base.x;
    int _e8 = _group_0_binding_0_vs.origin.x;
    float _e13 = _group_0_binding_0_vs.scale;
    return (_e4 + (float((w - _e8)) * _e13));
}

float wy(int w_1) {
    float _e4 = _group_0_binding_0_vs.base.y;
    int _e8 = _group_0_binding_0_vs.origin.y;
    float _e13 = _group_0_binding_0_vs.scale;
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
        uint _e8 = _group_0_binding_0_vs.overrides;
        if ((_e5 < min(_e8, 64u))) {
        } else {
            break;
        }
        {
            uint _e14 = j;
            uvec4 o = _group_0_binding_0_vs.marks[_e14];
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

void main() {
    uint vi = uint(gl_VertexID);
    Row r = Row(_p2vs_location0, _p2vs_location1, _p2vs_location2);
    Frag out_ = Frag(vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), vec4(0.0), uvec4(0u), vec2(0.0));
    bool local = false;
    bool local_1 = false;
    bool local_2 = false;
    bool local_3 = false;
    vec4 p = vec4(0.0);
    float radius = 0.0;
    float grow = 0.0;
    vec4 m1_ = vec4(0.0, 0.0, 1.0, 0.0);
    vec4 m2_ = vec4(0.0, 1.0, 0.0, 0.0);
    vec4 m3_ = vec4(0.0);
    float chain = 0.0;
    vec4 box = vec4(0.0);
    bool local_4 = false;
    uint h = r.look.x;
    uint layer = (h >> 24u);
    uvec4 row = _group_0_binding_0_vs.palette[min(layer, 255u)];
    out_.position = vec4(-2.0, -2.0, 0.0, 1.0);
    if (!(((h & 512u) != 0u))) {
        uint _e28 = _group_0_binding_0_vs.layers;
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
        gl_Position = _e42.position;
        _vs2fs_location0 = _e42.p;
        _vs2fs_location1 = _e42.m0_;
        _vs2fs_location2 = _e42.m1_;
        _vs2fs_location3 = _e42.m2_;
        _vs2fs_location4 = _e42.m3_;
        _vs2fs_location5 = _e42.stroke;
        _vs2fs_location6 = _e42.base;
        _vs2fs_location7 = _e42.k;
        _vs2fs_location8 = _e42.uv;
        gl_Position.yz = vec2(-gl_Position.y, gl_Position.z * 2.0 - gl_Position.w);
        return;
    }
    uint kind = (h & 15u);
    uint cap = ((h >> 4u) & 3u);
    float weight = float((((h >> 14u) & 3u) + 1u));
    float _e61 = _group_0_binding_0_vs.line;
    float _e68 = _group_0_binding_0_vs.scale;
    float width = (((h & 256u) != 0u) ? (float(r.look.w) * _e68) : ((weight * uintBitsToFloat(row.z)) * _e61));
    float _e77 = wx(r.pos.x);
    float _e80 = wy(r.pos.y);
    float _e83 = wx(r.pos.z);
    float _e86 = wy(r.pos.w);
    vec4 corner = vec4(_e77, _e80, _e83, _e86);
    float dash_1 = float(((h >> 10u) & 15u));
    float half_ = (width * 0.5);
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
    float _e119 = _group_0_binding_0_vs.scale;
    radius = (float(r.look.y) * _e119);
    grow = (half_ * float(stroked));
    if ((kind == 0u)) {
        grow = (half_ * 1.4142135);
        float _e154 = _group_0_binding_0_vs.scale;
        chain = (float(r.look.y) * _e154);
        float _e160 = _group_0_binding_0_vs.px;
        float on = ((2.0 * dash_1) * _e160);
        m1_ = vec4(on, (2.0 * on), 1.0, 0.0);
        float dx = (corner.z - corner.x);
        float dy = (corner.w - corner.y);
        float l = sqrt(((dx * dx) + (dy * dy)));
        float kk = (1.0 / max(l, 1e-6));
        m3_ = vec4(((l > 1e-6) ? (dx * kk) : 1.0), (dy * kk), (l * 0.5), 0.0);
    }
    if ((kind == 2u)) {
        float _e199 = _group_0_binding_0_vs.scale;
        float rr = (float(uint(r.pos.z)) * _e199);
        float start = float((r.look.z & 65535u));
        float sweep = ((float((r.look.z >> 16u)) / 65535.0) * 6.2831855);
        float m = (((start / 65536.0) * 6.2831855) + (sweep / 2.0));
        radius = rr;
        m1_ = vec4(0.0, 0.0, cos(m), sin(m));
        m2_ = vec4(max(sin((sweep / 2.0)), 0.0), cos((sweep / 2.0)), float(((r.look.z >> 16u) == 65535u)), 0.0);
        p = vec4(corner.x, corner.y, 0.0, 0.0);
        float e = (rr + half_);
        box = vec4(((corner.x - e) - 1.0), ((corner.y - e) - 1.0), ((corner.x + e) + 1.0), ((corner.y + e) + 1.0));
    } else {
        if ((kind == 4u)) {
            float _e275 = _group_0_binding_0_vs.scale;
            float gw = (float(uint(r.pos.z)) * _e275);
            float _e283 = _group_0_binding_0_vs.scale;
            float gh = (float(uint(r.pos.w)) * _e283);
            uint q = ((h >> 16u) & 3u);
            float c_1[4] = float[4](1.0, 0.0, -1.0, 0.0);
            m1_ = vec4(0.0, 0.0, c_1[q], c_1[((q + 3u) & 3u)]);
            p = vec4(corner.x, corner.y, gw, gh);
            float e_1 = max(gw, gh);
            box = vec4(((corner.x - e_1) - 1.0), ((corner.y - e_1) - 1.0), ((corner.x + e_1) + 1.0), ((corner.y + e_1) + 1.0));
            float _e326 = unorm16_(r.look.y);
            float _e331 = unorm16_((r.look.y >> 16u));
            out_.uv = vec2(_e326, _e331);
            float _e336 = unorm16_(r.look.z);
            float _e345 = unorm16_((r.look.z >> 16u));
            m3_ = vec4(((_e336 - _e326) / max(gw, 1e-6)), ((_e345 - _e331) / max(gh, 1e-6)), 0.0, 0.0);
        } else {
            float _e356 = grow;
            float _e363 = grow;
            float _e370 = grow;
            float _e377 = grow;
            box = vec4(((min(corner.x, corner.z) - _e356) - 1.0), ((min(corner.y, corner.w) - _e363) - 1.0), ((max(corner.x, corner.z) + _e370) + 1.0), ((max(corner.y, corner.w) + _e377) + 1.0));
        }
    }
    uint _e385 = _group_0_binding_0_vs.row_base;
    uint _e388 = override_of((r.row - _e385), row.x);
    uint _e392 = _group_0_binding_0_vs.row_base;
    uint _e395 = override_of((r.row - _e392), row.y);
    if (((h & 64u) != 0u)) {
        local_4 = ((row.w & 1u) != 0u);
    } else {
        local_4 = false;
    }
    bool filled = local_4;
    vec4 _e410 = rgba(_e388);
    out_.stroke = _e410;
    vec4 _e413 = out_.stroke;
    vec4 _e417 = rgba(_e395);
    out_.base = (filled ? _e417 : vec4(_e413.xyz, 0.0));
    vec4 _e420 = p;
    out_.p = _e420;
    float _e422 = radius;
    float _e426 = chain;
    out_.m0_ = vec4(half_, _e422, float((cap == 1u)), _e426);
    vec4 _e429 = m1_;
    out_.m1_ = _e429;
    float _e432 = m2_.x;
    float _e434 = m2_.y;
    float _e437 = m2_.z;
    out_.m2_ = vec4(_e432, _e434, ((kind == 2u) ? _e437 : float(stroked)), (half_ * float(stroked)));
    vec4 _e445 = m3_;
    out_.m3_ = _e445;
    out_.k = uvec4(kind, uint((cap == 2u)), r.look.y, r.look.z);
    vec4 _e455 = box;
    vec2 lo = clamp(floor(_e455.xy), vec2(0.0), vec2(16777216.0));
    vec4 _e463 = box;
    vec2 hi = clamp(ceil(_e463.zw), vec2(0.0), vec2(16777216.0));
    vec2 at = mix(lo, hi, bvec2(((vi & 1u) != 0u), ((vi & 2u) != 0u)));
    vec2 _e484 = _group_0_binding_0_vs.size;
    out_.position = vec4((((at / _e484) * vec2(2.0, -2.0)) + vec2(-1.0, 1.0)), 0.0, 1.0);
    Frag _e497 = out_;
    gl_Position = _e497.position;
    _vs2fs_location0 = _e497.p;
    _vs2fs_location1 = _e497.m0_;
    _vs2fs_location2 = _e497.m1_;
    _vs2fs_location3 = _e497.m2_;
    _vs2fs_location4 = _e497.m3_;
    _vs2fs_location5 = _e497.stroke;
    _vs2fs_location6 = _e497.base;
    _vs2fs_location7 = _e497.k;
    _vs2fs_location8 = _e497.uv;
    gl_Position.yz = vec2(-gl_Position.y, gl_Position.z * 2.0 - gl_Position.w);
    return;
}

