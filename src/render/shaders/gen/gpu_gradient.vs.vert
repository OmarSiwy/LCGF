#version 300 es

precision highp float;
precision highp int;


void main() {
    uint i = uint(gl_VertexID);
    gl_Position = vec4(((float((i & 1u)) * 4.0) - 1.0), ((float((i >> 1u)) * 4.0) - 1.0), 0.0, 1.0);
    gl_Position.yz = vec2(-gl_Position.y, gl_Position.z * 2.0 - gl_Position.w);
    return;
}

