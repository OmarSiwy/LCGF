// lcgf_render.gpu's own compute test: every element of a storage buffer from its index.
@group(0) @binding(0) var<storage, read_write> out: array<u32>;
@group(0) @binding(1) var<uniform> base: vec4u;

@compute @workgroup_size(64)
fn main(@builtin(global_invocation_id) id: vec3u) {
    if (id.x < arrayLength(&out)) {
        out[id.x] = id.x * 3u + base.x;
    }
}
