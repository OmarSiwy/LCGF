#version 450
// One triangle over the whole target (conformance/render.py `scene_pipe`, vertex stage).
void main() {
    gl_Position = vec4(float(gl_VertexIndex & 1) * 4.0 - 1.0, float(gl_VertexIndex >> 1) * 4.0 - 1.0, 0.0, 1.0);
}
