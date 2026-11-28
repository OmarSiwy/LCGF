# Plan: what Schemify needs from LCGF

Schemify, an EDA schematic editor, is moving its GUI onto LCGF. Its owner wants every gap closed in LCGF, not worked around in Schemify. Its priorities, in order:
1. A schematic canvas that draws on the GPU back ends and on `sw` from one source.
2. Run-time theme values (sizes, fonts, radii, spacing, not only colours) in compiled pages.

It needs them in a few weeks. Sources: the research replies of 2026-11-26 (file:line evidence is kept below where it decides something).

## 1. The canvas

`lcgf.canvas` (src/draw/canvas.zig) draws many 2D primitives from caller-owned columns under a camera. A schematic, a plot or a map fills `Instances` once, or when it changes. Every frame, `Frame.canvas` puts one node in the tree with a `Camera`, an optional `Palette` and the `Range`s to draw. Panning, zooming and recolouring change a few numbers, not the rows; a GPU back end uploads only `Instances.dirty`.

`canvas.wgsl`, translated by naga, draws it on every GPU back end, and its Zig twin draws it in `sw` (src/render/sw/canvas.zig). The `canvas` golden holds the two to the same pixels. Output is premultiplied and clipped to the node's rect.

### The row
- **Size:** each instance is 32 bytes in two instance-step rows, `pos` (4 × i32) and `look` (4 × u32), plus a u32 colour column (`Instances.colors`, on by default, 4 bytes a row).
- **Kinds:** `segment` (butt, square or round caps), `rect` (fill, stroke, corner radius), `arc` (a ring sector with caps; `circle` is a full one), `polygon` (any simple or self-crossing chain in the side column `verts`, nonzero rule) and `glyph` (an atlas cell, turned in quarter turns).
- **Coordinates:** the application's own integer units (i32), whatever its document counts in. The camera's i64 origin is subtracted in wrapping i32 before any f32, so a pan far from 0 loses no precision.
- **Colour:** a row's own colour, when it is not 0, is both its stroke and its fill. Otherwise the row takes its layer's. A range `Override` recolours a layer's rows (a selection, a diff); a row's own colour wins over both.
- **Style:** a `Layer` (16 bytes; a palette is one uniform array of at most 256) holds stroke and fill colours, the stroke width in logical pixels, the dash's on and off lengths in logical pixels (to 1/16 px, below 2048), whether fills are drawn, and whether the layer is shown. An empty palette gives every row `Layer.default`: white, 1 px, solid.
- **Width:** a stroke is its layer's width in logical pixels at any zoom (a hairline stays a hairline), or, per row, a width in world units that zooms with the drawing (`.width = n` on the builder).
- **Dashes:** a dash runs along a segment chain from its start, and along an arc's centre line from its start angle.
- **Glyphs:** this file knows no font. `protocol.Mono.canvasGlyphs` writes bitmap-font glyphs over a `protocol.Atlas` of cells. `lcgf_app`'s labels (src/app/labels.zig) write distance glyphs in real fonts. A window has one canvas atlas, so one `Instances` holds one kind of glyph; mixing them trips a debug assertion.
- **Hit testing:** `canvas.hit` uses the same distance functions on the CPU, so what is selected is what is drawn.

### Usage
An application that colours rows itself (a plot, a map) needs no palette:

```zig
var shapes: lcgf.canvas.Instances = .init(&carver, 100_000, 4_096, 64, .{});
_ = shapes.segment(.{ 0, 0 }, .{ 25_400, 0 }, .{ .color = trace, .width = 150, .cap = .round });
_ = shapes.circle(.{ 0, 0 }, 1_270, .{ .color = marker });
_ = f.canvas(.from("plot"), .{ .size = .{ .fill, .fill } }, &shapes, .{
    .camera = .{ .origin = view.origin, .scale = view.px_per_unit },
    .ranges = &.{shapes.since(0)},
});
```

An application with layers (a schematic: theme, hidden layers, highlight at one uniform write) names a layer per row and passes its palette:

```zig
const layers = [_]lcgf.canvas.Layer{
    .of(.{ .stroke = wire, .width = 1 }),                      // 0 wires
    .of(.{ .stroke = edge, .fill = body, .width = 1.5 }),      // 1 symbols
    .of(.{ .stroke = wire, .width = 1, .dash = .{ 4, 4 } }),   // 2 buses, dashed
};
_ = shapes.polyline(&net, .{ .layer = 0, .cap = .round });
_ = shapes.rect(.{ -5_000, -2_500 }, .{ 5_000, 2_500 }, .{ .layer = 1, .radius = 200 });
_ = font.canvasGlyphs(&shapes, "R1", .{ 2_000, 0 }, .{ .px = 1_270, .layer = 1 });
shapes.setColor(picked_row, .rgb(255, 200, 0)); // one row, over its layer
_ = f.canvas(.from("schematic"), style, &shapes, .{
    .camera = camera,
    .palette = &.{ .layers = &layers },
    .ranges = &.{ wires, symbols, selection },
    .overrides = &.{.{ .range = selection, .color = tint }},
});
```

### Limits
- A polyline is segments with no joins: a translucent stroke doubles where two meet.
- A polygon's distance tests every one of its edges per pixel (`polygonDist`): fine for a schematic's or a plot's small shapes, slow for a large filled area of many edges.
- No curves and no gradients. An arbitrary path goes through src/draw/paths.zig into a quad.
- A new kind lands only with its software twin, its shader code and a golden that holds the two to the same pixels.

### Migrating from the first format
| Schemify writes today | It writes after |
|---|---|
| `.layer = k` with a palette of 40 layers | The same. A row in its own colour writes `.color = c`, or `setColor(i, c)` later; an empty palette makes every row white, 1 px, unless coloured |
| `.weight = w` (1 to 4 × the layer width) | A layer per width (`Layer.of(.{ .width = w × base })`), or `.width = units` for a world-unit width |
| `Palette.zoom_scale` and `Camera.zoom` | Nothing: a layer width is logical pixels at every zoom. A width that zooms is a world-unit `.width` |
| `.dash = n` (2n px on, 2n off) | A dashed layer, `Layer.of(.{ .dash = .{ 2n, 2n } })`, and `.layer` naming it |
| `Instances.glyphs(text, at, .{ .px, .layer, .turns, .atlas })` | `(protocol.Mono{}).canvasGlyphs(&shapes, text, at, .{ .px, .layer, .turns, .atlas })`. In `lcgf_app`, the atlas is the bundled font's, `Mono.atlas` (the default); the example host's 16 × 14 `host.font.cells` belong to the example host only |
| `.{ .marks = true }`, `mark(i, c)`, `s.marks` | Nothing to opt in: `setColor(i, c)` and `s.colors` (0 is the layer's) |
| `View.of(cam, palette, …)` | `View.of(cam, …)` |

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

**Done:** Schemify builds LCGF with the default back end and runs through `lcgf_app`, which falls back to software by itself, instead of `-Drender=sw` and a copy of the example host. The host (its `Incremental` and its X11 runner) is deleted (stage 7 of docs/plans/window.md). Stage 7 also brought an App hook for a draw list the application composed and canvas labels in real fonts through `lcgf_app`.

LCGF fixes bugs Schemify finds at the root, on `main`: send them to the LCGF session with the commit and a repro.
