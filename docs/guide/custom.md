# Custom rendering

The UI never owns the GPU. You create the device, the queue, the render pass and the target;
the back end only creates its own buffers and pipelines from your device, and the frame reaches
it as a `DrawList` of three kinds of command: `quads` (one instanced draw of a batch sharing a
texture and material), `text` (a run's glyph quads) and `custom` (a rectangle you draw yourself).
Because you own the pass, raw GPU access needs no callback and no back-end hook.

Every code block below is a piece of `docs/guide/custom.zig`, which `zig build docs` compiles
and runs against `render_null.Null`, the back end that records the calls a GPU back end makes.
The contract and the three routes are written up in the header of `src/render/iface.zig`; the
wgpu back end's header (`src/render/wgpu/wgpu.zig`, from `prototype/ui_wgpu.zig`) lists the five
kinds of raw access below.

| Access | How |
|---|---|
| under / over | record your own draws into the pass before or after the UI's |
| inline | a `custom` node; stop the command loop at it and draw (`iface.drawUntilCustom`) |
| texture in | register your texture's view with the back end, then `Style.texture` on any node |
| texture out | point the pass at any texture view: the UI draws into your texture |
| materials | your WGSL fragment function in the quad shader, then `Style.material` |

## The frame

```zig
fn build(f: *Frame, video: types.Texture, stripes: types.Material) void {
    _ = f.open(.from("page"), .{ .dir = .x, .size = .{ .fill, .fill }, .gap = 8, .pad = @splat(8) });
    // Route 3: a texture you rendered, shown as an ordinary, rounded, clipped quad. The
    // fill multiplies it; a node with neither a fill nor a border colour paints nothing.
    _ = f.leaf(.from("video"), .{ .size = .{ .px(160), .px(90) }, .radius = 8, .fill = .white, .texture = video });
    // Route 2: a rect the host draws itself, in paint order; `data` says what.
    _ = f.custom(.from("3d"), .{ .size = .{ .fill, .fill } }, 7);
    // A material: your fragment function in the quad shader.
    _ = f.leaf(.from("busy"), .{ .size = .{ .px(40), .fill }, .fill = .rgb(40, 40, 60), .material = stripes });
    f.close();
}
```

## The pass

Upload first, while no pass is open, then walk the commands. `drawUntilCustom` draws up to the
next `custom` command and returns its index; you draw that one and continue after it:

```zig
gfx.prepare(queue, draw, .{}, in.viewport, 1); // uploads, before the pass begins
// Route 1, under: your draws here are behind the UI.
var i = lcgf.render_iface.drawUntilCustom(&gfx, pass, draw, 0);
while (i < draw.cmd_len) : (i = lcgf.render_iface.drawUntilCustom(&gfx, pass, draw, i + 1)) {
    const c = draw.customs[draw.command(i).custom];
    pass.push(.host); // your pipeline: scissor to c.clip, draw into c.rect
    scene.draws += 1;
    scene.rect = c.rect;
    scene.data = c.data;
}
// Route 1, over: your draws here are on top of the UI.
```

`c` is a `CustomDraw`: `rect` and `clip` in logical pixels, the `data` you passed to
`Frame.custom`, and the node's `id` and row. UI nodes painted after it cover your drawing and
earlier ones lie under it. If your draw needs an upload, do it before the pass, next to
`prepare`. With no custom commands, `iface.render` (or the back end's `render`) is the one-call
form.

Your draw may leave the pass in any state. Every back end sets the whole state it depends on
(pipeline, both bind groups, vertex buffer) on every `drawBatch` and `drawText`; the test checks
the recorded calls with `render_null.rebindsAfterHost`.

## Textures and materials

The wgpu back end is `render_wgpu.Renderer(binding)`, generic over a namespace of about a dozen
thin functions over your wgpu binding (`Binding` in `src/render/wgpu/wgpu.zig` lists them;
`src/render/wgpu/native.zig` is the one for wgpu-native). It gives out the handles:

- `addTexture(device, view, sampler)` returns a `Texture` for `Style.texture`. A texture you
  render in an earlier pass then becomes an ordinary quad: clipped, rounded, batched and layered
  like the rest. It costs a texture and a pass, and it is the only route whose output the UI can
  transform. `Style.uv` picks the part of the texture a quad shows.
- `addMaterial(device, wgsl)` returns a `Material` for `Style.material`. Build the source with
  `quad_shader.shader(fn_source)`, where `fn_source` is a WGSL `fn material(in: Frag) -> vec4f`:

```zig
const quad_shader = lcgf.quad_shader;
var materials: quad_shader.Materials = .{};
const stripes_wgsl = quad_shader.shader(quad_shader.example_material);
```

```zig
const stripes = materials.add(stripes_wgsl); // a wgpu host calls `Renderer.addMaterial(device, stripes_wgsl)`
```

Inside `material`, `in.params` carries the node's `Style.params`, `in.local` is the pixel offset
from the quad's centre and `in.half` its half size, both in logical pixels, and the quad shader's
helpers (`gradient`, `nine_uv`, `nearest_uv`, `rounded_box`, `tex`, `samp`, `globals`) are in
scope. `src/render/shaders/example_material.wgsl` (diagonal stripes) is the example used here;
`ci/run.sh shaders` validates it with the stock shader on a real wgpu device. A back end holds at
most `quad_shader.max_materials` (16) materials, the stock one included.

The other GPU back ends under `src/render/` take the same `DrawList` and follow the same
contract (`src/render/iface.zig`).
