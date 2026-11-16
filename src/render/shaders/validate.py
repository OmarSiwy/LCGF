"""Validate every dumped shader variant on a real wgpu device (software adapter in CI):

    python3 src/render/shaders/validate.py DIR

DIR is what `shaders-dump` wrote. For each <variant>.wgsl, naga parses and validates the module
(create_shader_module) and wgpu builds the quad render pipeline with the instance layout from
layout.txt, which checks that the shader's inputs match `quad.attrs`. Any error raises and exits
non-zero. The bind group layouts and blend state are tools/golden/gpu.py's.
"""
import sys
from pathlib import Path
import wgpu

d = Path(sys.argv[1])
lines = [l.split() for l in (d / "layout.txt").read_text().splitlines()]
stride = int([l for l in lines if l[0] == "stride"][0][1])
attrs = [{"shader_location": int(l[1]), "offset": int(l[2]), "format": l[3]} for l in lines if l[0] == "attr"]

device = wgpu.gpu.request_adapter_sync().request_device_sync()
VF = wgpu.ShaderStage.VERTEX | wgpu.ShaderStage.FRAGMENT
bgl0 = device.create_bind_group_layout(entries=[{"binding": 0, "visibility": VF, "buffer": {"type": "uniform"}}])
bgl1 = device.create_bind_group_layout(entries=[
    {"binding": 0, "visibility": wgpu.ShaderStage.FRAGMENT, "texture": {"sample_type": "float", "view_dimension": "2d"}},
    {"binding": 1, "visibility": wgpu.ShaderStage.FRAGMENT, "sampler": {"type": "filtering"}}])
layout = device.create_pipeline_layout(bind_group_layouts=[bgl0, bgl1])
blend = {"src_factor": "one", "dst_factor": "one-minus-src-alpha", "operation": "add"}

variants = sorted(d.glob("*.wgsl"))
assert variants, f"no variants in {d}"
for f in variants:
    module = device.create_shader_module(code=f.read_text())
    device.create_render_pipeline(
        layout=layout,
        vertex={"module": module, "entry_point": "vs",
                "buffers": [{"array_stride": stride, "step_mode": "instance", "attributes": attrs}]},
        primitive={"topology": "triangle-strip"},
        fragment={"module": module, "entry_point": "fs",
                  "targets": [{"format": "rgba8unorm", "blend": {"color": blend, "alpha": blend}}]})
    print(f"ok   {f.name}")
print(f"{len(variants)} shader variants valid")
