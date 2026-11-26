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
layout(std140) uniform Params_block_0Fragment { Params _group_0_binding_0_fs; };

uniform highp sampler2D _group_0_binding_1_fs;

smooth in vec2 _vs2fs_location0;
layout(location = 0) out vec4 _fs2p_location0;

void main() {
    V v = V(gl_FragCoord, _vs2fs_location0);
    vec4 _e4 = texture(_group_0_binding_1_fs, vec2(v.uv));
    vec4 _e7 = _group_0_binding_0_fs.tint;
    _fs2p_location0 = (_e4 * _e7);
    return;
}

