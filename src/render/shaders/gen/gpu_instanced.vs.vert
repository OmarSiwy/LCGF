#version 300 es

precision highp float;
precision highp int;

struct V {
    vec4 pos;
    vec4 color;
};
layout(location = 0) in vec2 _p2vs_location0;
layout(location = 1) in ivec2 _p2vs_location1;
layout(location = 2) in uint _p2vs_location2;
layout(location = 3) in ivec4 _p2vs_location3;
flat out vec4 _vs2fs_location0;

void main() {
    vec2 corner = _p2vs_location0;
    ivec2 at = _p2vs_location1;
    uint rgba = _p2vs_location2;
    ivec4 check = _p2vs_location3;
    bool local = false;
    bool local_1 = false;
    bool local_2 = false;
    bool local_3 = false;
    int column = -(at.x);
    if ((at.y == column)) {
        local = (check.x == column);
    } else {
        local = false;
    }
    bool _e13 = local;
    if (_e13) {
        local_1 = (check.y == -(column));
    } else {
        local_1 = false;
    }
    bool _e20 = local_1;
    if (_e20) {
        local_2 = (check.z == (2 * column));
    } else {
        local_2 = false;
    }
    bool _e28 = local_2;
    if (_e28) {
        local_3 = (check.w == -7);
    } else {
        local_3 = false;
    }
    bool ok = local_3;
    float x = ((float(column) + corner.x) / 8.0);
    vec4 color = (ok ? (vec4(rgba & 0xFFu, rgba >> 8 & 0xFFu, rgba >> 16 & 0xFFu, rgba >> 24) / 255.0) : vec4(1.0, 0.0, 1.0, 1.0));
    V _tmp_return = V(vec4(((x * 2.0) - 1.0), (1.0 - (corner.y * 2.0)), 0.0, 1.0), color);
    gl_Position = _tmp_return.pos;
    _vs2fs_location0 = _tmp_return.color;
    gl_Position.yz = vec2(-gl_Position.y, gl_Position.z * 2.0 - gl_Position.w);
    return;
}

