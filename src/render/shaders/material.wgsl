// The stock material: the fill (or its gradient) times the bound texture. quad.zig `shader`
// appends it to quad.wgsl; a user material is a function with the same signature.
fn material(in: Frag) -> vec4f {
    let uv = select(nearest_uv(in), nine_uv(in), in.params.x == k_nine);
    return gradient(in) * textureSample(tex, samp, uv);
}
