#version 100
// quad.wgsl's fragment stage with the stock material by hand in GLSL ES 1.00 for the GL ES 2
// path (src/render/gles/es2.zig). Same formulas as src/render/shaders/gen/stock.frag for fill,
// rounded corners, border, texture (nearest texel centre), clip and opacity.
// ponytail: no `params` features (gradients, shadow, nine-slice, dashed and dotted borders):
// they read u32 bit patterns GLSL ES 1.00 cannot; add them by decoding params to floats in
// es2.zig `prepare` when an ES 2 device needs them.
precision highp float;

uniform vec4 u_globals; // viewport.xy, scale, pad
uniform sampler2D u_texture;
uniform vec2 u_texture_size;

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

float corner_radius(vec2 p, vec2 half_, vec4 radii) {
    float right = ((p.y > 0.0) ? radii.z : radii.y);
    float left = ((p.y > 0.0) ? radii.w : radii.x);
    return min(((p.x > 0.0) ? right : left), min(half_.x, half_.y));
}

float rounded_box(vec2 p, vec2 half_, float r) {
    vec2 q = ((abs(p) - half_) + vec2(r));
    return ((length(max(q, vec2(0.0))) + min(max(q.x, q.y), 0.0)) - r);
}

float floor_div(float num, float den) {
    float q = floor((num / den));
    return ((q + ((((q + 1.0) * den) <= num) ? 1.0 : 0.0)) - (((q * den) > num) ? 1.0 : 0.0));
}

float texel_centre(float pos, float size, float uv0, float uv1, float n) {
    float s = max(size, 1e-6);
    float a = (uv0 * n);
    float whole = floor(a);
    float k = whole + floor_div((((a - whole) * s) + (((uv1 - uv0) * n) * pos)), s);
    return ((clamp(k, 0.0, (n - 1.0)) + 0.5) / n);
}

void main() {
    vec2 local = v_local_half.xy;
    vec2 half_ = v_local_half.zw;
    vec2 pixel = v_pixel_border_opacity.xy;
    float border = v_pixel_border_opacity.z;
    float opacity = v_pixel_border_opacity.w;
    float scale = u_globals.z;
    float d = rounded_box(local, half_, corner_radius(local, half_, v_radii)) * scale;
    float shape = clamp((0.5 - d), 0.0, 1.0);
    float inner = clamp((0.5 - (d + (border * scale))), 0.0, 1.0);
    float has_border = step(0.001, border);
    float on_border = 1.0 - mix(1.0, inner, has_border);
    vec2 rect_pos = ((v_to_rect.xy * gl_FragCoord.x) + (v_to_rect.zw * gl_FragCoord.y)) + v_to_rect_off;
    vec2 size = half_ * 2.0;
    vec2 uv = vec2(texel_centre(rect_pos.x, size.x, v_uv_rect.x, v_uv_rect.z, u_texture_size.x),
                   texel_centre(rect_pos.y, size.y, v_uv_rect.y, v_uv_rect.w, u_texture_size.y));
    vec4 color = mix(v_fill * texture2D(u_texture, uv), v_border_color, on_border);
    vec2 inside = (step(v_clip.xy, pixel) * step(pixel, v_clip.zw));
    vec2 clip_centre = ((v_clip.xy + v_clip.zw) * 0.5);
    vec2 clip_half = ((v_clip.zw - v_clip.xy) * 0.5);
    vec2 to_clip = (pixel - clip_centre);
    float clip_d = rounded_box(to_clip, clip_half, corner_radius(to_clip, clip_half, v_clip_radii)) * scale;
    float rounded = (any(greaterThan(v_clip_radii, vec4(0.0))) ? clamp((0.5 - clip_d), 0.0, 1.0) : 1.0);
    float alpha = ((((shape * inside.x) * inside.y) * rounded) * opacity);
    gl_FragColor = (vec4((color.xyz * color.w), color.w) * alpha);
}
