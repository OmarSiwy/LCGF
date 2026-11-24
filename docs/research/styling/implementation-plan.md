# Styling implementation plan

> **Historical research snapshot.** This record predates implementation. See the [implemented styling guide](../../styling/README.md), [coverage profiles](../../styling/coverage.md), and [validation report](../../styling/validation.md) for the completed branch.

Baseline: `ed94db3da27882ef1c87d0dd15a382b4df39e2c2`. The work below was proposed when this research snapshot was written. The original documentation commit changed no runtime behavior. Phase labels express dependency order and scope, not delivery dates or measured effort. A capability group can involve several patches; an existing group may need only integration or clearer documentation.

## Working sequence

Start each patch from a small caller example. Preserve independently callable operations and caller-owned memory, following [the API review](api-design.md). Keep public signatures provisional until those examples exist. Prioritize a normal interactive application and an application with custom text/rendering before generalizing.

The [inventory](inventory.md) is the full backlog. The work packages here combine related entries so foundations are implemented once. For example, `ui.pixel_rounding` concerns layout policy while `visual.pixel_alignment` concerns rendering; they share a contract and should not become separate competing systems.

## P0 — Correctness and explicit contracts

| Work package | Initial code surfaces to inspect | Meaningful completion criterion |
|---|---|---|
| Reproduce transform/effect bounds risks | `src/layout/layout.zig`, `src/draw/damage.zig`, `src/draw/order.zig`, `src/draw/features.zig` | A translated object entering the viewport is visible; growing/shrinking shadows repaint both old and new extents; overlap-sensitive translucent ordering remains correct. Confirm failures before changing algorithms. |
| Shared geometry for paint, clip, text, hit and accessibility | `src/core/types.zig`, `src/draw/inherit.zig`, `src/draw/paint.zig`, `src/draw/draw_list.zig`, `src/interact/hit.zig`, `src/comptime/paint.zig` | A transformed labeled control paints, clips and responds consistently through the advertised front ends. Singular transforms and custom bounds have defined behavior. |
| Explicit presence and semantic state contracts | `src/theme/theme.zig`, `src/widgets/base.zig`, `src/runtime/frame.zig` | Transparent literals, zero, default and inherit are distinct; disabled/read-only visuals agree with behavior; style-only state does not invent conflicting accessibility state. |
| Backend capability, color/alpha and capacity contracts | `src/draw/features.zig`, `src/comptime/features.zig`, `src/render/iface.zig`, relevant backends | Every requested feature is supported, deliberately approximated, or rejected. Import/blending/surface formats and limits are documented. Fixed-buffer exhaustion is explicit. |
| Text run and cluster boundaries | `src/text/`, `src/runtime/frame.zig` | A paint-only color span does not unnecessarily break a ligature; fallback and editing use appropriate cluster boundaries; shaping/line-layout/paint dependencies are stated. |

Do not make every later feature depend on a broad new framework. Resolve each contract at the smallest common boundary. Keep inexpensive rectangle clips, plain colors and primitive alpha working while richer semantics develop.

## P1 — Expose existing power and establish reusable parts

| Work package | Scope | Completion criterion |
|---|---|---|
| Direct style resolution and optional recipes | Token identity, explicit patches, per-property precedence, variants, combined states, scoped themes | Equal-colored roles diverge correctly on a theme change; unrelated literals remain stable; selected + hovered + keyboard-focused controls preserve each applicable property. A direct uncached call and optional cached route agree. |
| Parts that preserve widget behavior | Background, content, label/icon, indicator, focus ring; start with button, input and slider | Customizing a label, border or thumb does not require rewriting input/navigation behavior. Existing simple controls remain concise to author. |
| Advanced text convenience | Connect existing bidi, paragraph alignment, wrapping, truncation and rich-text capabilities to a supported frame sequence | Measurement and drawing share metrics; mixed-direction labels, alignment and multiline truncation work through real usage examples. Preserve caller-sequenced `Frame.finish`. |
| Layout and overlay convenience | Expose the existing bounded grid, flex extensions, anchors, layer-aware hit/paint order and custom passes | Examples can use these operations without relying on private internals; bounded/non-CSS semantics are documented accurately. |
| Environment and accessible defaults | Existing contrast/text scale/reduced motion/focus helpers; broaden state coverage and preference inputs | Focus, errors and selection remain distinguishable; large text does not silently disappear; unknown platform preferences remain distinguishable from false. |

This phase should deliver substantial practical expressiveness before any general compositor. Keep parts lightweight: a decorative mark need not become an independently allocated tree object.

## P2 — Composed everyday paint and typography

| Work package | Scope | Completion criterion |
|---|---|---|
| Ordered decoration lowering | Independent backgrounds, border, outline, outer/inset shadow data | One control can combine a multi-stop gradient, dashed border, shadow and focus outline. Simple solid controls retain the existing compact route. |
| Brushes and image geometry | Multi-stop linear/radial/conic gradients, spread, stable image box/fit/position/crop/tint/repeat, nine-slice modes and sampling | Transparent stops, small/degenerate geometry, source edges, repeats and high-DPI assets behave consistently on the advertised backends. |
| Edges and corners | Per-edge width/color/pattern, border alignment, elliptical radii normalization, dash phase, outlines | Extreme radii and unequal sides do not create cracks; border, background and clip geometry use the intended corresponding shapes. |
| Complete affine and nested rounded clipping | Propagate the P0 geometry contract and represent general rounded intersections | Deeply nested clips agree for text, images and shapes. Rotation/skew/scaling work with pointer targets and damage. |
| Everyday font and text controls | Font matching, OpenType features, line metrics, letter/word spacing, whitespace/tabs, decoration, text paint, editing parts | Baselines, caret/selection and text measurement remain consistent under mixed fonts, bidi and decorations. Cosmetic span changes preserve shaping where appropriate. |
| Standard component recipes and inspector | Inputs, navigation, tables/trees, scrollbars, recipe provenance, computed values and invalidation diagnostics | Inspecting a property reveals its source and why a value changed; scrollbar axes/parts and focus are styleable without replacing behavior. |

