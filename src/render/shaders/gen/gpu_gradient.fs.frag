#version 300 es

precision highp float;
precision highp int;

layout(std140) uniform type_block_0Fragment { vec4 _group_0_binding_0_fs; };

layout(location = 0) out vec4 _fs2p_location0;

void main() {
    vec4 p = gl_FragCoord;
    float _e4 = _group_0_binding_0_fs.x;
    float _e11 = _group_0_binding_0_fs.y;
    _fs2p_location0 = vec4(((p.x / _e4) * 0.5), 0.25, ((p.y / _e11) * 0.6), 1.0);
    return;
}

