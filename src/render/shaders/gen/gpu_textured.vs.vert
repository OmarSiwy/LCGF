#version 300 es

precision highp float;
precision highp int;

struct Params {
    vec4 tint;
};
struct V {
    vec4 pos;
    vec2 uv;
};
layout(location = 0) in vec2 _p2vs_location0;
smooth out vec2 _vs2fs_location0;

void main() {
    vec2 at = _p2vs_location0;
    V _tmp_return = V(vec4(((at.x * 2.0) - 1.0), (1.0 - (at.y * 2.0)), 0.0, 1.0), at);
    gl_Position = _tmp_return.pos;
    _vs2fs_location0 = _tmp_return.uv;
    gl_Position.yz = vec2(-gl_Position.y, gl_Position.z * 2.0 - gl_Position.w);
    return;
}

