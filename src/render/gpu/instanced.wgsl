// lcgf_render.gpu's own instancing test: per-instance data from two instance-step buffers, one
// bound at an offset, in integer formats, drawn from a first instance past 0. Each instance
// fills one pixel column of an 8 x 1 target. It reads no @builtin(instance_index), so GL ES can
// emulate the first instance by offsetting the buffers.
struct V { @builtin(position) pos: vec4f, @location(0) @interpolate(flat) color: vec4f };

@vertex
fn vs(@location(0) corner: vec2f, @location(1) at: vec2i, @location(2) rgba: u32, @location(3) check: vec4i) -> V {
    // `at` is (-column, column); `check` is (column, -column, 2 * column, -7). Anything else is
    // magenta, so a wrong sign, offset or instance shows.
    let column = -at.x;
    let ok = at.y == column && check.x == column && check.y == -column && check.z == 2 * column && check.w == -7;
    let x = (f32(column) + corner.x) / 8.0;
    let color = select(vec4f(1.0, 0.0, 1.0, 1.0), unpack4x8unorm(rgba), ok);
    return V(vec4f(x * 2.0 - 1.0, 1.0 - corner.y * 2.0, 0.0, 1.0), color);
}

@fragment
fn fs(v: V) -> @location(0) vec4f {
    return v.color;
}