Do not promise SVG/CSS equivalence from a partial shader implementation. Each combination must have a documented paint order, supported feature subset and appropriate fallback.

## P3 — Advanced layout, responsiveness, vectors and motion

Add layout breadth behind well-defined measurement contracts: intrinsic sizes, relative lengths and bounded expressions, logical dimensions, richer flex distribution/wrapping/baselines, advanced grid and optional subgrid, fixed/sticky positioning, independent gaps, container conditions, safe-area inputs and virtualization boundaries. These are algorithms and dependencies, not merely additional fields. Cyclic container/child sizing needs a declared resolution rule.

Expose existing path capabilities and extend brushes, dash phase, markers, non-scaling strokes and vector import with explicit fidelity reporting. Reuse shared geometry where practical; keep prepared assets useful on limited renderers. Arbitrary path clipping belongs here; alpha/luminance masking depends on P4 composition.

Extend existing motion with timing/playback/interruption, easing, typed interpolation, broader FLIP, motion paths and compatible shape morphing. Track only active animation work and preserve reduced-motion/idle behavior. Let the caller consume completion events as data. Layout-affecting properties must invalidate layout; paint-only animation should preserve unrelated measurement.

Broaden international typography using existing Unicode machinery: language-sensitive line policies, hyphenation resources, inline objects, locale-sensitive display transforms and typographic variants. Keep source-to-display/cluster mappings for editing. Token interchange and EDA/editor recipes are optional authoring/application layers.

**Exit criterion:** demonstrate responsive docked panels, a zoomable technical canvas and mixed-language controls with animated state changes. Verify only the newly exercised dependencies; do not rebuild every unrelated subsystem as a prerequisite.

## P4 — Optional layers, masks and effects

Only introduce a general compositing path when concrete usage requires completed-subtree semantics. Start with exact group opacity; use it to establish begin/end group behavior, conservative bounds, host-owned surface requirements, resource limits, ordering and reuse. A backend can optimize away an intermediate surface when the result is provably equivalent.

Then add alpha/luminance masks, isolated stacking groups, blend modes and compositing operators, content-alpha shadows, color filters and foreground blur. Backdrop effects come after source-region tracking and damage propagation exist. They sample previous scene content, so a visually stationary panel can require recomputation when its background changes.

**Exit criterion:** the overlapping-child group-opacity example produces the correct result; nested mask/filter/group bounds remain correct; surface budget exhaustion follows policy; software and GPU agree within a documented tolerance for the common supported subset. Report passes and peak transient storage as well as frame time.

The absence of compositor support must not disable ordinary controls. Platform-native materials are distinct from portable backdrop filters and belong to P5.

## P5 — Specialist extensions with explicit demand

Evaluate managed wide gamut/HDR, perspective/3D, native window materials, general custom filter graphs, advanced corner shapes, extended font formats and variable/color fonts, vertical writing/ruby, specialized document layout, mathematical typesetting and a broad CSS-like authoring compiler independently.

Phase assignment reflects this broad default plan, not a claim that these features are unimportant. Move variable/color fonts or a particular international writing system earlier if actual product requirements depend on them. Do not postpone required language support merely because it is less common in English interfaces.

These extensions may bring dependencies, larger assets, platform restrictions or substantial conformance work. Each needs its own caller example and cost/benefit decision. CSS/SVG draft semantics should be labeled as such; a subset importer should diagnose unsupported constructs rather than imply full browser/document conformance.

## Verification and measurement when implementation begins

Use meaningful cases that probe combined semantics, not tests that merely restate struct fields:

- Same-value semantic tokens, explicit transparent overrides, simultaneous states and theme changes during animation.
- Transformed text/custom drawing, nested clips, hit targets larger than visuals, old/new paint bounds and layer-aware hit order.
- Ligatures across paint spans, Arabic/English bidi, combining marks, emoji sequences, fallback boundaries, ellipsis and caret mapping.
- Multi-stop alpha gradients, repeated/cropped images, extreme radii, border dashes, inset/outer shadows and group-opacity overlap.
- Unsupported renderer features, bounded buffers and surfaces, scale changes and font/image generation changes.
- High contrast, large text, reduced motion/transparency, keyboard-visible focus and state distinctions beyond color.

Compare visual results only for declared compatible paths, with documented tolerances. Performance scenes should include a dense static control grid, theme switching, sparse active animations, a scrolling/zooming technical canvas and an effects-heavy panel. Record toolchain, hardware, backend, resolution, scale and warm/cold state; measure frame percentiles, CPU phases, allocations, bytes per node, draw calls, damaged pixels and peak offscreen storage. Avoid global translucent reordering and unmeasured SIMD rewrites.

No runtime tests or benchmarks were executed for the original documentation-only commit. The later [validation report](../../styling/validation.md) records implementation results; this plan retains its original proposed completion criteria.
