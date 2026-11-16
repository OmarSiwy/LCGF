#version 100
// quad.wgsl's vertex stage by hand in GLSL ES 1.00 for the GL ES 2 path (src/render/gles/es2.zig):
// naga writes no GLSL ES below 3.00. Same formulas as src/render/shaders/gen/stock.vert, with the
// quad expanded on the CPU (one vertex per corner, `a_corner`) instead of instanced, and without
// `params` (no integer attributes in GLSL ES 1.00): shadows draw unexpanded.
precision highp float;

uniform vec4 u_globals; // viewport.xy, scale, pad

attribute vec4 a_rect;
attribute vec4 a_clip;
attribute vec4 a_uv;
attribute vec4 a_fill;
attribute vec4 a_border_color;
attribute vec4 a_radii;
attribute float a_border;
attribute float a_opacity;
attribute vec4 a_xform;
attribute vec2 a_xform_t;
attribute vec4 a_clip_radii;
attribute vec2 a_corner;

varying vec4 v_local_half;
varying vec4 v_pixel_border_opacity;
varying vec4 v_radii;
varying vec4 v_fill;
varying vec4 v_border_color;
varying vec4 v_clip;
varying vec4 v_uv_rect;
varying vec4 v_clip_radii;
varying vec4 v_to_rect;
varying vec2 v_to_rect_off;

void main() {
    vec2 p = mix(a_rect.xy, a_rect.zw, a_corner);
    vec2 screen = ((a_xform.xy * p.x) + (a_xform.zw * p.y)) + a_xform_t;
    vec2 ndc = ((screen / u_globals.xy) * vec2(2.0, -2.0)) + vec2(-1.0, 1.0);
    // naga's flip: rows count from the top in GL window space, as in the GLSL ES 3.0 variant.
    gl_Position = vec4(ndc.x, -ndc.y, -1.0, 1.0);
    v_local_half = vec4(p - ((a_rect.xy + a_rect.zw) * 0.5), (a_rect.zw - a_rect.xy) * 0.5);
    v_pixel_border_opacity = vec4(screen, a_border, a_opacity);
    v_radii = a_radii;
    v_fill = a_fill;
    v_border_color = a_border_color;
    v_clip = a_clip;
    v_uv_rect = a_uv;
    v_clip_radii = a_clip_radii;
    float scale = u_globals.z;
    float k = 1.0 / (((a_xform.x * a_xform.w) - (a_xform.y * a_xform.z)) * scale);
    v_to_rect = vec4(a_xform.w * k, -(a_xform.y) * k, -(a_xform.z) * k, a_xform.x * k);
    v_to_rect_off = -((v_to_rect.xy * (a_xform_t.x * scale)) + (v_to_rect.zw * (a_xform_t.y * scale))) - a_rect.xy;
}
