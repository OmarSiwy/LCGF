"""GPU pixel check: draw a dumped frame with a real wgpu device (software adapter in CI), using
the shader text and instance layout exactly as the Zig code declares them, read the pixels back,
check eight of them and write the frame as a PNG for tools/golden/golden.py.

    python3 tools/golden/gpu.py DIR OUT.png

DIR holds what a dump tool wrote (tools/golden/dump.zig for the toolbar scene): quad.wgsl, quads.bin, glyphs.bin,
cmds.txt, and the textures the frame samples: a `texture ID W H FILE` line in cmds.txt per
RGBA8 file in DIR, bound as texture ID. Texture 0 is white; an id with no file, and every text
run, gets the stand-in glyph atlas below. Ported from prototype/render.py; the drawing and the
checks are unchanged.

A `canvas` line (tools/golden/draw.zig `canvasScene`) draws canvas.bin and verts.bin with
canvas.wgsl as src/render/gpu/canvas.zig does: rows from two instance buffers, a third of row
indices and a fourth of marks (marks.bin, or zeros), the uniforms of src/render/shaders/canvas.zig `Uniforms`, one draw per `range`.
"""
import math, struct, sys
from pathlib import Path
import wgpu

def pick_adapter():
    """The adapter LCGF_WGPU_ADAPTER names (a substring of its device name), else the first
    Vulkan one (lavapipe in the dev shells), else wgpu's default: a host's own GPU and its
    OpenGL adapter are never picked by accident."""
    import os
    adapters = wgpu.gpu.enumerate_adapters_sync()
    want = os.environ.get("LCGF_WGPU_ADAPTER")
    for a in adapters:
        if want and want in a.info["device"]:
            return a
    if want:
        sys.exit(f"no wgpu adapter matches LCGF_WGPU_ADAPTER={want!r}")
    for a in adapters:
        if a.info["backend_type"] == "Vulkan":
            return a
    return wgpu.gpu.request_adapter_sync()

from golden import write_png

d, out_png = Path(sys.argv[1]), sys.argv[2]
W, H = 800, 600
wgsl = (d / "quad.wgsl").read_text()
quads = (d / "quads.bin").read_bytes()
glyphs = (d / "glyphs.bin").read_bytes()
lines = [l.split() for l in (d / "cmds.txt").read_text().splitlines()]
stride = int([l for l in lines if l[0] == "stride"][0][1])
attrs = [{"shader_location": int(l[1]), "offset": int(l[2]), "format": l[3]} for l in lines if l[0] == "attr"]

adapter = pick_adapter()
device = adapter.request_device_sync()
print("adapter:", adapter.info["device"], adapter.info["backend_type"])

module = device.create_shader_module(code=wgsl)   # naga validates the WGSL here
VF = wgpu.ShaderStage.VERTEX | wgpu.ShaderStage.FRAGMENT
bgl0 = device.create_bind_group_layout(entries=[{"binding": 0, "visibility": VF, "buffer": {"type": "uniform"}}])
bgl1 = device.create_bind_group_layout(entries=[
    {"binding": 0, "visibility": wgpu.ShaderStage.FRAGMENT, "texture": {"sample_type": "float", "view_dimension": "2d"}},
    {"binding": 1, "visibility": wgpu.ShaderStage.FRAGMENT, "sampler": {"type": "filtering"}}])
layout = device.create_pipeline_layout(bind_group_layouts=[bgl0, bgl1])
blend = {"src_factor": "one", "dst_factor": "one-minus-src-alpha", "operation": "add"}
pipeline = device.create_render_pipeline(
    layout=layout,
    vertex={"module": module, "entry_point": "vs",
            "buffers": [{"array_stride": stride, "step_mode": "instance", "attributes": attrs}]},
    primitive={"topology": "triangle-strip"},
    fragment={"module": module, "entry_point": "fs",
              "targets": [{"format": "rgba8unorm", "blend": {"color": blend, "alpha": blend}}]},
    multisample={"count": 1})

# The host's own pipeline for the custom draw: a gradient, scissored to the rect the UI reserved.
scene = device.create_shader_module(code="""
@vertex fn vs(@builtin(vertex_index) i: u32) -> @builtin(position) vec4f {
  return vec4f(f32(i & 1u) * 4.0 - 1.0, f32(i >> 1u) * 4.0 - 1.0, 0.0, 1.0); }
@fragment fn fs(@builtin(position) p: vec4f) -> @location(0) vec4f {
  return vec4f(p.x / 800.0 * 0.5, 0.25, p.y / 600.0 * 0.6, 1.0); }""")
