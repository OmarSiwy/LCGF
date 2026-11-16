#version 450
// The goldens' host draw for a custom command (conformance/render.py `scene_pipe`): a gradient
// over the pixel position; the target size comes in as a push constant.
layout(push_constant) uniform Size { vec2 size; } pc;
layout(location = 0) out vec4 color;
void main() {
    vec2 p = gl_FragCoord.xy;
    color = vec4(p.x / pc.size.x * 0.5, 0.25, p.y / pc.size.y * 0.6, 1.0);
}
