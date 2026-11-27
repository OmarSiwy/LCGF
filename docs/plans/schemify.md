# Plan: what Schemify needs from LCGF

Schemify, an EDA schematic editor, is moving its GUI onto LCGF. Its owner wants every gap closed in LCGF, not worked around in Schemify. Its priorities, in order:
1. A schematic canvas that draws on the GPU back ends and on `sw` from one source.
2. Run-time theme values (sizes, fonts, radii, spacing, not only colours) in compiled pages.

It needs them in a few weeks. Sources: the research replies of 2026-11-26 (file:line evidence is kept below where it decides something).

## 1. The canvas

### What it draws
About 100,000 primitives per frame, at 120 fps while panning and zooming (Schemify budget D39):
- line segments with width and caps;
- rects;
- arcs;
- filled polygons;
- glyphs.

Coordinates are i32 milli-units, transformed by a camera. Output is premultiplied, clipped to the canvas node's rect, and identical on every back end, `sw` included (headless PNG export, pixel goldens in CI, machines without a GPU).

### Design: an LCGF-owned primitive batch, not quads and not a WGSL executor
- **Not a CPU executor for user WGSL** (Schemify's option a). That is a shader interpreter, out of place in Tier 0, and a restricted subset would drift from the real shaders.
- **Not one `Quad` per primitive** (the research's first sketch). A `Quad` is 136 bytes, so 100k is about 13.6 MB written and uploaded every frame, and a camera move would re-emit all of it.
- **Instead, a canvas batch.** The caller fills compact instance columns once, about 24 bytes per primitive. Panning and zooming change only a camera uniform. LCGF owns the shader, written once as `canvas.wgsl` and translated by naga to every GPU back end, and a Zig twin of it in `sw`. Goldens hold the two to the same pixels. This is the pattern `quad.wgsl` and `sw`'s shader loop already follow.

### Usage first (what a Schemify frame looks like)

```zig
// Once, or when the schematic changes: caller-owned, padded SoA columns (Tier 0, no allocator).
var shapes: lcgf.canvas.Instances = .init(&storage, 100_000);
const wire = shapes.segment(.{ 0, 0 }, .{ 25_400, 0 }, .{ .width = 150, .cap = .round, .color = net_color });
_ = shapes.rect(.{ -5_000, -2_500 }, .{ 5_000, 2_500 }, .{ .fill = body, .stroke = edge, .width = 200 });
_ = shapes.arc(.{ 0, 0 }, 1_270, .{ .start = 0, .sweep = std.math.pi, .width = 150, .color = edge });
_ = shapes.polygon(&.{ .{ 0, 0 }, .{ 1_000, 500 }, .{ 0, 1_000 } }, .{ .fill = pin });
_ = shapes.glyphs(run, .{ 2_000, 0 }, .{ .px = 1_270, .color = label });

// Every frame: one node, the camera, the ranges to draw (layers, selection on top).
const node = f.canvas(.from("schematic"), .{ .size = .{ .fill, .fill } }, &shapes, .{
    .camera = .{ .origin = view.origin, .scale = view.px_per_milli },
    .ranges = &.{ layers.wires, layers.symbols, layers.selection },
});
const r = f.interact(node, .{ .hover = true, .drag = true });   // pan, select: existing calls
```

- **Instance kinds:** `segment` (capsule SDF, butt/square/round caps), `rect` (fill, stroke, radius), `circle`, `arc` (ring sector with caps), `polygon` (an edge range in a side column; winding evaluated per pixel inside its box), `glyph` (an atlas sample, through the existing glyph atlas).
- **Coordinates:** `i32` milli-units. The camera takes an `i64` origin, so subtracting it on the host keeps f32 precision at any pan distance; the shader receives origin-relative i32 values plus scale and offset.
- **Draw list:** one new command kind, `canvas`, carrying the node rect and clip, the instance buffer reference, the camera and the ranges. It sorts and damages like a custom node; a camera change damages the node.
- **Hit testing:** `lcgf.canvas.hit(&shapes, camera, point) ?u32` uses the same SDFs on the CPU, so selection matches what is drawn. Optional: Schemify keeps its own object index.

### Schemify's answers (2026-11-26), which the layout follows
- **Width in screen logical px:** weight (1..4) × palette width of the layer, optionally × clamp(zoom, 0.5, 4); a world-unit width as an option.
- **Colour by palette:** an instance stores a layer index (u8, 40 layers) and style bits; a palette uniform holds colour, width and fill on/off per layer, so theme, hidden layers and highlight cost one uniform write.
- **Recolour and overlay by row:** a per-draw colour override table keyed by row range, and a second batch with its own ranges on top.
- **Incremental updates:** rows are killed in place and appended; the caller marks dirty row ranges, and only those upload.
- **Fill and stroke** of one closed shape on one layer, fills under strokes.
- **Polygons:** CSR chains of ≥2 points, simple, often non-convex, unbounded edge count, nonzero rule. Open polylines are chains of capped segments, no joins.
- **Dashes:** dash n in 0..15 is dashes and gaps of 2n logical px in screen space, restarting at each chain's first edge.
- **Glyphs:** from LCGF's shaper; size in world milli-units, rotation in quarter turns, anchored at a world point.

### Work packages, in order (each passes the gates; goldens at 0 bad pixels)

| WP | What | Where |
|---|---|---|
| C0 | GPU projection correctness the canvas depends on: GL ES `first_instance` emulated through the instance buffer offset (it is dropped silently in release builds today, `gles/gpu.zig:630-638`); `sint32x2`/`sint32x4` vertex formats; a `check.zig` case for instancing, instance-step buffers with offsets, first instance > 0 and integer attributes, run on every back end | `src/render/gpu/{desc,check}.zig`, the projections, `web/lcgf.js` |
| C1 | `lcgf.canvas.Instances` (Tier 0 columns and builders), `Camera`, `hit` | `src/draw/canvas.zig` |
| C2 | The `canvas` draw-list command and `Frame.canvas` | `src/draw/draw_list.zig`, `src/runtime/frame.zig` |
| C3 | `sw`: the Zig shader for every kind, culled per band, clipped to the node, threaded and damage-aware like the quad loop | `src/render/sw/canvas.zig` |
| C4 | `canvas.wgsl`, naga-translated (`src/render/shaders/translate.sh`), and an instanced pipeline in each GPU back end: vk, metal, d3d12, gles, wgpu, web | `src/render/shaders/`, each back end's renderer |
| C5 | A `canvas` golden scene (every kind, caps, clipping, camera, glyphs) at 0 bad pixels, sw against GPU; a 100k-primitive pan/zoom benchmark against the 120 fps budget, with workload and conditions | `tools/golden/draw.zig`, `tools/golden/ref/draw/`, `bench/` |

## 2. Run-time theme values in compiled pages

Today a comptime page folds the theme: the theme is a comptime parameter (`ComptimeUi(State, spec, theme)`), and only colours change at run time (`theme.recolor`, `src/theme/theme.zig:263`). Lengths are harder, because they feed measure and layout: they must enter when rows are pushed, and a theme change must force a relayout.

**Design (the research's option C).**
- **Spec:** a token index on the `Spec`.
- **Push:** writes the listed fields from a caller-owned `ThemeTable` of lengths, font sizes and colours.
- **Relayout:** a theme generation counter makes a changed table relayout the page.
- **Cost:** pages without tokens are unchanged, byte for byte.
- **Order:** the runtime front end gets it first, then comptime pages.

| WP | What |
|---|---|
| T-RT | `ThemeTable` and token fields on `Spec`/push, the theme generation in the dirty state; runtime front end |
| T-CT | The same in `ComptimeUi` |

## Landed (on `main`)

| What | Commits |
|---|---|
| C0: GL ES first instance, sint32x2/x4, instancing check (web and Metal too) | 386337b3, 41c86462, 6a84e326 |
| C1–C3: `lcgf.canvas` (palette layers, overrides, dirty ranges, chains and dashes, turned glyphs), `Frame.canvas`, sw | 0149d626..1ece7576 |
| C4: `canvas.wgsl`, one pipeline; vk, wgpu, gles, web, d3d12 at 0 bad pixels; metal cross-built only | a2b7c437, 6a71ab01, 83571bd1, 37c89e7d, 68c6b4b1, a656aee3, c59dee32 |
| C5 (sw): canvas golden scene, integer cull, 100k benchmark, per-frame tile bin (`sw.Setup.bins`) | 68b6ec7a..70481997, 7bb8710f, d3844a9e |
| T-RT, T-CT: run-time theme tokens on runtime and comptime pages | ac391ab0, dba544f2, aad15faf, de869134 |
| C4/C5 GPU: canvas golden in draw-golden on the GPU, vk benchmark (RTX 5060: 0.55 ms/frame for 100k at 1080p; pan uploads 160 B), batch placement fix | 1e06d82c..00b85934 |
| sw canvas: transform and rounded-clip parents, `Frame.reuse` (`enableCanvas` now takes 2 × customs rows), cheaper shading (71M instr/frame for 100k, 1 thread), golden through the bin, dashes on arcs | ea5ff09e, 58e13807, d42136f3, fdcd4a68, 2ae59430, b64b2381 |
| GPU transformed nodes, rounded clips, dashed arcs; address-free damage; comptime `CanvasRenderer` (apps without a canvas pay 0 B); caller-set limits in `Desc` (`canvas_batches` ≤32, `canvas_draws` ≤64, `canvas_overrides` ≤512) | d48e38d1, 90db0223, 8af3f1ea, 7b81d32c..403133d8 |
| Per-row mark colours for large selections: `Instances.init(…, .{ .marks = true })`, `mark(i, color)`; a mark beats a range override. **API change:** `Instances.init`/`requiredBytes` take an `Options` (`.{}` for none) | 2154cef9, b522005b |
| E2 several regions; per-row view state; E1 fit-sized regions | 1d39f356, fa569c09, 71f60ea2, 357f6c33, 83987184, d72829fc |
| **Re-pin here for your (1)+(2):** E1, a fit-sized region takes its content's size in the same frame and its clicks land in the final rect, in both frontends | cb47649c, 06c0e429; main 9e9a492b |
| census-src passes (0 lines over baseline); embedded flash at or below the earlier main | 93f62797 |
| Your report of 2026-11-27 on the software window, fixed at the root: a canvas under `trackDamage` draws its new camera, an application's images draw (`presentWith`, `lcgf_app.Image`), text samples the font, not white; a composed page's damage is the union of its sides', not the whole window (`ComptimeUi.recordDamage`) | 642d05ca, e97e7648, 367ce9a4 |
| X11 pacing at the display's refresh rate (120 Hz panels pace at 120 Hz); `Connection.overrideScale`; the screen's real size from RandR; the bitmap font's cells for bytes 32 to 255 (`Mono.encode`: ellipsis, middle dot, infinity); a 0-second timer fires on the next frame; the example host draws an application's own glyphs | 79faee36, 612c4550, 9265b3e1, d1292960, f2a99fe0, 39d61d19 |
| The window layer (docs/plans/window.md): `lcgf_app` on the GPU with `Surface`, real fonts at the window's scale, canvas labels over a distance atlas (`text.labels`) | 71cae28e, 644d4791, 3b22a4c4 |

**Next:** build LCGF with the default back end and run through `lcgf_app`, not `-Drender=sw` and a copy of `src/example/host.zig`; `lcgf_app` falls back to software by itself. Once Schemify confirms that path, `Incremental` and `src/example/window.zig` are deleted (stage 7 of docs/plans/window.md), which also brings an App hook for a draw list the application composed and canvas labels in real fonts through `lcgf_app`.

LCGF fixes bugs Schemify finds at the root, on `main`: send them to the LCGF session with the commit and a repro.
