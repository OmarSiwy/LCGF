# Plan: what Schemify needs from LCGF

Schemify, an EDA schematic editor, is moving its GUI onto LCGF. Its owner wants every gap closed in LCGF, not worked around in Schemify. Its priorities, in order:
1. A schematic canvas that draws on the GPU back ends and on `sw` from one source.
2. Run-time theme values (sizes, fonts, radii, spacing, not only colours) in compiled markup pages.
3. The markup gaps in its UI spec (`Schemify-zig/docs/port/ui.md` §7.5).

It needs them in a few weeks. Sources: the research replies of 2026-11-26 (file:line evidence is kept below where it decides something), `docs/plans/markup-compiler.md` (MC) and `docs/plans/markup-engine-api.md` (EA).

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
- **Hit testing:** `lcgf.canvas.hit(&shapes, camera, point) ?u32` uses the same SDFs on the CPU, so selection matches what is drawn.

### Work packages, in order (each passes the gates; goldens at 0 bad pixels)

| WP | What | Where |
|---|---|---|
| C0 | GPU projection correctness the canvas depends on: GL ES `first_instance` emulated through the instance buffer offset (it is dropped silently in release builds today, `gles/gpu.zig:630-638`); `sint32x2`/`sint32x4` vertex formats; a `check.zig` case for instancing, instance-step buffers with offsets, first instance > 0 and integer attributes, run on every back end | `src/render/gpu/{desc,check}.zig`, the projections, `web/lcgf.js` |
| C1 | `lcgf.canvas.Instances` (Tier 0 columns and builders), `Camera`, `hit` | `src/draw/canvas.zig` |
| C2 | The `canvas` draw-list command and `Frame.canvas` | `src/draw/draw_list.zig`, `src/runtime/frame.zig` |
| C3 | `sw`: the Zig shader for every kind, culled per band, clipped to the node, threaded and damage-aware like the quad loop | `src/render/sw/canvas.zig` |
| C4 | `canvas.wgsl`, naga-translated (`src/render/shaders/translate.sh`), and an instanced pipeline in each GPU back end: vk, metal, d3d12, gles, wgpu, web | `src/render/shaders/`, each back end's renderer |
| C5 | A `canvas` golden scene (every kind, caps, clipping, camera, glyphs) at 0 bad pixels, sw against GPU; a 100k-primitive pan/zoom benchmark against the 120 fps budget, with workload and conditions | `tools/golden/draw.zig`, `tools/golden/ref/draw/`, `bench/` |
| C6 | C and C++/Rust exposure through `src/abi/api.zig` (per `docs/plans/bindings-rust.md` §6) | `src/abi/` |

## 2. Run-time theme values in compiled pages

Today a comptime page folds the theme: `var()` is substituted by the compiler (`tools/lcgf-gen/markup/lower.zig:75-120`), the theme is a comptime parameter (`ComptimeUi(State, spec, theme)`, `emit_zig.zig:404`), and only colours change at run time (`theme.recolor`, `src/theme/theme.zig:263`). Lengths are harder, because they feed measure and layout: they must enter when rows are pushed, and a theme change must force a relayout.

**Design (the research's option C).**
- **Compiler:** `var(--t-*)` becomes a token index on the `Spec`.
- **Push:** writes the listed fields from a caller-owned `ThemeTable` of lengths, font sizes and colours.
- **Relayout:** a theme generation counter makes a changed table relayout the page.
- **Cost:** pages without tokens are unchanged, byte for byte.
- **Order:** the runtime emitter (§3, N-FE) gets it first, then comptime pages, so a page keeps its CSS when it changes front end.

| WP | What |
|---|---|
| T-RT | `ThemeTable` and token fields on `Spec`/push, the theme generation in the dirty state; runtime front end |
| T-CT | The same in `ComptimeUi` and the compiler (`--runtime-vars=t-`) |

## 3. The markup gaps (Schemify ui.md §7.5, mapped onto the current compiler)

- **Already done:**
  - literal text G1 (`lower.zig:996-1018`);
  - IME preedit;
  - resize cursors;
  - canvas custom draw and capture (`Frame.custom`/`interact`);
  - virtual lists;
  - `on:change`;
  - filled path/polygon as an atlas quad (`src/draw/paths.zig`);
  - SVG path icons.
- **In existing plan entries:**
  - G4 overlays: F10;
  - G6 state CSS: F3b;
  - class bindings: F3;
  - prose and wrap: F2/F11;
  - ellipsis: F12b;
  - tables and trees over data: M8.2;
  - forced runtime page: M7.2;
  - `sfy-*` custom elements: M8.3;
  - `on:submit`: M4.2 and F18;
  - list, dialog and status roles: F1.
- **New:**
  - N-THEME (§2);
  - N-FE: a per-page `lcgf-frontend="runtime"`, with M7.2 brought forward;
  - N-SUBMIT: per-field `on:submit` (Enter; Ctrl+Enter in a textarea);
  - F1+: roles menu, menu_item, tab, tab_list, combobox, scroll_view, figure.
- **App components, out of LCGF's scope:**
  - button icon and mark;
  - multi-cascade menus;
  - docks;
  - pixel splits;
  - growing text areas;
  - scancode chords;
  - math;
  - waves graph.

  Schemify builds these as `sfy-*` custom elements (M8.3).

**Order:**
1. T1 text controls.
2. N-FE runtime emitter.
3. T-RT.
4. M8.3 components.
5. M8.2 each.
6. F3.
7. F18 and N-SUBMIT.
8. F3b.
9. T-CT.
10. F1+.
11. F2, F11, F12b.
12. F10.
13. SVG icons in markup.

## Pins

No pin until a piece lands. Each landing is announced to Schemify with its commit on `main`.