scene_pipe = device.create_render_pipeline(layout="auto",
    vertex={"module": scene, "entry_point": "vs", "buffers": []},
    primitive={"topology": "triangle-list"},
    fragment={"module": scene, "entry_point": "fs", "targets": [{"format": "rgba8unorm"}]})

def vbuf(data):
    b = device.create_buffer(size=max(len(data), stride), usage=wgpu.BufferUsage.VERTEX | wgpu.BufferUsage.COPY_DST)
    device.queue.write_buffer(b, 0, data)
    return b
quad_buf, glyph_buf = vbuf(quads), vbuf(glyphs)
globals_buf = device.create_buffer(size=16, usage=wgpu.BufferUsage.UNIFORM | wgpu.BufferUsage.COPY_DST)
device.queue.write_buffer(globals_buf, 0, struct.pack("<4f", W, H, 1.0, 0.0))
g0 = device.create_bind_group(layout=bgl0, entries=[{"binding": 0, "resource": {"buffer": globals_buf, "offset": 0, "size": 16}}])

def tex_group(w, h, data):
    t = device.create_texture(size=(w, h, 1), format="rgba8unorm", usage=wgpu.TextureUsage.TEXTURE_BINDING | wgpu.TextureUsage.COPY_DST)
    device.queue.write_texture({"texture": t}, data, {"bytes_per_row": w * 4, "rows_per_image": h}, (w, h, 1))
    s = device.create_sampler(mag_filter="nearest", min_filter="nearest")
    return device.create_bind_group(layout=bgl1, entries=[{"binding": 0, "resource": t.create_view()}, {"binding": 1, "resource": s}])
white = tex_group(1, 1, b"\xff\xff\xff\xff")
# Stand-in atlas, 16x16 cells of 4x4 texels: every printable byte is a small block.
atlas = bytearray(64 * 64 * 4)
for byte in range(33, 127):
    cx, cy = byte & 15, byte >> 4
    for y in range(1, 4):
        for x in range(1, 3):
            o = ((cy * 4 + y) * 64 + cx * 4 + x) * 4
            atlas[o:o + 4] = b"\xff\xff\xff\xff"
atlas_group = tex_group(64, 64, bytes(atlas))
groups = {0: white}
for l in lines:
    if l[0] == "texture":
        groups[int(l[1])] = tex_group(int(l[2]), int(l[3]), (d / l[4]).read_bytes())

target = device.create_texture(size=(W, H, 1), format="rgba8unorm",
                               usage=wgpu.TextureUsage.RENDER_ATTACHMENT | wgpu.TextureUsage.COPY_SRC)
enc = device.create_command_encoder()
rp = enc.begin_render_pass(color_attachments=[{"view": target.create_view(), "clear_value": (0.05, 0.05, 0.06, 1), "load_op": "clear", "store_op": "store"}])
draws = 0
def bind(buf, group):                       # what Renderer.bind does
    rp.set_pipeline(pipeline); rp.set_bind_group(0, g0); rp.set_bind_group(1, group); rp.set_vertex_buffer(0, buf)
for l in lines:
    if l[0] == "quads":
        bind(quad_buf, groups.get(int(l[3]), atlas_group)); rp.draw(4, int(l[2]), 0, int(l[1])); draws += 1
    elif l[0] == "text":
        bind(glyph_buf, atlas_group); rp.draw(4, int(l[2]), 0, int(l[1])); draws += 1
    elif l[0] == "custom":                 # inline custom draw: host pipeline, left in whatever state
        x0, y0, x1, y1 = [int(float(v)) for v in l[1:5]]
        rp.set_pipeline(scene_pipe); rp.set_scissor_rect(x0, y0, x1 - x0, y1 - y0); rp.draw(3, 1, 0, 0)
        rp.set_scissor_rect(0, 0, W, H)
