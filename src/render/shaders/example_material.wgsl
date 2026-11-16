// An example user material, also shipped as a variant so CI validates the user path: diagonal
// stripes of the fill and `params.y` (rgba8), `params.z` pixels wide (bit pattern of an f32).
fn material(in: Frag) -> vec4f {
    let width = max(bitcast<f32>(in.params.z), 1.0);
    let band = fract((in.local.x + in.local.y) / (2.0 * width));
    return select(in.fill, unpack4x8unorm(in.params.y), band > 0.5);
}
