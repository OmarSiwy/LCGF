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
    uvec4 marks[512];
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
layout(std140) uniform Draw_block_0Vertex { Draw _group_0_binding_0_vs; };

layout(location = 0) in ivec4 _p2vs_location0;
layout(location = 1) in uvec4 _p2vs_location1;
layout(location = 2) in uint _p2vs_location2;
layout(location = 3) in uint _p2vs_location3;
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
        if ((_e5 < min(_e8, 512u))) {
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

vec2 screen(vec2 p_1) {
    float _e4 = _group_0_binding_0_vs.fwd.x;
    float _e10 = _group_0_binding_0_vs.fwd.z;
    float _e17 = _group_0_binding_0_vs.fwd_t.x;
    float _e22 = _group_0_binding_0_vs.fwd.y;
    float _e28 = _group_0_binding_0_vs.fwd.w;
    float _e35 = _group_0_binding_0_vs.fwd_t.y;
    return vec2((((_e4 * p_1.x) + (_e10 * p_1.y)) + _e17), (((_e22 * p_1.x) + (_e28 * p_1.y)) + _e35));
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

void main() {
    uint vi = uint(gl_VertexID);
    Row r = Row(_p2vs_location0, _p2vs_location1, _p2vs_location2, _p2vs_location3);
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
    float _e119 = _group_0_binding_0_vs.scale;
    radius = (float(r.look.y) * _e119);
    grow = (half_2 * float(stroked));
    if ((kind == 0u)) {
        grow = (half_2 * 1.4142135);
        float _e154 = _group_0_binding_0_vs.scale;
        chain = (float(r.look.y) * _e154);
        float _e160 = _group_0_binding_0_vs.px;
        float on_1 = ((2.0 * dash) * _e160);
        m1_ = vec4(on_1, (2.0 * on_1), 1.0, 0.0);
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
        float m_1 = (((start / 65536.0) * 6.2831855) + (sweep / 2.0));
        radius = rr;
        float _e227 = _group_0_binding_0_vs.scale;
        chain = (float(r.look.y) * _e227);
        float _e233 = _group_0_binding_0_vs.px;
        float on_2 = ((2.0 * dash) * _e233);
        m1_ = vec4(on_2, (2.0 * on_2), cos(m_1), sin(m_1));
        m3_ = vec4((sweep / 2.0), 0.0, 0.0, 0.0);
        m2_ = vec4(max(sin((sweep / 2.0)), 0.0), cos((sweep / 2.0)), float(((r.look.z >> 16u) == 65535u)), 0.0);
        p = vec4(corner.x, corner.y, 0.0, 0.0);
        float e = (rr + half_2);
        box = vec4(((corner.x - e) - 1.0), ((corner.y - e) - 1.0), ((corner.x + e) + 1.0), ((corner.y + e) + 1.0));
    } else {
        if ((kind == 4u)) {
            float _e294 = _group_0_binding_0_vs.scale;
            float gw = (float(uint(r.pos.z)) * _e294);
            float _e302 = _group_0_binding_0_vs.scale;
            float gh = (float(uint(r.pos.w)) * _e302);
            uint q_1 = ((h >> 16u) & 3u);
            float c_1[4] = float[4](1.0, 0.0, -1.0, 0.0);
            m1_ = vec4(0.0, 0.0, c_1[q_1], c_1[((q_1 + 3u) & 3u)]);
            p = vec4(corner.x, corner.y, gw, gh);
            float e_1 = max(gw, gh);
            box = vec4(((corner.x - e_1) - 1.0), ((corner.y - e_1) - 1.0), ((corner.x + e_1) + 1.0), ((corner.y + e_1) + 1.0));
            float _e345 = unorm16_(r.look.y);
            float _e350 = unorm16_((r.look.y >> 16u));
            out_.uv = vec2(_e345, _e350);
            float _e355 = unorm16_(r.look.z);
            float _e364 = unorm16_((r.look.z >> 16u));
            m3_ = vec4(((_e355 - _e345) / max(gw, 1e-6)), ((_e364 - _e350) / max(gh, 1e-6)), 0.0, 0.0);
        } else {
            float _e375 = grow;
            float _e382 = grow;
            float _e389 = grow;
            float _e396 = grow;
            box = vec4(((min(corner.x, corner.z) - _e375) - 1.0), ((min(corner.y, corner.w) - _e382) - 1.0), ((max(corner.x, corner.z) + _e389) + 1.0), ((max(corner.y, corner.w) + _e396) + 1.0));
        }
    }
    bool marked = (r.mark != 0u);
    uint _e407 = _group_0_binding_0_vs.row_base;
    uint _e410 = override_of((r.row - _e407), row.x);
    uint colour_2 = (marked ? r.mark : _e410);
    uint _e416 = _group_0_binding_0_vs.row_base;
    uint _e419 = override_of((r.row - _e416), row.y);
    uint fill = (marked ? r.mark : _e419);
    if (((h & 64u) != 0u)) {
        local_4 = ((row.w & 1u) != 0u);
    } else {
        local_4 = false;
    }
    bool filled = local_4;
    vec4 _e436 = rgba(colour_2);
    out_.stroke = _e436;
    vec4 _e439 = out_.stroke;
    vec4 _e443 = rgba(fill);
    out_.base = (filled ? _e443 : vec4(_e439.xyz, 0.0));
    vec4 _e446 = p;
    out_.p = _e446;
    float _e448 = radius;
    float _e452 = chain;
    out_.m0_ = vec4(half_2, _e448, float((cap == 1u)), _e452);
    vec4 _e455 = m1_;
    out_.m1_ = _e455;
    float _e458 = m2_.x;
    float _e460 = m2_.y;
    float _e463 = m2_.z;
    out_.m2_ = vec4(_e458, _e460, ((kind == 2u) ? _e463 : float(stroked)), (half_2 * float(stroked)));
    vec4 _e471 = m3_;
    out_.m3_ = _e471;
    out_.k = uvec4(kind, uint((cap == 2u)), r.look.y, r.look.z);
    vec4 _e481 = box;
    vec2 _e483 = screen(_e481.xy);
    vec4 _e484 = box;
    vec2 _e486 = screen(_e484.zy);
    vec4 _e487 = box;
    vec2 _e489 = screen(_e487.xw);
    vec4 _e490 = box;
    vec2 _e492 = screen(_e490.zw);
    vec2 lo = clamp(floor(min(min(_e483, _e486), min(_e489, _e492))), vec2(0.0), vec2(16777216.0));
    vec2 hi = clamp(ceil(max(max(_e483, _e486), max(_e489, _e492))), vec2(0.0), vec2(16777216.0));
    vec2 at_1 = mix(lo, hi, bvec2(((vi & 1u) != 0u), ((vi & 2u) != 0u)));
    vec2 _e524 = _group_0_binding_0_vs.size;
    out_.position = vec4((((at_1 / _e524) * vec2(2.0, -2.0)) + vec2(-1.0, 1.0)), 0.0, 1.0);
    Frag _e537 = out_;
    gl_Position = _e537.position;
    _vs2fs_location0 = _e537.p;
    _vs2fs_location1 = _e537.m0_;
    _vs2fs_location2 = _e537.m1_;
    _vs2fs_location3 = _e537.m2_;
    _vs2fs_location4 = _e537.m3_;
    _vs2fs_location5 = _e537.stroke;
    _vs2fs_location6 = _e537.base;
    _vs2fs_location7 = _e537.k;
    _vs2fs_location8 = _e537.uv;
    gl_Position.yz = vec2(-gl_Position.y, gl_Position.z * 2.0 - gl_Position.w);
    return;
}

