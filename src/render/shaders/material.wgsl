// The stock material: the fill (or its gradient) times the bound texture, or a ramp's colour. quad.zig `shader`
// appends it to quad.wgsl; a user material is a function with the same signature.
// The branches test per-instance values (quad.wgsl `fs`); the sample comes after them, in
// uniform control flow.
fn material(in: Frag) -> vec4f {
    var uv: vec2f;
    if (in.params.x == k_nine) {
        uv = nine_uv(in);
    } else {
        uv = nearest_uv(in);
    }
    var color = in.fill;
    if (in.params.x == k_linear || in.params.x == k_radial) {
        color = gradient(in);
    }
    let sampled = color * textureSample(tex, samp, uv);
    if (in.params.x == k_ramp) {
        return ramp(in);
    }
    return sampled;
}
