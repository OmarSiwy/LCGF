// A themed surface material: the fill, lit from above. The top of the quad is lifted toward white
// by `params.x` (an f32, 0 to 1) and the light falls off to the plain fill at the bottom, with a
// one-pixel highlight along the top edge. The fill comes from the theme, so the sheen follows a
// theme switch; quad.wgsl applies corners, border, clip and opacity around it.
fn material(in: Frag) -> vec4f {
    let strength = clamp(bitcast<f32>(in.params.x), 0.0, 1.0);
    let t = clamp(0.5 - in.local.y / max(2.0 * in.half.y, 1.0), 0.0, 1.0);
    let edge = select(0.0, 0.5, in.local.y < 1.0 - in.half.y);
    let lift = strength * (t * t + edge);
    let rgb = mix(in.fill.rgb, vec3f(in.fill.a), clamp(lift, 0.0, 1.0));
    return vec4f(rgb, in.fill.a);
}
