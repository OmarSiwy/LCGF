#version 300 es

precision highp float;
precision highp int;

struct V {
    vec4 pos;
    vec4 color;
};
flat in vec4 _vs2fs_location0;
layout(location = 0) out vec4 _fs2p_location0;

void main() {
    V v = V(gl_FragCoord, _vs2fs_location0);
    _fs2p_location0 = v.color;
    return;
}