def f32(x): return struct.unpack("<f", struct.pack("<f", x))[0]
if any(l[0] == "canvas" for l in lines):
    zoom_scale = int([l for l in lines if l[0] == "palette"][0][1])
    layers = [l[1:] for l in lines if l[0] == "layer"]
    # One command per `canvas` line, with the camera, range and override lines after it.
    cmds = []
    for l in lines:
        if l[0] == "canvas":
            node = [float(v) for v in l[1:]] + [1, 0, 0, 1, 0, 0, 0, 0, 0, 0][len(l) - 10:]
            cmds.append({"node": node, "ranges": [], "marks": []})
        elif l[0] == "camera": cmds[-1]["cam"] = l[1:]
        elif l[0] == "range": cmds[-1]["ranges"].append((int(l[1]), int(l[2])))
        elif l[0] == "override": cmds[-1]["marks"].append((int(l[1]), int(l[2]), int(l[3])))
    rows = (d / "canvas.bin").read_bytes()
    verts = (d / "verts.bin").read_bytes()
    n = len(rows) // 32
    pos = b"".join(rows[i * 32:i * 32 + 16] for i in range(n))
    look = b"".join(rows[i * 32 + 16:i * 32 + 32] for i in range(n))
    cmod = device.create_shader_module(code=(d / "canvas.wgsl").read_text())
    F = wgpu.ShaderStage.FRAGMENT
    cbgl0 = device.create_bind_group_layout(entries=[
        {"binding": 0, "visibility": VF, "buffer": {"type": "uniform"}},
        {"binding": 1, "visibility": F, "buffer": {"type": "read-only-storage"}}])
    cbgl1 = device.create_bind_group_layout(entries=[{"binding": 0, "visibility": F, "texture": {"sample_type": "float", "view_dimension": "2d"}}])
    cpipe = device.create_render_pipeline(
        layout=device.create_pipeline_layout(bind_group_layouts=[cbgl0, cbgl1]),
        vertex={"module": cmod, "entry_point": "vs", "buffers": [
            {"array_stride": 16, "step_mode": "instance", "attributes": [{"shader_location": 0, "offset": 0, "format": "sint32x4"}]},
            {"array_stride": 16, "step_mode": "instance", "attributes": [{"shader_location": 1, "offset": 0, "format": "uint32x4"}]},
            {"array_stride": 4, "step_mode": "instance", "attributes": [{"shader_location": 2, "offset": 0, "format": "uint32"}]},
            {"array_stride": 4, "step_mode": "instance", "attributes": [{"shader_location": 3, "offset": 0, "format": "uint32"}]}]},
        primitive={"topology": "triangle-strip"},
        fragment={"module": cmod, "entry_point": "fs", "targets": [{"format": "rgba8unorm", "blend": {"color": blend, "alpha": blend}}]})
    def buf(data, usage):
        b = device.create_buffer(size=max(len(data), 16), usage=usage | wgpu.BufferUsage.COPY_DST)
        device.queue.write_buffer(b, 0, data)
        return b
    V = wgpu.BufferUsage.VERTEX
    pos_buf, look_buf = buf(pos, V), buf(look, V)
    row_buf = buf(struct.pack(f"<{n}I", *range(n)), V)
    marks_path = d / "marks.bin"
    mark_buf = buf(marks_path.read_bytes() if marks_path.exists() else bytes(4 * n), V)
    vert_buf = buf(verts, wgpu.BufferUsage.STORAGE)
    at_tex = device.create_texture(size=(64, 64, 1), format="rgba8unorm", usage=wgpu.TextureUsage.TEXTURE_BINDING | wgpu.TextureUsage.COPY_DST)
    device.queue.write_texture({"texture": at_tex}, bytes(atlas), {"bytes_per_row": 256, "rows_per_image": 64}, (64, 64, 1))
    cg1 = device.create_bind_group(layout=cbgl1, entries=[{"binding": 0, "resource": at_tex.create_view()}])
    for c in cmds:
        node, cam, marks = c["node"], c["cam"], c["marks"]
        # canvas.zig `View.of` at scale 1, then shaders/canvas.zig `fill` (`Uniforms`).
        origin = [int(cam[0]) & 0xffffffff, int(cam[1]) & 0xffffffff]
        scale, ox, oy, zoom = f32(float(cam[2])), float(cam[3]), float(cam[4]), float(cam[5])
        line = f32(min(max(zoom, 0.5), 4)) if zoom_scale else 1.0
        a, b, cc, dd, tx, ty = [f32(v) for v in node[9:15]]
        det = f32(f32(a * dd) - f32(b * cc))
        if det == 0: continue
        inv = [f32(dd / det), f32(-b / det), f32(-cc / det), f32(a / det)]
        inv_t = [f32(f32(-f32(f32(dd * tx) - f32(cc * ty))) / det), f32(f32(-f32(f32(a * ty) - f32(b * tx))) / det)]
        radii = node[15:19]
        clip = node[4:8]
        u = struct.pack("<2I2f3fI", origin[0], origin[1], f32(node[0] + ox), f32(node[1] + oy), scale, line, 1.0, zoom_scale)
        u += struct.pack("<4f4f2ff5I", *node[0:4], *clip, W, H, node[8], 0, 0, len(verts) // 8, len(marks), len(layers))
        u += struct.pack("<4f2f2f4f4f4f2fII", *inv, *inv_t, tx, ty, a, b, cc, dd, *radii,
                         f32(f32(clip[0] + clip[2]) * 0.5), f32(f32(clip[1] + clip[3]) * 0.5), f32(f32(clip[2] - clip[0]) * 0.5), f32(f32(clip[3] - clip[1]) * 0.5),
                         1.0, 1.0, int(any(r > 0 for r in radii)), 0)
        pal = b"".join(struct.pack("<IIfI", int(l[0]), int(l[1]), float(l[2]), int(l[3])) for l in layers)
        u += pal + bytes(16 * (256 - len(layers)))
        u += b"".join(struct.pack("<4I", x, y, z, 0) for x, y, z in marks) + bytes(16 * (512 - len(marks)))
        uni = buf(u, wgpu.BufferUsage.UNIFORM)
        cg0 = device.create_bind_group(layout=cbgl0, entries=[{"binding": 0, "resource": {"buffer": uni, "offset": 0, "size": len(u)}},
                                                              {"binding": 1, "resource": {"buffer": vert_buf, "offset": 0, "size": vert_buf.size}}])
        # gpu.scissor of the node's screen bounds (a pixel wider when turned) and its clip.
        xs = [a * x + cc * y + tx for x in (node[0], node[2]) for y in (node[1], node[3])]
        ys = [b * x + dd * y + ty for x in (node[0], node[2]) for y in (node[1], node[3])]
        e = 0 if node[9:15] == [1, 0, 0, 1, 0, 0] else 1
        x0, y0 = max(0, math.floor(max(min(xs) - e, clip[0]))), max(0, math.floor(max(min(ys) - e, clip[1])))
        x1, y1 = min(W, math.ceil(min(max(xs) + e, clip[2]))), min(H, math.ceil(min(max(ys) + e, clip[3])))
        if x1 <= x0 or y1 <= y0: continue
        rp.set_scissor_rect(x0, y0, x1 - x0, y1 - y0)
        rp.set_pipeline(cpipe); rp.set_bind_group(0, cg0); rp.set_bind_group(1, cg1)
        for slot, bb in enumerate((pos_buf, look_buf, row_buf, mark_buf)): rp.set_vertex_buffer(slot, bb)
        for first, count in c["ranges"]:
            rp.draw(4, count, 0, first); draws += 1
rp.end()
device.queue.submit([enc.finish()])
px = bytes(device.queue.read_texture({"texture": target}, {"bytes_per_row": W * 4, "rows_per_image": H}, (W, H, 1)))
def at(x, y): return tuple(px[(y * W + x) * 4:(y * W + x) * 4 + 3])

write_png(out_png, W, H, px)

if not any(l[0] == "reset" for l in lines): sys.exit(0)  # not the prototype scene: no fixed pixel checks
reset = [float(v) for v in [l for l in lines if l[0] == "reset"][0][1:]]
checks = {
    "toolbar panel":            (at(400, 4), (30, 31, 36)),
    "button, hovered":          (at(int(reset[0]) + 3, int((reset[1] + reset[3]) / 2)), (74, 77, 90)),
    "button corner is rounded": (at(int(reset[0]), int(reset[1])), (30, 31, 36)),
    "sidebar panel":            (at(80, 500), (30, 31, 36)),
    "custom draw (host pipeline)": (at(700, 500), (int(700.5 / 800 * 0.5 * 255 + .5), 64, int(500.5 / 600 * 0.6 * 255 + .5))),
    "overlay border":           (at(184 + 110, 74 + 1), (90, 140, 255)),
    "bar inside overlay":       (at(184 + 100, 74 + 60), (200, 90, 60)),
    "bar clipped at overlay edge": (at(184 + 230, 74 + 60), None),
}
ok = True
for name, (got, want) in checks.items():
    if want is None:
        good = got != (200, 90, 60)
    else:
        good = all(abs(a - b) <= 2 for a, b in zip(got, want))
    ok &= good
    print(f"{'ok  ' if good else 'FAIL'} {name:30s} got {got} want {want}")
print("draw calls:", draws)
sys.exit(0 if ok else 1)
