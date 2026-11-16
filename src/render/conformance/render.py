"""Draw one conformance scene with a real wgpu device and write it as a PNG.

    python3 src/render/conformance/render.py DIR OUT.png      (nix develop .#golden)

DIR is one scene as conformance-dump wrote it. The drawing is tools/golden/gpu.py's (same
pipeline, bind groups, stand-in glyph atlas and host pipeline for custom draws) with the size
read from cmds.txt and without that script's checks, which are pixels of the prototype's frame.
"""
import struct, sys
from pathlib import Path
import wgpu
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "tools" / "golden"))
from golden import write_png

d, out_png = Path(sys.argv[1]), sys.argv[2]
lines = [l.split() for l in (d / "cmds.txt").read_text().splitlines()]
first = lambda key: [l for l in lines if l[0] == key][0]
W, H = int(first("size")[1]), int(first("size")[2])
stride = int(first("stride")[1])
attrs = [{"shader_location": int(l[1]), "offset": int(l[2]), "format": l[3]} for l in lines if l[0] == "attr"]

device = wgpu.gpu.request_adapter_sync().request_device_sync()
module = device.create_shader_module(code=(d / "quad.wgsl").read_text())
VF = wgpu.ShaderStage.VERTEX | wgpu.ShaderStage.FRAGMENT
bgl0 = device.create_bind_group_layout(entries=[{"binding": 0, "visibility": VF, "buffer": {"type": "uniform"}}])
bgl1 = device.create_bind_group_layout(entries=[
    {"binding": 0, "visibility": wgpu.ShaderStage.FRAGMENT, "texture": {"sample_type": "float", "view_dimension": "2d"}},
    {"binding": 1, "visibility": wgpu.ShaderStage.FRAGMENT, "sampler": {"type": "filtering"}}])
blend = {"src_factor": "one", "dst_factor": "one-minus-src-alpha", "operation": "add"}
pipeline = device.create_render_pipeline(
    layout=device.create_pipeline_layout(bind_group_layouts=[bgl0, bgl1]),
    vertex={"module": module, "entry_point": "vs",
            "buffers": [{"array_stride": stride, "step_mode": "instance", "attributes": attrs}]},
    primitive={"topology": "triangle-strip"},
    fragment={"module": module, "entry_point": "fs",
              "targets": [{"format": "rgba8unorm", "blend": {"color": blend, "alpha": blend}}]},
    multisample={"count": 1})

scene = device.create_shader_module(code=f"""
@vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {{
  return vec4f(f32(i & 1u) * 4.0 - 1.0, f32(i >> 1u) * 4.0 - 1.0, 0.0, 1.0); }}
@fragment fn fs(@builtin(position) p: vec4f) -> @location(0) vec4f {{
  return vec4f(p.x / {W}.0 * 0.5, 0.25, p.y / {H}.0 * 0.6, 1.0); }}""")
scene_pipe = device.create_render_pipeline(layout="auto",
    vertex={"module": scene, "entry_point": "vs", "buffers": []},
    primitive={"topology": "triangle-list"},
    fragment={"module": scene, "entry_point": "fs", "targets": [{"format": "rgba8unorm"}]})

def vbuf(data):
    b = device.create_buffer(size=max(len(data), stride), usage=wgpu.BufferUsage.VERTEX | wgpu.BufferUsage.COPY_DST)
    if data:
        device.queue.write_buffer(b, 0, data)
    return b
quad_buf, glyph_buf = vbuf((d / "quads.bin").read_bytes()), vbuf((d / "glyphs.bin").read_bytes())
globals_buf = device.create_buffer(size=16, usage=wgpu.BufferUsage.UNIFORM | wgpu.BufferUsage.COPY_DST)
device.queue.write_buffer(globals_buf, 0, struct.pack("<4f", W, H, 1.0, 0.0))
g0 = device.create_bind_group(layout=bgl0, entries=[{"binding": 0, "resource": {"buffer": globals_buf, "offset": 0, "size": 16}}])

def tex_group(w, h, data):
    t = device.create_texture(size=(w, h, 1), format="rgba8unorm", usage=wgpu.TextureUsage.TEXTURE_BINDING | wgpu.TextureUsage.COPY_DST)
    device.queue.write_texture({"texture": t}, data, {"bytes_per_row": w * 4, "rows_per_image": h}, (w, h, 1))
    s = device.create_sampler(mag_filter="nearest", min_filter="nearest")
    return device.create_bind_group(layout=bgl1, entries=[{"binding": 0, "resource": t.create_view()}, {"binding": 1, "resource": s}])
white = tex_group(1, 1, b"\xff\xff\xff\xff")
atlas = bytearray(64 * 64 * 4)
for byte in range(33, 127):
    cx, cy = byte & 15, byte >> 4
    for y in range(1, 4):
        for x in range(1, 3):
            o = ((cy * 4 + y) * 64 + cx * 4 + x) * 4
            atlas[o:o + 4] = b"\xff\xff\xff\xff"
atlas_group = tex_group(64, 64, bytes(atlas))

target = device.create_texture(size=(W, H, 1), format="rgba8unorm",
                               usage=wgpu.TextureUsage.RENDER_ATTACHMENT | wgpu.TextureUsage.COPY_SRC)
enc = device.create_command_encoder()
rp = enc.begin_render_pass(color_attachments=[{"view": target.create_view(), "clear_value": (0, 0, 0, 1), "load_op": "clear", "store_op": "store"}])
def bind(buf, group):
    rp.set_pipeline(pipeline); rp.set_bind_group(0, g0); rp.set_bind_group(1, group); rp.set_vertex_buffer(0, buf)
for l in lines:
    if l[0] == "quads":
        bind(quad_buf, white); rp.draw(4, int(l[2]), 0, int(l[1]))
    elif l[0] == "text":
        bind(glyph_buf, atlas_group); rp.draw(4, int(l[2]), 0, int(l[1]))
    elif l[0] == "custom":
        x0, y0, x1, y1 = [int(float(v)) for v in l[1:5]]
        rp.set_pipeline(scene_pipe); rp.set_scissor_rect(x0, y0, x1 - x0, y1 - y0); rp.draw(3, 1, 0, 0)
        rp.set_scissor_rect(0, 0, W, H)
rp.end()
device.queue.submit([enc.finish()])
px = bytes(device.queue.read_texture({"texture": target}, {"bytes_per_row": W * 4, "rows_per_image": H}, (W, H, 1)))
write_png(out_png, W, H, px)
print(f"rendered {d.name}: {W}x{H}")
