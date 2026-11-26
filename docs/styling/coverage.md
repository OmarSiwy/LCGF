# Styling capability coverage

This is the implementation record for every group in the original research inventory. **A covered group means the stated profile has real consumers and named evidence; it does not mean every CSS/SVG interpretation or every native platform is supported.** Read the limitations with the profile. Execution results and skipped platform cases are in [validation.md](validation.md).

Coverage: **158 / 158 groups**, **1009 researched option mentions**, **33 categories**. Option mentions overlap and are not a count of independent implemented properties.

| Plan phase | Groups |
|---|---:|
| P0 | 24 |
| P1 | 30 |
| P2 | 44 |
| P3 | 38 |
| P4 | 11 |
| P5 | 11 |

A snapshot of the styling branch's capability record, frozen at the merge; edit it by hand.

## Style system

### ui.property_contract — Typed property metadata and support contract

**P0 · Implemented profile**

Compile-time metadata, typed authoring, validation, initial values, interpolation and invalidation for 37 native box/text properties plus a separately reflected native Paragraph catalog. Computed values feed existing Frame/Tree/Texts and Stack consumers.

Implementation: [src/style/properties.zig](../../src/style/properties.zig), [src/style/paragraph.zig](../../src/style/paragraph.zig), [src/style/resolve.zig](../../src/style/resolve.zig).

Evidence:

- `direct typed values reach existing box and text consumers; transparent and zero are values`
- `paint-only changes do not request shaping or layout; text metrics do`
- `caller usage: resolved paragraph tokens drive the real shaping and multiline layout path`

Profile boundaries:

- Advanced brushes, effects and layout side tables retain their own typed inputs rather than becoming unused Style fields.
- Backend resource/material support remains the renderer's capability contract; the style catalog does not manufacture a missing backend feature.

### ui.bounded_style_storage — Caller-owned optional style storage

**P0 · Implemented profile**

Direct borrowed slices remain sufficient; optional caller-owned declaration pools return deterministic capacity errors and generation-checked spans. Compiler, provenance and token-scale output use declared destination buffers.

Implementation: [src/style/storage.zig](../../src/style/storage.zig), [src/style/tokens.zig](../../src/style/tokens.zig), [src/style/compiler.zig](../../src/style/compiler.zig).

Evidence:

- `bounded authoring storage rejects overflow and stale spans without losing current declarations`
- `cycles and scale capacity errors are explicit`
- `compiler errors report unsupported input and bounded storage without ignoring declarations`

Profile boundaries:

- The caller keeps borrowed data alive and owns mutation/revision sequencing.
- Store generations wrap modulo u64 while skipping zero; spans must not survive a complete epoch wrap or replacement of their owning store.

### ui.presence_inheritance — Explicit presence and inheritance

**P0 · Implemented profile**

Tagged literal/inherit/initial/token sources with omission as absence, selected inherited text/cursor properties, and independent paragraph inheritance. Explicit transparent, null and numeric zero survive resolution.

Implementation: [src/style/resolve.zig](../../src/style/resolve.zig), [src/style/paragraph.zig](../../src/style/paragraph.zig).

Evidence:

- `explicit inheritance, initial, zero and transparent remain distinct, also at comptime`
- `paragraph presence and invalidation distinguish inherited, initial, null and zero`

Profile boundaries:

- Existing theme.Inherited sentinel-based APIs remain available for compatibility; callers opt into the explicit declaration resolver.

## Themes and tokens

### ui.semantic_tokens — Role-preserving semantic color tokens

**P1 · Implemented profile**

Named typed tokens, lexical aliases, nearest-scope lookup and final-origin records preserve role identity independently of packed RGBA equality; application-defined roles need no registry.

Implementation: [src/style/tokens.zig](../../src/style/tokens.zig), [src/style/resolve.zig](../../src/style/resolve.zig), [src/theme/recipe.zig](../../src/theme/recipe.zig), [tools/stylegen/stylegen.py](../../tools/stylegen/stylegen.py).

Evidence:

- `caller usage: same-value semantic tokens separate on a theme change, literals stay literal`
- `same-valued roles keep their identities; a child scope and lexical alias differ`
- `DTCG generated semantic aliases and typography feed actual text layout`

Profile boundaries:

- Applications choose their semantic vocabulary; stock convenience defaults are a deliberately small palette, not every domain role.

### ui.design_scales — Spacing, typography and shape token scales

**P1 · Implemented profile**

Caller-authored monotone numeric scales, bridges for existing spacing/radius/type scales, explicit density and text scaling, and generated composite typography/border/elevation values with native consumers.

Implementation: [src/style/tokens.zig](../../src/style/tokens.zig), [src/theme/recipe.zig](../../src/theme/recipe.zig), [tools/stylegen/stylegen.py](../../tools/stylegen/stylegen.py), [src/style/import_tests.zig](../../src/style/import_tests.zig).

Evidence:

- `cycles and scale capacity errors are explicit`
- `default recipe respects environment text scale and keeps focus separate from selected border`
- `DTCG generated semantic aliases and typography feed actual text layout`
- `DTCG generated gradients, shadows and borders paint caller-owned pixels`

Profile boundaries:

- Density changes only the tokens chosen by the caller; separate hit-target policies are not silently scaled.
- Generated typography selects a supplied static font catalog entry; variable-font instance creation remains explicit.

### ui.theme_scope — Scoped themes and deterministic precedence

**P1 · Implemented profile**

Component base, inherited values, ordered matched declarations and local property overrides lower deterministically; explicit nested token scopes and final optional system-color policy report their winning provenance.

Implementation: [src/style/tokens.zig](../../src/style/tokens.zig), [src/style/resolve.zig](../../src/style/resolve.zig), [src/theme/recipe.zig](../../src/theme/recipe.zig), [src/style/inspector.zig](../../src/style/inspector.zig).

Evidence:

- `same-valued roles keep their identities; a child scope and lexical alias differ`
- `caller usage: simultaneous states, orthogonal variants and local transparent overrides`
- `inspector explains a real compiled rule winner, inactive state and local override`
- `system colors override authored paint with provenance and explicit component exceptions`

Profile boundaries:

- This is ordered native merging, not CSS origin/specificity/cascade-layer semantics.
- The caller associates tree subtrees with scope indices; no retained theme manager walks the application automatically.

## Component styling

### ui.part_identifiers — Reusable widget part styles

**P1 · Implemented profile**

Stable common part IDs plus arbitrary application IDs; independent label/icon/mark/track/thumb/fill/focus resolution reaches real controls. Slider and range recipes share the same thumb property vocabulary while retaining their native value semantics.

Implementation: [src/style/resolve.zig](../../src/style/resolve.zig), [src/theme/recipe.zig](../../src/theme/recipe.zig), [src/theme/recipe_controls.zig](../../src/theme/recipe_controls.zig), [src/theme/recipe_extra_controls.zig](../../src/theme/recipe_extra_controls.zig), [src/theme/recipe_parts.zig](../../src/theme/recipe_parts.zig).

Evidence:

- `recipe caller: custom thumb and app-defined part use direct data, no registry`
- `caller usage: custom icon/label retains button activation and disabled prevents it`
- `radio and range recipes preserve keyboard and pointer behavior with shared marks and two visible thumbs`

Profile boundaries:

- A decorative part is allocated as a node only by a builder that needs one; a recipe ID alone does not allocate a tree row.
- Range knobs use validated explicit pixel dimensions in the supplied adapter.

### ui.variants_recipes — Named variants and reusable component recipes

**P1 · Implemented profile**

Borrowed recipes and variant-ID slices compose intent, size, density and application variants per property, with component-local values applied last before any explicit system-color policy.

Implementation: [src/style/resolve.zig](../../src/style/resolve.zig), [src/theme/recipe.zig](../../src/theme/recipe.zig), [src/theme/recipe_controls.zig](../../src/theme/recipe_controls.zig).

Evidence:

- `caller usage: simultaneous states, orthogonal variants and local transparent overrides`
- `caller usage: combined states keep independent border/focus and failed resolution leaves frame balanced`

Profile boundaries:

- Variant names have application-defined meanings; there is no global registration or implicit inheritance of variant membership.

### ui.combined_states — Combinable state-dependent styling

**P1 · Implemented profile**

Required/forbidden masks cover built-in interaction/semantic states plus caller custom bits; ordered declarations preserve independent selection and keyboard focus without enumerating every state combination.

Implementation: [src/style/resolve.zig](../../src/style/resolve.zig), [src/theme/recipe.zig](../../src/theme/recipe.zig), [src/theme/recipe_controls.zig](../../src/theme/recipe_controls.zig), [src/theme/recipe_comptime.zig](../../src/theme/recipe_comptime.zig), [src/widgets/base.zig](../../src/widgets/base.zig).

Evidence:

- `caller usage: simultaneous states, orthogonal variants and local transparent overrides`
- `recipe disabled state cancels capture, skips Tab and cannot be defeated by a visual override`
- `recipe read-only checkbox remains focusable and its pointer event is explicitly suppressed`
- `combined state and environment row participation cancels captured range and radio actions in both front ends`

Profile boundaries:

- Focus-within, dragging, drop-target and domain states are supplied by the owner when not directly produced by the standard adapter.
- Style resolution does not itself mutate application behavior or semantic truth.

## Style system

### ui.resolver_generations — Shared style handles and targeted invalidation

**P1 · Implemented profile**

Optional bounded cache stores reached combinations using exact state/environment keys and caller-owned recipe/token/parent revisions. Metadata and differences expose the concrete dirty domains for independently scheduled passes.

Implementation: [src/style/storage.zig](../../src/style/storage.zig), [src/style/tokens.zig](../../src/style/tokens.zig), [src/style/properties.zig](../../src/style/properties.zig), [src/style/inspector.zig](../../src/style/inspector.zig).

Evidence:

- `optional cache agrees with direct resolution and generation changes invalidate a reached state`
- `paint-only changes do not request shaping or layout; text metrics do`
- `inspector explains a real compiled rule winner, inactive state and local override`

Profile boundaries:

- Base/declaration/local/variant changes must advance the recipe revision; mutable borrowed data is not observed automatically.
- No mandatory interning, subscription graph or global invalidation traversal exists; the host schedules affected requests and clears before revision reuse/wrap.

## Style authoring

### ui.typed_authoring — Unified runtime and compile-time authoring

**P1 · Implemented profile**

Same typed resolver at runtime and comptime, direct computed values, optional diagonal component adapters, dynamic state/environment/token fields and independently callable native passes; production DrawLists and semantic role/value columns are compared by replay consumers.

Implementation: [src/style/style.zig](../../src/style/style.zig), [src/style/resolve.zig](../../src/style/resolve.zig), [src/theme/recipe_controls.zig](../../src/theme/recipe_controls.zig), [src/theme/recipe_comptime.zig](../../src/theme/recipe_comptime.zig), [src/theme/recipe_part_comptime.zig](../../src/theme/recipe_part_comptime.zig), [src/theme/recipe_extra_controls.zig](../../src/theme/recipe_extra_controls.zig), [src/widgets/base.zig](../../src/widgets/base.zig).

Evidence:

- `explicit inheritance, initial, zero and transparent remain distinct, also at comptime`
- `recipe controls: runtime/comptime draw and behavior parity through click, drag, text and theme changes`
- `data part composition has runtime/comptime parity with dynamic state and environment`
- `radio and range recipes preserve keyboard and pointer behavior with shared marks and two visible thumbs`
- `a runtime token error in a comptime recipe is returned as frame data`

Profile boundaries:

- Capacity, resource and renderer support remain explicit; parity claims apply to the named supported consumer fixtures rather than all possible arbitrary shaders or widget extensions.

### ui.token_import — Optional design-token interchange

**P3 · Implemented profile**

Offline bounded DTCG 2025.10 compiler covers all 13 token categories, inherited group types, aliases and local component references, deterministic native Zig constants and source-preserving metadata. Cycles, missing references, duplicate keys, invalid types/values and capacity limits fail explicitly.

Implementation: [tools/stylegen/stylegen.py](../../tools/stylegen/stylegen.py), [tools/stylegen/test_stylegen.py](../../tools/stylegen/test_stylegen.py), [src/style/testdata/dtcg.json](../../src/style/testdata/dtcg.json), [src/style/testdata/dtcg_generated.zig](../../src/style/testdata/dtcg_generated.zig), [src/style/import_tests.zig](../../src/style/import_tests.zig).

Evidence:

- `python3 tools/stylegen/test_stylegen.py`
- `DTCG generated semantic aliases and typography feed actual text layout`
- `DTCG generated gradients, shadows and borders paint caller-owned pixels`
- `DTCG generated transition timing and custom stroke use native playback and stroking`

Profile boundaries:

- Declared profile rejects group $extends, remote references, missing color components and unsupported unit expressions.
- rem conversion, seconds and radius-to-sigma lowering are explicit target settings; existing RGBA8 packing clamps color at its boundary.
- DTCG is a Community Group specification, not a W3C Recommendation.

### ui.stylesheet_compiler — Optional CSS-like authoring compiler

**P5 · Implemented profile**

Optional bounded compiler for part/variant/state compounds, comma groups, :not(:state), comments, native property aliases and padding shorthand; output is ordinary Rule/Declaration data with source positions and no render-time source parsing.

Implementation: [src/style/compiler.zig](../../src/style/compiler.zig), [src/style/resolve.zig](../../src/style/resolve.zig), [src/style/properties.zig](../../src/style/properties.zig).

Evidence:

- `compiler caller resolves parsed parts, variants, combined states and explicit transparency`
- `compiler errors report unsupported input and bounded storage without ignoring declarations`
- `compiled declarations feed the actual frame text and layout consumer`

Profile boundaries:

- Full CSS selectors, descendant combinators, specificity, @rules/imports/cascade layers, !important, URLs and custom-property definitions are explicitly unsupported.
- Output buffers are unspecified on a failed compilation; no partial successful sheet is returned.

## Style tooling

### ui.style_inspector — Computed-style and dependency inspector

**P2 · Implemented profile**

Caller-owned computed-property snapshots, all rule match reasons, declaration dispositions, literal/inherit/token provenance and concrete invalidation differences; final system policy can supply its own winning origin trace.

Implementation: [src/style/inspector.zig](../../src/style/inspector.zig), [src/style/resolve.zig](../../src/style/resolve.zig), [src/style/properties.zig](../../src/style/properties.zig), [src/theme/recipe.zig](../../src/theme/recipe.zig).

Evidence:

- `inspector explains a real compiled rule winner, inactive state and local override`
- `system colors override authored paint with provenance and explicit component exceptions`

Profile boundaries:

- This is read-only inspector data, not a retained inspector UI or an automatic backend capability detector.
- inspector.snapshot evaluates raw requests; request Recipe.resolve provenance separately for the recipe's later system-color policy.

## Layout and geometry

### ui.size_constraints — Preferred, minimum and maximum dimensions

**P1 · Implemented profile**

Retains native fit/pixel/grow/percentage/min/max/aspect rows. The optional measured flex pass adds explicit basis and full bounded min/max freezing, then lowers placements to ordinary Style.

Implementation: [src/layout/flex.zig](../../src/layout/flex.zig), [src/layout/layout.zig](../../src/layout/layout.zig), [src/layout/special.zig](../../src/layout/special.zig).

Evidence:

- `min: a node is never smaller than its min, even with no content`
- `percent: a fraction of the parent's inner size on both axes`
- `aspect: the height follows the resolved width, over content, grow and stretch`
- `bounded flex bases freeze repeatedly and auto margins absorb remaining space`

Profile boundaries:

- Native Flex preserves its documented max-wins conflict rule, one shrink round and optional two grow rounds; special.flex is the explicit iterative profile.

### ui.intrinsic_measurement — Intrinsic content measurement semantics

**P3 · Implemented profile**

Measures real shaped min-content and max-content widths, mandatory breaks, tab stops, no-break spaces, ordinary versus anywhere wrapping and explicit hyphen opportunities; fit-content lowers to actual Size.px.

Implementation: [src/text/layout/intrinsic.zig](../../src/text/layout/intrinsic.zig), [src/text/layout/lines.zig](../../src/text/layout/lines.zig), [src/layout/grid.zig](../../src/layout/grid.zig).

Evidence:

- `intrinsic widths distinguish unbreakable words anywhere tabs and fit content in real layout`

Profile boundaries:

- Input glyph clusters must be in logical monotonic order and coarsened to graphemes; measure before visual bidi reordering.
- Language-specific hyphen marker widths require fromOpportunities; the basic UAX14 pass does not guess a hyphen glyph.

### ui.relative_units — Relative length units and bounded expressions

**P3 · Implemented profile**

Caller-resolved logical/device/percentage/font/root-font/line/viewport/container/physical lengths, safe insets and bounded arithmetic/min/max/clamp expressions lower to real Size values.

Implementation: [src/layout/units.zig](../../src/layout/units.zig).

Evidence:

- `relative units and expressions feed real layout without a manager or hidden passes`

Profile boundaries:

- Font, viewport, container and safe-area bases are caller inputs; indefinite bases return explicit Indefinite.
- This is typed bounded expression evaluation, not a CSS calc() text parser.

### ui.box_spacing — Per-edge padding and margins

**P1 · Implemented profile**

Retains physical per-edge padding and non-collapsing margin rows; logical mapping is explicit; optional measured flex consumes explicit physical margins and automatic margin slots.

Implementation: [src/layout/flex.zig](../../src/layout/flex.zig), [src/layout/logical.zig](../../src/layout/logical.zig), [src/layout/special.zig](../../src/layout/special.zig).

Evidence:

- `margin: adds to the parent's natural size and to the cursor step; the node sits inside it`
- `bounded flex bases freeze repeatedly and auto margins absorb remaining space`
- `logical edges sizes margins and reversed block flow reach physical box geometry`

Profile boundaries:

- Native floating nodes retain their documented margin policy; margins are not CSS block margin collapse.
- The existing box-size convention remains the core contract; no global CSS content-box/border-box switch is inferred.

### ui.row_column_gaps — Independent gaps and line spacing

**P3 · Implemented profile**

Grid, measured row/column flow, masonry and document columns accept independent axis/line gaps and emit placements consumed by native nodes or text Lines.

Implementation: [src/layout/grid.zig](../../src/layout/grid.zig), [src/layout/special.zig](../../src/layout/special.zig), [src/layout/document.zig](../../src/layout/document.zig), [src/layout/wrap.zig](../../src/layout/wrap.zig).

Evidence:

- `grid: gaps between tracks, spans across gaps, and items aligned in their cells`
- `special layouts lower into ordinary node layout and preserve dependent placement`
- `table spans and page fragments drive the real placement and glyph-line columns`

Profile boundaries:

- The legacy native flex-wrap side table retains its single Style.gap input; independent line/main gaps use the explicit measured flow pass.

### ui.logical_edges — Direction-aware logical edges and dimensions

**P3 · Implemented profile**

Maps inline/block dimensions, logical padding/margins/insets and axes for horizontal/vertical/sideways writing and LTR/RTL; an optional mirror pass handles reversed box flow.

Implementation: [src/layout/logical.zig](../../src/layout/logical.zig).

Evidence:

- `logical edges sizes margins and reversed block flow reach physical box geometry`

Profile boundaries:

- Logical box mapping does not rotate glyphs; vertical_text is the separate text consumer.
- Mirroring requires caller-supplied bounded rows and explicit placement sequencing.

### ui.flex_distribution — Flex basis, growth and shrink semantics

**P3 · Implemented profile**

Keeps the native fast profile and adds a measured single-line flex pass with explicit basis, growth/shrink weights, repeated min/max freezing, margins, auto margins, stretch and baseline placement.

Implementation: [src/layout/flex.zig](../../src/layout/flex.zig), [src/layout/special.zig](../../src/layout/special.zig).

Evidence:

- `bounded flex bases freeze repeatedly and auto margins absorb remaining space`
- `regrow: bounded to two rounds; a grower capped in the second leaves its rest unused`

Profile boundaries:

- The measured pass is explicitly sequenced by the caller and does not replace the native SIMD row profile.
- No browser flexbox conformance claim; complex multi-line flex interactions remain explicit composition.

### ui.flex_wrap_baseline — Wrapping, line layout and baseline alignment

**P3 · Implemented profile**

Retains native row wrap and first-baseline rows; measured flow supports either main axis with independent gaps; explicit baseline values and inline-object metrics align mixed content. Paragraph.baseline_source selects first/last measured text baselines for the ordinary native baseline rows; the explicit metrics commit helper does the same for custom paragraphs.

Implementation: [src/layout/wrap.zig](../../src/layout/wrap.zig), [src/layout/baseline.zig](../../src/layout/baseline.zig), [src/layout/special.zig](../../src/layout/special.zig), [src/layout/logical.zig](../../src/layout/logical.zig), [src/text/layout/inline_objects.zig](../../src/text/layout/inline_objects.zig), [src/text/layout/metrics.zig](../../src/text/layout/metrics.zig), [src/text/layout/stack.zig](../../src/text/layout/stack.zig).

Evidence:

- `wrap: when everything fits on one line the rects are those of a row that does not wrap`
- `baseline alignment: children of a baseline row share one baseline`
- `special layouts lower into ordinary node layout and preserve dependent placement`
- `inline replacement participates in wrapping baseline metrics and transformed image emission`
- `edge trim and selected last baselines drive glyph queries and native baseline layout`

Profile boundaries:

- Native baseline alignment remains restricted to non-wrapping rows; first/last text baseline selection is implemented, but full automatic multi-line flex baseline-sharing groups are outside that profile.
- Reverse flow uses logical mirroring or caller order; there is no separate implicit CSS order cascade.

### ui.alignment_distribution — Container and item alignment distribution

**P3 · Implemented profile**

Grid and measured placement support start/end/center/space-between/space-around/space-evenly; native item cross overrides and grid stretch are retained. Negative spare space is clamped in measured distribution.

Implementation: [src/layout/grid.zig](../../src/layout/grid.zig), [src/layout/special.zig](../../src/layout/special.zig), [src/layout/flex.zig](../../src/layout/flex.zig).

Evidence:

- `grid content distribution and bounded fit tracks set cell starts`
- `cross: a child's own alignment replaces the parent's across the main axis`
- `bounded flex bases freeze repeatedly and auto margins absorb remaining space`

Profile boundaries:

- Self/baseline semantics are explicit for each layout profile; there is no universal CSS alignment resolver.

### ui.grid_basics — Public integration of bounded grid

**P1 · Implemented profile**

Public bounded grid rows and run/fit/resolve passes support fixed/content/fraction tracks, explicit cells/spans, independent gaps, item alignment and sparse automatic placement.

Implementation: [src/layout/grid.zig](../../src/layout/grid.zig).

Evidence:

- `grid: items in explicit cells; fit tracks take the largest item, items fill their cell`
- `grid: gaps between tracks, spans across gaps, and items aligned in their cells`
- `autoPlace: row order around explicit items, spans that do not fit move on`

Profile boundaries:

- Track/content contributions use the declared native profile rather than the full browser Grid sizing algorithm.

### ui.grid_advanced — Richer grid tracks and placement

**P3 · Implemented profile**

Adds min/max and bounded fit-content tracks, fractional freezing, row/column dense placement, definite-size auto-fill/auto-fit expansion and bounded implicit track patterns. Borrowed named lines with positive/negative occurrences and validated rectangular named areas resolve into real numeric grid items/spans.

Implementation: [src/layout/grid.zig](../../src/layout/grid.zig), [src/text/layout/intrinsic.zig](../../src/text/layout/intrinsic.zig), [src/layout/grid_names.zig](../../src/layout/grid_names.zig).

Evidence:

- `bounded grid fractions honor minima caps and redistribution in actual cell geometry`
- `dense and column auto flow use bounded existing cells`
- `automatic repeats and bounded implicit patterns feed actual grid track sizing`
- `named lines and rectangular areas resolve to actual grid node geometry`

Profile boundaries:

- Names are resolved explicitly from caller rows/templates; this does not add a CSS selector/tokenizer or an implicit name registry.
- auto-fit uses a caller-supplied occupied-track count; intrinsic automatic-repeat browser rules are not inferred.
- A distinct min-content floor is supplied explicitly rather than guessed from a maximum-content measurement.

### ui.subgrid — Subgrid alignment across nested components

**P3 · Implemented profile**

An explicit parent-item relation shares row or column track definitions, intrinsic contributions, resolved lines and inherited gap values across nested grids.

Implementation: [src/layout/grid.zig](../../src/layout/grid.zig).

Evidence:

- `shared subgrid contributes individual intrinsic tracks and reuses resolved lines`

Profile boundaries:

- Parent grids must precede children, shared counts must match the parent item span, and shared-axis child padding must be zero.
- Automatic CSS subgrid baseline participation and arbitrary cyclic dependencies are outside this bounded profile.

## Positioning and layering

### ui.out_of_flow — Out-of-flow placement and containing blocks

**P1 · Implemented profile**

Floating rows retain an explicit containing parent/origin; ordinary offsets, logical inset resolution and anchor/pivot passes lower to normal geometry.

Implementation: [src/core/types.zig](../../src/core/types.zig), [src/layout/overlay.zig](../../src/layout/overlay.zig), [src/layout/units.zig](../../src/layout/units.zig).

Evidence:

- `anchor: corners and edges of the parent's content box, with the subtree carried along`
- `anchor: no anchors leaves the layout untouched; overflow is reported`
- `anchor: a popover is placed against another node's rect from the previous frame`
- `anchor: flip to the other side only when the first side leaves the viewport`
- `relative units and expressions feed real layout without a manager or hidden passes`

Profile boundaries:

- The caller identifies the containing block; there is no implicit CSS containing-block search.

### ui.anchored_overlays — Menus and popovers anchored to geometry

**P1 · Implemented profile**

Anchors consume explicit/current-or-previous geometry, edge/pivot/offset and viewport fallback data, carrying the subtree with the repositioned root.

Implementation: [src/layout/overlay.zig](../../src/layout/overlay.zig).

Evidence:

- `anchor: corners and edges of the parent's content box, with the subtree carried along`
- `anchor: no anchors leaves the layout untouched; overflow is reported`
- `anchor: a popover is placed against another node's rect from the previous frame`
- `anchor: flip to the other side only when the first side leaves the viewport`
- `overlay: a window with a menu, a tooltip from last frame's rect and paint layers`

Profile boundaries:

- Applications decide when previous-frame geometry is acceptable; layer selection and focus trapping remain explicit.

### ui.fixed_sticky — Fixed and sticky positioning

**P3 · Implemented profile**

Measured fixed/sticky placement accepts explicit containing and scroll boxes, independent start/end constraints and caller chosen stacking. Unconstrained axes retain their measured positions.

Implementation: [src/layout/scroll_policy.zig](../../src/layout/scroll_policy.zig).

Evidence:

- `both-axis gutters converge, mirror and position thumbs with real offsets`
- `chaining, snap stops, reveal padding and content anchoring combine predictably`

Profile boundaries:

- Call between arrangement and finalization; the helper does not observe window/scroll state or create a layer automatically.

### ui.layer_order — Consistent paint and hit layer order

**P0 · Implemented profile**

Global inherited layer order and row order agree between paint and hit queries. Explicit offscreen ranges provide isolated local composition without global translucent reordering.

Implementation: [src/layout/overlay.zig](../../src/layout/overlay.zig), [src/draw/order.zig](../../src/draw/order.zig), [src/interact/hit.zig](../../src/interact/hit.zig), [src/interact/targets.zig](../../src/interact/targets.zig), [src/render/prepared.zig](../../src/render/prepared.zig).

Evidence:

- `order: raised nodes and their subtrees paint after layer 0, rows in order within a layer`
- `overlay: a window with a menu, a tooltip from last frame's rect and paint layers`
- `stacking layers: a raised menu paints after every row; batch counts recorded`
- `stacking layers: with no node raised, layer order paints exactly like row order`
- `merge across text: overlapping items keep their order, in row and in layer order`
- `atLayered matches the scalar reference, and is `at` when every layer is 0`
- `atLayered: an open menu covers the later body row under it`
- `expanded targets agree across pure comptime and layered runtime input`
- `ordinary quad text and custom commands participate in an exact clipped isolated group`

Profile boundaries:

- Local groups are caller-sequenced surfaces, not a retained CSS stacking-context resolver.

## Layout and geometry

### ui.visibility_participation — Visibility, layout and input participation

**P0 · Implemented profile**

Independent layout/paint/hit/semantic participation combines down the subtree, collapses layout contributions and cancels captured input when a control becomes ineligible.

Implementation: [src/core/types.zig](../../src/core/types.zig), [src/core/tree.zig](../../src/core/tree.zig), [src/layout/layout.zig](../../src/layout/layout.zig), [src/runtime/frame.zig](../../src/runtime/frame.zig), [src/runtime/reuse.zig](../../src/runtime/reuse.zig), [src/a11y/tree.zig](../../src/a11y/tree.zig), [src/theme/recipe_tests.zig](../../src/theme/recipe_tests.zig).

Evidence:

- `participation reserves hidden space, collapses layout and cancels descendant input`
- `reuse rebuilds collapsed and cursor-dependent children when their parent changes`
- `recipe participation cancels release actions and explicit cursor wins in both front ends`

Profile boundaries:

- Inherited exclusions cannot be re-enabled by a child; choose a separate sibling/subtree for a portal or independently participating overlay.

### ui.overflow_modes — Overflow and scrolling semantics

**P1 · Implemented profile**

Native visible/clip geometry remains separate from a measured scroll viewport; both-axis auto/always presentation uses real extents, clipping and input.

Implementation: [src/core/types.zig](../../src/core/types.zig), [src/layout/scroll.zig](../../src/layout/scroll.zig), [src/widgets/scroll_area.zig](../../src/widgets/scroll_area.zig), [src/layout/scroll_policy.zig](../../src/layout/scroll_policy.zig).

Evidence:

- `clamp: scroll stays between the content start and its end`
- `scroll: a long list scrolled by a wheel, then to a focused row, with a sticky header`
- `two-axis styled viewport consumes input and emits semantic bars through ordinary Frame`
- `both-axis gutters converge, mirror and position thumbs with real offsets`

Profile boundaries:

- This is explicit native container behavior, not CSS overflow propagation or anonymous scroll-box construction.

### ui.containment_virtualization — Containment and virtualized measurement boundaries

**P3 · Implemented profile**

Existing bounded virtualization and relayout boundaries compose with measured placeholders and explicit scroll extent. Reused subtrees rebase sparse paint references and rebuild when inherited participation/cursor inputs change.

Implementation: [src/runtime/reuse.zig](../../src/runtime/reuse.zig), [src/comptime/dynamic.zig](../../src/comptime/dynamic.zig), [src/widgets/vlist.zig](../../src/widgets/vlist.zig), [src/layout/incremental.zig](../../src/layout/incremental.zig).

Evidence:

- `reuse: unchanged signals copy the subtree; a changed one rebuilds it once`
- `reuse: a copy moved to other rows has its links rebased`
- `reuse: the pointer over the subtree forces a rebuild`
- `reuse: after the pointer leaves, one more rebuild clears the hover, then reuse resumes`
- `reuse: springs moving outside the subtree do not stop the copy`
- `reuse: a spring moving inside the subtree rebuilds it until it lands, then survives copies`
- `reuse: a copy behind a relayout boundary skips layout and lands where a rebuild would`
- `reuse: no room for the copy means a rebuild, never an overflow`
- `reuse: a copied subtree keeps its extras rows and inherits from its new place`
- `reuse rebuilds collapsed and cursor-dependent children when their parent changes`
- `reuse rebases paint references when an unchanged decorated subtree moves in row storage`
- `virtual list maps a bounded window onto a large data set and clips fractional rows`
- `a conditional root releases its viewport when hidden, then reuses it`
- `check: what a comptime virtual list's state must have`
- `window: the rows on screen by index arithmetic`
- `boundaries: changes inside a boundary leave its natural size, and all outside it, alone`

Profile boundaries:

- Visible-range realization and content extents are application inputs. No CSS content-visibility heuristic or asynchronous intrinsic measurement is implied.

### ui.custom_layout_protocol — Custom layout through explicit passes

**P1 · Implemented profile**

Custom measured items/results remain ordinary caller-owned rows; standalone arrange functions produce Placement, Style, Box or text Lines consumed by existing native layout/emission.

Implementation: [src/layout/special.zig](../../src/layout/special.zig), [src/layout/document.zig](../../src/layout/document.zig), [src/text/layout/intrinsic.zig](../../src/text/layout/intrinsic.zig), [src/text/layout/inline_objects.zig](../../src/text/layout/inline_objects.zig).

Evidence:

- `special layouts lower into ordinary node layout and preserve dependent placement`
- `table spans and page fragments drive the real placement and glyph-line columns`

Profile boundaries:

- No hidden per-widget runtime callbacks or required layout object registry; callers sequence dependent passes.

### ui.pixel_rounding — Logical geometry and pixel rounding policy

**P0 · Implemented profile**

Runtime, plain and folded compile-time layout support fractional or device-grid coordinates and a caller grid origin. Cumulative track/glyph/caret endpoints use the same optional rounding pass.

Explicit none/nearest/floor/ceil policies use device scale and grid origin; cumulative track endpoints avoid drift; the text pass updates glyph, line, justification and caret geometry together.

Implementation: [src/layout/rounding.zig](../../src/layout/rounding.zig), [src/layout/layout.zig](../../src/layout/layout.zig), [src/runtime/frame.zig](../../src/runtime/frame.zig), [src/comptime/layout.zig](../../src/comptime/layout.zig), [src/text/layout/query.zig](../../src/text/layout/query.zig).

Evidence:

- `cumulative rounding preserves shared edges and glyph caret geometry at fractional scale`
- `rounded runtime, plain and folded layouts retain shared fractional geometry`

Profile boundaries:

- Fixed-viewport integer compile-time retention rejects fractional policies unless fractional_coordinates is selected. Change the grid from original measurements, not already-snapped text advances.
- The text rounding pass runs after placement/bidi and before query/emission, and must restart from raw layout when policy changes.
- Stroke alignment is a paint concern; root-owned finalizeWith/runtime integration supplies the corresponding native geometry path.

## Responsive styling

### ui.responsive_conditions — Viewport and container style conditions

**P3 · Implemented profile**

Explicit viewport/container width and height ranges plus scale ranges select ordinary ordered rules; each request supplies its own container snapshot and optional exact environment cache key.

Implementation: [src/style/environment.zig](../../src/style/environment.zig), [src/style/resolve.zig](../../src/style/resolve.zig), [src/style/storage.zig](../../src/style/storage.zig).

Evidence:

- `unknown preferences do not match false; viewport and container conditions stay separate`
- `optional cache agrees with direct resolution and generation changes invalidate a reached state`

Profile boundaries:

- Named breakpoint conventions, orientation policy and container measurement scheduling remain caller data/control flow.
- There is no retained boundary subscription system or automatic size-query cycle solver.

### ui.environment_conditions — Environment and input-capability conditions

**P1 · Implemented profile**

Host data for appearance/accent, text scale, high/forced contrast, reduced effects, pointer precision, hover, direction and unknown preferences drives the same rule evaluation; existing Input/Settings adapters retain unknown-versus-false semantics.

Implementation: [src/style/environment.zig](../../src/style/environment.zig), [src/style/resolve.zig](../../src/style/resolve.zig), [src/theme/recipe.zig](../../src/theme/recipe.zig), [src/style/locale.zig](../../src/style/locale.zig).

Evidence:

- `unknown preferences do not match false; viewport and container conditions stay separate`
- `known accessibility inputs consume existing settings and explicit effect choices`
- `default recipe respects environment text scale and keeps focus separate from selected border`
- `locale font preferences and labels lower to real Frame text rows`
- `combined state and environment row participation cancels captured range and radio actions in both front ends`

Profile boundaries:

- The resolver does not query an operating system or infer capabilities that the host did not supply.

### ui.safe_area_occlusion — Safe-area and viewport occlusion inputs

**P3 · Implemented profile**

Host safe-area/keyboard/occlusion inputs produce an explicit usable rectangle for responsive layout and overlay constraints. Unknown preferences remain distinguishable from false.

Implementation: [src/core/input.zig](../../src/core/input.zig), [src/style/environment.zig](../../src/style/environment.zig), [src/layout/overlay.zig](../../src/layout/overlay.zig).

Evidence:

- `unknown preferences do not match false; viewport and container conditions stay separate`
- `known accessibility inputs consume existing settings and explicit effect choices`
- `anchor: flip to the other side only when the first side leaves the viewport`

Profile boundaries:

- The framework consumes host measurements; it does not guess display cutouts or keyboard geometry.

## Optional document and specialized layout

### ui.special_layout_modules — Specialized native and document layouts

**P5 · Implemented profile**

Optional bounded dock, radial, flow, masonry, flex, measured spanning table, balanced column height and page/column fragmentation passes produce usable placements/Lines; fragmentation reports relaxed impossible constraints.

Implementation: [src/layout/special.zig](../../src/layout/special.zig), [src/layout/document.zig](../../src/layout/document.zig).

Evidence:

- `special layouts lower into ordinary node layout and preserve dependent placement`
- `bounded flex bases freeze repeatedly and auto margins absorb remaining space`
- `table spans and page fragments drive the real placement and glyph-line columns`

Profile boundaries:

- These are measured native/document building blocks, not an HTML formatter or general constraint-equation solver.
- Automatic CSS floats, collapsed table-border conflict resolution and footnote placement are not provided by these two modules.

## Typography

### ui.public_text_pipeline — Advanced text in the normal frame path

**P1 · Implemented profile**

Paragraph rows, rich spans, font-backed metrics, explicit fallback, wrapping, bidi, ellipsis and real transformed glyph emission are consumed by Stack and root's normal Frame.endText path. First/last baseline source is also consumed through the normal Paragraph/Stack path.

Implementation: [src/text/layout/stack.zig](../../src/text/layout/stack.zig), [src/text/protocol.zig](../../src/text/protocol.zig), [src/text/layout/emit.zig](../../src/text/layout/emit.zig), [src/runtime/frame.zig](../../src/runtime/frame.zig), [src/text/layout/metrics.zig](../../src/text/layout/metrics.zig).

Evidence:

- `paragraph rows drive normal measure wrap query and transformed glyph emission`
- `rich rows preserve shaping and expose per-glyph font size and inherited-opacity paint`
- `golden: a frame measured, wrapped and painted through the stack matches the reference`

Profile boundaries:

- The native Stack uses native Shaper values; optional HarfBuzz remains an explicit same-Run producer rather than a mandatory core backend.
- Default Frame.end retains the small Mono profile; full text is selected explicitly.

### ui.font_selection — Family, resource and style matching

**P2 · Implemented profile**

Caller-owned catalog/family lists select actual font handles through CSS-style static width/style/weight ordering; OS/2/head metadata and existing system/embedded fallback adapters remain explicit.

Implementation: [src/text/font/match.zig](../../src/text/font/match.zig), [src/text/fallback/fallback.zig](../../src/text/fallback/fallback.zig), [src/text/fallback/system.zig](../../src/text/fallback/system.zig).

Evidence:

- `font requests select actual family faces before the ordinary text measure pass`
- `static-face matching respects width priority and the 400 to 500 weight interval`

Profile boundaries:

- Family matching is ASCII case-insensitive; platform discovery/canonical Unicode family aliases remain caller-owned.
- find returns a catalog index; apply writes catalog[index].font. There is no required global font registry.

### ui.font_weight_width_style — Font weight, width and slant selection

**P2 · Implemented profile**

Matches real normal/italic/oblique and numeric weight/width faces; optional HarfBuzz synthesis explicitly controls horizontal/vertical emboldening, slant and in-place advance policy with real outline/raster effects.

Implementation: [src/text/font/match.zig](../../src/text/font/match.zig), [src/text/shape/harfbuzz.zig](../../src/text/shape/harfbuzz.zig).

Evidence:

- `static-face matching respects width priority and the 400 to 500 weight interval`
- `explicit synthesis changes real outline coverage and matching advances with default reset`

Profile boundaries:

- Synthesis is an explicit outline fallback, not an implicit replacement for a real chosen face; SVG/bitmap artwork is not synthesized.
- Automatic selection within variable font axis ranges is not part of the static catalog matcher.

## Optional typography

### ui.font_formats_variations — Extended font formats and variable/color fonts

**P5 · Implemented profile**

Optional HB13.2.1 provides TTF/CFF/CFF2/variable outlines, arbitrary explicit variation axes, format diagnostics, COLRv0+CPAL layers, COLRv1 gradients/clips/transforms/groups/compositing, embedded PNG extraction, and plain/gzip OpenType SVG rasterization through actual bounded paint consumers.

Implementation: [src/text/shape/harfbuzz.zig](../../src/text/shape/harfbuzz.zig), [src/text/shape/harfbuzz_paint.zig](../../src/text/shape/harfbuzz_paint.zig), [src/text/shape/testdata/make_variable.py](../../src/text/shape/testdata/make_variable.py), [src/text/shape/testdata/make_color.py](../../src/text/shape/testdata/make_color.py), [src/text/shape/testdata/make_colrv1.py](../../src/text/shape/testdata/make_colrv1.py).

Evidence:

- `variable coordinates change real glyph advances and an empty axis list restores defaults`
- `variable outlines change rasterized coverage through bounded existing path buffers`
- `CFF and CFF2 cubic outlines connect to the same path rasterizer`
- `COLRv0 palettes change real rasterized glyph layer colors`
- `python src/text/shape/testdata/make_variable.py`
- `python src/text/shape/testdata/make_color.py`
- `python src/text/shape/testdata/make_colrv1.py`
- `bitmap color fonts decode with the existing PNG path and SVG extraction is explicit`
- `COLRv1 callbacks render real gradients groups transforms palette overrides and bounded failures`
- `plain and gzip SVG font glyphs render detached at the true baseline with palette fallback`

Profile boundaries:

- The native parser remains glyf-based; extended formats require the optional HB build.
- Named instances and optical sizing are caller-resolved complete axis lists; no automatic platform instance selector is added.
- SVG font support is the renderer's declared bounded SVG profile and returns explicit unsupported-profile errors; it is not full SVG/CSS conformance.
- Bitmap extraction supports HarfBuzz's PNG payload route; other embedded codecs are not silently decoded.

## Typography

### ui.shaping_features — Shaping feature and run-property control

**P2 · Implemented profile**

Native Paragraph consumes liga/kern/mark flags; optional HB consumes arbitrary OpenType feature tags/values/byte ranges, explicit script/language/direction and cluster-level policy with reset per call.

Implementation: [src/text/layout/stack.zig](../../src/text/layout/stack.zig), [src/text/layout/spans.zig](../../src/text/layout/spans.zig), [src/text/shape/harfbuzz.zig](../../src/text/shape/harfbuzz.zig).

Evidence:

- `paint-only spans preserve kerning and ligatures and features remain explicit`
- `explicit feature ranges direction and language reach HarfBuzz and reset per call`

Profile boundaries:

- Native Shaper's smaller feature/script profile is retained explicitly; full script shaping uses the optional adapter.
- HB shapes one caller-itemized run; callers segment distinct script/language/feature runs before combining outputs.

## Typography and internationalization

### ui.bidi_itemization — Bidi, script and language integration

**P1 · Implemented profile**

Retains Unicode bidi/isolation/script passes and logical/visual caret/selection mapping; paragraph direction is exposed and HB accepts explicit per-run language/script.

Implementation: [src/text/unicode/bidi.zig](../../src/text/unicode/bidi.zig), [src/text/unicode/script.zig](../../src/text/unicode/script.zig), [src/text/layout/lines.zig](../../src/text/layout/lines.zig), [src/text/layout/query.zig](../../src/text/layout/query.zig), [src/text/shape/harfbuzz.zig](../../src/text/shape/harfbuzz.zig).

Evidence:

- `BidiCharacterTest.txt: reordered lines draw in visual order`
- `BidiTest.txt: levels and order`
- `script runs: one script each, Common only where nothing else`
- `explicit feature ranges direction and language reach HarfBuzz and reset per call`

Profile boundaries:

- Full native Stack does not automatically convert arbitrary language tags into a multi-HB-run pipeline.
- Native ligature caret subdivision retains its equal-share policy unless caller metrics supply a finer external caret model.

### ui.cluster_fallback — Cluster-aware font fallback

**P0 · Implemented profile**

Fallback chooses a complete Unicode grapheme using nominal font coverage, preserves base+combining/ZWJ/variation sequences in one face and maintains actual face identity through layout/atlas lookup.

Implementation: [src/text/fallback/fallback.zig](../../src/text/fallback/fallback.zig), [src/text/layout/stack.zig](../../src/text/layout/stack.zig).

Evidence:

- `cluster fallback moves a base with its mark and never splits an unsupported sequence`
- `Stack fallback keeps a combining sequence in one face through shaping and line layout`

Profile boundaries:

- If no face covers the full cluster, the entire cluster stays with a first-scalar/current candidate and unresolved glyphs remain .notdef.
- Nominal coverage does not guarantee an emoji ZWJ/variation sequence has a single ligature.
- Rich spans have explicit face choices and do not automatically use the plain-paragraph fallback chain.

### ui.grapheme_editing — Grapheme-safe indexing and editing

**P0 · Implemented profile**

Preserves existing UTF-8/grapheme editing and navigation, adds whole-shaped-cluster truncation and read-only behavior across every mutation path.

Implementation: [src/text/edit/edit.zig](../../src/text/edit/edit.zig), [src/text/edit/moves.zig](../../src/text/edit/moves.zig), [src/text/edit/buffer.zig](../../src/text/edit/buffer.zig), [src/text/layout/break_policy.zig](../../src/text/layout/break_policy.zig), [src/text/unicode/grapheme.zig](../../src/text/unicode/grapheme.zig).

Evidence:

- `replayed input: typing, Backspace and Delete by grapheme, Enter`
- `replayed input: the caret moves by grapheme, word and line`
- `start middle and end truncation preserve complete clusters in real glyph output`
- `GraphemeBreakTest.txt`

Profile boundaries:

- Display transforms use explicit source maps; applications must use those maps when editing transformed display strings.

## Typography

### ui.paragraph_alignment — Paragraph alignment and justification

**P1 · Implemented profile**

Paragraph alignment exposes logical start/end, physical left/right, center, justification and last-line alignment; bidi placement and per-line width overrides use the same line geometry.

Implementation: [src/text/layout/stack.zig](../../src/text/layout/stack.zig), [src/text/layout/lines.zig](../../src/text/layout/lines.zig).

Evidence:

- `paragraph rows drive normal measure wrap query and transformed glyph emission`
- `golden: carets at every offset match the reference`

Profile boundaries:

- Justification is advance/space based; language-specific kashida insertion or glyph reshaping is not automatically performed.

### ui.whitespace_tabs — Whitespace, newlines and tabs

**P2 · Implemented profile**

Explicit preserve/collapse/preserve-breaks normalization maintains source offsets; paragraph tab size/width and wrapping modes use per-line tab origins and trailing-space handling.

Implementation: [src/text/layout/whitespace.zig](../../src/text/layout/whitespace.zig), [src/text/layout/lines.zig](../../src/text/layout/lines.zig), [src/text/layout/stack.zig](../../src/text/layout/stack.zig).

Evidence:

- `paragraph rows drive normal measure wrap query and transformed glyph emission`
- `intrinsic widths distinguish unbreakable words anywhere tabs and fit content in real layout`

Profile boundaries:

- Tab stops are periodic widths, not a mixed per-stop left/right/decimal tab ruler.
- Applications decide whether to normalize before a specialized external shaping pass.

### ui.wrap_hyphenation — Line-breaking policies and hyphenation

**P3 · Implemented profile**

UAX14 opportunities, word/keep-all/grapheme policies, emergency breaks, soft hyphens, caller dictionary opportunities and a real Liang Unicode-scalar pattern evaluator feed greedy or bounded quadratic balanced line breaking and visible hyphen marker quads. Explicit Unicode/default, strict, normal, loose and anywhere modes apply bounded Japanese/Chinese punctuation/kana/hyphen/iteration/affix distinctions to actual break opportunities.

Implementation: [src/text/layout/break_policy.zig](../../src/text/layout/break_policy.zig), [src/text/layout/lines.zig](../../src/text/layout/lines.zig), [src/text/layout/stack.zig](../../src/text/layout/stack.zig), [src/text/layout/tailoring.zig](../../src/text/layout/tailoring.zig), [src/text/unicode/style_properties.zig](../../src/text/unicode/style_properties.zig), [src/text/unicode/style_data.zig](../../src/text/unicode/style_data.zig), [src/text/unicode/make_style.py](../../src/text/unicode/make_style.py).

Evidence:

- `patterns create measured hyphen breaks consumed by standard line placement`
- `strict and loose CJK tailoring change real wrapped lines while keeping glue and clusters`

Profile boundaries:

- Locale hyphenation patterns/dictionaries and canonical casing are supplied by the caller; no bundled language corpus is claimed.
- Tailoring is the declared Unicode16 CJK profile; locale-specific Thai compound-word segmentation and additional publishing traditions require caller opportunities/dictionaries.
- Balanced breaking uses constant width and a declared candidate bound; variable leading-line widths use greedy mode and return UnsupportedPolicy for balanced.

### ui.text_overflow — Truncation and maximum visible lines

**P1 · Implemented profile**

Normal paragraphs clamp maximum lines with optional end ellipsis; optional start/middle/end truncation produces real retained glyph rows plus caller-shaped markers and source-range metadata.

Implementation: [src/text/layout/stack.zig](../../src/text/layout/stack.zig), [src/text/layout/lines.zig](../../src/text/layout/lines.zig), [src/text/layout/break_policy.zig](../../src/text/layout/break_policy.zig), [src/text/layout/emit.zig](../../src/text/layout/emit.zig).

Evidence:

- `paragraph rows drive normal measure wrap query and transformed glyph emission`
- `start middle and end truncation preserve complete clusters in real glyph output`

Profile boundaries:

- A fade is composed using paint/mask facilities rather than a separate glyph-breaking mode.
- Custom marker callers supply measured/shaped glyphs and matching atlas images.

### ui.line_metrics — Line height, leading and baseline metrics

**P2 · Implemented profile**

Paragraph absolute/factor line height and leading distribution use actual font metrics; inline measured boxes supply explicit baselines; document blocks carry before/after spacing; metric-based font-size-adjust changes real text measurement. Font/cap/x-height/em/alphabetic edge helpers trim actual outer line leading while preserving baseline distances; explicit baseline-coordinate rows and shifts update glyph offsets and line metrics together.

Implementation: [src/text/layout/stack.zig](../../src/text/layout/stack.zig), [src/text/layout/lines.zig](../../src/text/layout/lines.zig), [src/text/layout/inline_objects.zig](../../src/text/layout/inline_objects.zig), [src/text/font/match.zig](../../src/text/font/match.zig), [src/layout/document.zig](../../src/layout/document.zig), [src/text/layout/metrics.zig](../../src/text/layout/metrics.zig).

Evidence:

- `paragraph rows drive normal measure wrap query and transformed glyph emission`
- `font requests select actual family faces before the ordinary text measure pass`
- `inline replacement participates in wrapping baseline metrics and transformed image emission`
- `edge trim and selected last baselines drive glyph queries and native baseline layout`
- `span baseline selection changes real offsets and line-height metrics`

Profile boundaries:

- Non-alphabetic BASE/MATH coordinate values are explicit caller/shaper inputs; the core helper does not silently guess unavailable font baselines. Trimming is an explicit pass over formatted Lines.
- Font-size-adjust's native metric helper uses OS/2 or measured TrueType glyph data; extended HB-only faces can provide their own target metrics.

### ui.text_spacing — Letter and word spacing

**P2 · Implemented profile**

Letter and word spacing are consumed once per complete cluster, avoid trailing letter spacing and interact with justification through the shared advances. Font-relative values can be resolved by units.

Implementation: [src/text/layout/lines.zig](../../src/text/layout/lines.zig), [src/text/layout/stack.zig](../../src/text/layout/stack.zig), [src/layout/units.zig](../../src/layout/units.zig).

Evidence:

- `paragraph rows drive normal measure wrap query and transformed glyph emission`

Profile boundaries:

- Negative spacing is clamped to prevent negative cluster advances.
- Optional ligatures are disabled for nonzero native letter spacing; full contextual script spacing remains the selected shaper/profile's responsibility.

### ui.rich_run_segmentation — Rich text shaping runs versus paint spans

**P0 · Implemented profile**

Adjacent spans with equal font/size shape together, preserving ligatures/kerning across paint-only boundaries; glyphs retain independent actual font/metric span/color metadata and optional versioned shape-cache reuse.

Implementation: [src/text/layout/spans.zig](../../src/text/layout/spans.zig), [src/text/layout/stack.zig](../../src/text/layout/stack.zig), [src/text/layout/emit.zig](../../src/text/layout/emit.zig).

Evidence:

- `paint-only spans preserve kerning and ligatures and features remain explicit`
- `rich rows preserve shaping and expose per-glyph font size and inherited-opacity paint`

Profile boundaries:

- A glyph crossing paint boundaries takes its cluster-start color; it is not split into clipped multicolor ligature fragments.
- Explicit font/size boundaries begin new shaping groups.

### ui.text_decorations — Text decorations

**P2 · Implemented profile**

Real font underline/strike metrics, explicit overrides, underline/overline/strike, solid/double/dotted/dashed/wavy patterns and glyph-ink skipping produce transformed, clipped draw quads. Named/custom emphasis marks shape into real mark images and place per Unicode typographic unit using actual cluster geometry, optional line-height reservation, and upright vertical positions.

Implementation: [src/text/layout/decorations.zig](../../src/text/layout/decorations.zig), [src/text/layout/emphasis.zig](../../src/text/layout/emphasis.zig), [src/text/unicode/style_properties.zig](../../src/text/unicode/style_properties.zig), [src/text/unicode/style_data.zig](../../src/text/unicode/style_data.zig).

Evidence:

- `decorations consume font metrics patterns ink and transformed selection geometry`
- `emphasis uses ligature shares grapheme exclusions and reserved real line geometry`
- `vertical emphasis remains upright beside actual column geometry`

Profile boundaries:

- Skip-ink uses supplied glyph-image ink boxes, not a curve-exact outline subtraction.
- Hosts supply an appropriate mark atlas image/font; missing named glyphs return MissingGlyph. Ruby/decorations collisions use explicit gap/placement inputs rather than hidden global typography policy.

### ui.inline_objects_baselines — Inline objects and baseline shifts

**P3 · Implemented profile**

Measured U+FFFC replacements alter actual advances/line metrics, place by baseline/text/line alignment and emit image quads; ruby composes measured base/annotation boxes and reserve/overhang policy.

Implementation: [src/text/layout/inline_objects.zig](../../src/text/layout/inline_objects.zig).

Evidence:

- `inline replacement participates in wrapping baseline metrics and transformed image emission`
- `ruby reserves measured annotation space and becomes one inline object`

Profile boundaries:

- Object measurement/layout is an explicit pass; Stack does not call arbitrary embedded widget callbacks.
- Superscript/subscript math composition is owned by the separate optional math module.

### ui.text_paint_spans — Foreground, background and highlight paint for text

**P2 · Implemented profile**

Authored span foregrounds and selection/background range quads preserve TextRun transform, rounded clipping and inherited opacity without multiplying effective ordinary text color twice.

Implementation: [src/text/layout/emit.zig](../../src/text/layout/emit.zig), [src/text/layout/decorations.zig](../../src/text/layout/decorations.zig), [src/text/layout/stack.zig](../../src/text/layout/stack.zig), [src/text/layout/emphasis.zig](../../src/text/layout/emphasis.zig).

Evidence:

- `paragraph quads carry placement, span colour, marker, transform and rounded clipping`
- `rich rows preserve shaping and expose per-glyph font size and inherited-opacity paint`
- `decorations consume font metrics patterns ink and transformed selection geometry`
- `emphasis uses ligature shares grapheme exclusions and reserved real line geometry`

Profile boundaries:

- Gradient/stroke text uses the optional outline/path/paint consumers rather than a mandatory style field in every native glyph row.

## Typography and interaction

### ui.editing_parts — Editable text visual parts

**P2 · Implemented profile**

Real single-line and multiline editors consume content, placeholder, caret, selection foreground/background, support/error and focus recipes while retaining native editor selection/typing/read-only behavior. Selected foreground clips full shaped runs instead of splitting ligatures.

Bar/block/underline carets and arbitrary selection/decoration colors are real geometry consumers; editor retains composition and displayed/source offsets, with read-only blocking mutation and platform input requests.

Implementation: [src/theme/recipe.zig](../../src/theme/recipe.zig), [src/theme/recipe_controls.zig](../../src/theme/recipe_controls.zig), [src/theme/recipe_comptime.zig](../../src/theme/recipe_comptime.zig), [src/theme/recipe_parts.zig](../../src/theme/recipe_parts.zig), [src/text/edit/edit.zig](../../src/text/edit/edit.zig), [src/text/layout/decorations.zig](../../src/text/layout/decorations.zig).

Evidence:

- `recipe controls: runtime/comptime draw and behavior parity through click, drag, text and theme changes`
- `forced color selection uses HighlightText in both front ends without duplicate semantics`
- `multiline recipe routes typing, read-only policy and support part to real editor output`
- `caller usage: read-only slider and textfield preserve application values`
- `decorations consume font metrics patterns ink and transformed selection geometry`
- `read-only input preserves selection copy and navigation while rejecting every edit path`
- `replayed input: IME composition shows a preedit range; the commit is one undo step`

Profile boundaries:

- The stock single-line profile exposes four native selection bands and nine possible color intervals; distinct selected foreground requires bounded additional clip/text rows.
- Specialized IME underline styling, selection handles and richer prefix/suffix/editor decorations can be composed through the separate text decoration/part APIs; the standard recipe does not implement every editor chrome policy.
- Blink scheduling, placeholder, prefix/suffix, inactive colors and selection handles are component/host recipe inputs rather than hidden text-editor global policy.

## Typography and internationalization

### ui.locale_text_transform — Locale-aware display text transformations

**P3 · Implemented profile**

Unicode16 full lower/upper/title/capitalize mappings include expansions, Greek final sigma, Turkish/Azeri/Lithuanian context and Dutch IJ; full-width and grapheme masking preserve explicit display/source offset maps.

Implementation: [src/text/layout/display.zig](../../src/text/layout/display.zig), [src/text/layout/whitespace.zig](../../src/text/layout/whitespace.zig), [src/text/unicode/display_data.zig](../../src/text/unicode/display_data.zig), [src/text/unicode/make_display.py](../../src/text/unicode/make_display.py).

Evidence:

- `display casing expands Unicode and preserves original editing offsets`
- `display masks whole graphemes and orientation distinguishes vertical alternates`

Profile boundaries:

- Casing locale selection is the declared root/tr/az/lt/nl profile, not an implicit system locale lookup.
- Localized number/date formatting is a separate application service.

## Typography

### ui.advanced_typographic_features — OpenType typographic variants

**P3 · Implemented profile**

Arbitrary OpenType feature tags and ranges are passed to real HB shaping, covering numeral forms, small caps, fractions, slashed zero, stylistic sets, alternates and localized forms when the selected font supplies them.

Implementation: [src/text/shape/harfbuzz.zig](../../src/text/shape/harfbuzz.zig).

Evidence:

- `explicit feature ranges direction and language reach HarfBuzz and reset per call`

Profile boundaries:

- A requested feature cannot create glyphs absent from the font; no synthetic small-caps/figure construction is silently substituted.

## Typography infrastructure

### ui.text_cache_contract — Text cache and invalidation contract

**P0 · Implemented profile**

Optional caller-owned native and HB shaping caches carry explicit font identity/reload generation; HB keys include all feature/language/script/direction/cluster/variation/synthesis settings. Native paint-only spans reuse shaping, and existing atlas ownership remains explicit. Embedded PNG strike selection restores prior ppem state, so raster extraction cannot silently alter later shaping/cache behavior.

Implementation: [src/text/shape/cache.zig](../../src/text/shape/cache.zig), [src/text/layout/spans.zig](../../src/text/layout/spans.zig), [src/text/layout/stack.zig](../../src/text/layout/stack.zig), [src/text/shape/harfbuzz.zig](../../src/text/shape/harfbuzz.zig), [src/text/raster/atlas.zig](../../src/text/raster/atlas.zig).

Evidence:

- `caller generations prevent reloaded font data from reusing stale cached advances`
- `measure and wrap fill w, h and ascent of the runs in this stack's fonts`
- `optional HarfBuzz cache separates variable instances features language and font generations`
- `glyph images survive eviction and repacking`
- `bitmap color fonts decode with the existing PNG path and SVG extraction is explicit`

Profile boundaries:

- No mandatory font-match or paragraph-layout cache is introduced; callers can retain their plain result rows.
- Caller resource lifetime/generation discipline is required; omitted native IDs default to local face index and generation zero.
- The existing bounded cache uses 63-bit hash identity with the documented collision tradeoff.

## Optional typography

### ui.vertical_ruby — Vertical writing and ruby annotations

**P5 · Implemented profile**

Actual HB vertical advances/substitutions feed bounded RL/LR columns, upright/sideways glyph transforms and UAX50 orientation; explicit measured ruby annotations compose into inline boxes. Upright vertical emphasis marks consume real pens/advances and explicit arranged column boxes.

Implementation: [src/text/layout/vertical.zig](../../src/text/layout/vertical.zig), [src/text/layout/display.zig](../../src/text/layout/display.zig), [src/text/layout/inline_objects.zig](../../src/text/layout/inline_objects.zig), [src/text/shape/harfbuzz.zig](../../src/text/shape/harfbuzz.zig), [src/text/layout/emphasis.zig](../../src/text/layout/emphasis.zig).

Evidence:

- `real vertical advance rows form right-to-left columns and upright or sideways quads`
- `vertical HarfBuzz advances feed the bounded vertical layout consumer`
- `ruby reserves measured annotation space and becomes one inline object`
- `vertical emphasis remains upright beside actual column geometry`

Profile boundaries:

- Vertical-alternate availability is an explicit caller/shaper fact; no alternate is fabricated from Unicode orientation alone.
- This is measured vertical/ruby composition, not the complete CSS ruby line-breaking and annotation-merging algorithm.
- Vertical emphasis space is reserved by caller column width/gap inputs; placing marks does not silently move already-arranged columns.

## Optional document and specialized layout

### ui.document_typography — Specialist document typography

**P5 · Implemented profile**

Optional measured mathematical composition and OpenType MATH metrics/variants/assemblies; shaped glyph placement along native polyline tangents; drop-cap width/origin integration; optical edge punctuation; bounded UTF-8 counter systems/scopes and baseline-aligned list markers. All use native glyph/rule/quad consumers without ordinary label storage.

Implementation: [src/text/layout/math.zig](../../src/text/layout/math.zig), [src/text/layout/ornament.zig](../../src/text/layout/ornament.zig), [src/text/layout/counters.zig](../../src/text/layout/counters.zig).

Evidence:

- `fraction enters inline layout and positions real paragraph quads plus rule`
- `scripts limits radicals and matrices reserve actual measured extents`
- `OpenType MATH constants and extender assembly become glyph quads with bounded storage`
- `shaped line follows native path tangents and retains transform opacity clipping`
- `drop cap changes real line breaks positions and caret coordinates in both directions`
- `hanging edge punctuation moves glyphs and carets together without splitting clusters`
- `counter systems format UTF8 exact integers and reject invalid and insufficient storage`
- `nested scoped counters reset increment and format without mutating ancestors`
- `formatted list marker becomes baseline aligned paragraph glyphs and ordinary bullet quads`

Profile boundaries:

- No TeX/MathML parser or formula AST; callers shape leaves, choose script sizes and supply measured boxes. MATH device hint corrections are not evaluated.
- Text-on-path caret/hit projection remains caller work; path rendering retains source clusters and transforms.
- Drop-cap variable leading widths use the greedy breaker; balanced breaking returns UnsupportedPolicy. Hanging punctuation preserves existing breaks rather than reoptimizing justified paragraphs.
- Counter algorithms have declared native conventions rather than complete CSS Counters/CLDR conformance. Footnotes/pagination belong to separate document-layout modules.

## Interaction styling

### ui.cursor_styles — Pointer cursor appearance

**P2 · Implemented profile**

35 cursor values with inheritance/default reset, platform mappings and declared fallback fidelity. Custom images use an ordinary texture quad with explicit hotspot, hardware hiding and old/new damage.

Implementation: [src/core/types.zig](../../src/core/types.zig), [src/runtime/frame.zig](../../src/runtime/frame.zig), [src/draw/cursor.zig](../../src/draw/cursor.zig), [src/shell/win32/win32.zig](../../src/shell/win32/win32.zig), [src/shell/macos/macos.zig](../../src/shell/macos/macos.zig), [src/shell/wayland/wayland.zig](../../src/shell/wayland/wayland.zig), [src/shell/x11/x11.zig](../../src/shell/x11/x11.zig), [src/shell/web/shell.js](../../src/shell/web/shell.js).

Evidence:

- `setCursor: the last request that holds wins; the next frame starts at arrow`
- `style cursor inherits through paint extras and explicit arrow overrides it`
- `custom cursor uploads through ordinary image draw, respects hotspot and damages movement`
- `x11: the cursor the frame asks for is the one the server shows`

Profile boundaries:

- Windows/macOS methods were cross-compiled; actual native sessions were unavailable. Wayland protocol/fallback fixtures and Web syntax were checked.
- The caller owns custom-image upload and final quad emission; platform-specific unavailable cursor shapes use documented fallbacks.

### ui.hit_target_geometry — Visual and hit-target geometry policy

**P0 · Implemented profile**

Caller-owned sorted hit-policy entries add local padding/minimum dimensions and rectangle/rounded/ellipse/path shapes. The chosen hit drives the ordinary capture/release path; runtime and pure compile-time use common inverse-transform and ancestor-clip geometry. Simultaneous contacts use caller-computed rows through Touches.stepWithHits while retaining capture by platform contact ID.

Implementation: [src/interact/targets.zig](../../src/interact/targets.zig), [src/runtime/context.zig](../../src/runtime/context.zig), [src/interact/interaction.zig](../../src/interact/interaction.zig), [src/comptime/events.zig](../../src/comptime/events.zig), [src/comptime/paint.zig](../../src/comptime/paint.zig).

Evidence:

- `expanded transformed targets preserve clipping, ordering, real activation and unchanged paint`
- `path targets share evenodd/nonzero holes and validate ambiguous expansion`
- `expanded targets agree across pure comptime and layered runtime input`
- `pure comptime affine painting and exact hit agree with the runtime tree`
- `Touches: enlarged caller targets preserve capture across reordered contacts and reject count changes atomically`
- `Touches: removed hidden or nonsensing owners cancel before missing-contact release and cannot reactivate mid-press`
- `shared choice slots paint and hit only the active hosted region`
- `unshared inactive choice targets stay absent while ordinary offscreen targets can expand`

Profile boundaries:

- Path expansion is deliberately rejected; callers must provide a dilated path when needed. Empty/collapsed rows are never revived.
- Pure compile-time target enumeration uses descriptor order; runtime accepts explicit layer rows.

### ui.focus_policy — Keyboard-visible focus styling policy

**P1 · Implemented profile**

Actual input modality and always-show-focus select an independent focus part; the native outside outline references current border-box geometry without layout or hit participation. Selection/hover styling does not replace the ring.

Implementation: [src/theme/recipe.zig](../../src/theme/recipe.zig), [src/theme/recipe_controls.zig](../../src/theme/recipe_controls.zig), [src/theme/recipe_comptime.zig](../../src/theme/recipe_comptime.zig), [src/theme/recipe_extra_controls.zig](../../src/theme/recipe_extra_controls.zig), [src/style/accessibility.zig](../../src/style/accessibility.zig).

Evidence:

- `default recipe respects environment text scale and keeps focus separate from selected border`
- `recipe disabled state cancels capture, skips Tab and cannot be defeated by a visual override`
- `radio and range recipes preserve keyboard and pointer behavior with shared marks and two visible thumbs`
- `native outline can satisfy AA focus visibility while failing the separate AAA area diagnostic`

Profile boundaries:

- Focus-within and focus-scroll policy are explicit owner/runtime inputs; no semantic relationship is inferred from decorative part names.
- Visibility, adjacent contrast and AAA changed-pixel area are separate diagnostics rather than a compliance certification.

### ui.disabled_readonly_semantics — Behavioral state and visual-state consistency

**P0 · Implemented profile**

Authoritative disabled/read-only state gates real behavior in both front ends, cancels stale capture and preserves allowed read-only navigation. Invalid/required/busy use reserved u16 semantic bits with existing ordinals intact, survive Export/diff and reach AccessKit properties.

Mode.read_only retains navigation, selection and copy while rejecting typing, deletion, cut/paste, undo/redo mutation and IME commit; it cancels preedit and avoids keyboard input requests.

Implementation: [src/theme/recipe_controls.zig](../../src/theme/recipe_controls.zig), [src/theme/recipe_comptime.zig](../../src/theme/recipe_comptime.zig), [src/theme/recipe_extra_controls.zig](../../src/theme/recipe_extra_controls.zig), [src/widgets/base.zig](../../src/widgets/base.zig), [src/a11y/tree.zig](../../src/a11y/tree.zig), [src/a11y/accesskit/c.zig](../../src/a11y/accesskit/c.zig), [src/a11y/accesskit/bridge.zig](../../src/a11y/accesskit/bridge.zig), [src/text/edit/edit.zig](../../src/text/edit/edit.zig).

Evidence:

- `recipe disabled state cancels capture, skips Tab and cannot be defeated by a visual override`
- `recipe read-only checkbox remains focusable and its pointer event is explicitly suppressed`
- `caller usage: read-only slider and textfield preserve application values`
- `extra recipe controls cancel disabled capture and keep read-only groups focusable without changes`
- `tree export: validation requirement and busy state retain the existing compact state ABI`
- `diagnostics compare recipe state with actual exported semantics including validation and busy`
- `accesskit: a text input's text goes out as its value, its placeholder as placeholder`
- `read-only input preserves selection copy and navigation while rejecting every edit path`

Profile boundaries:

- Busy, invalid and required are distinct from disabled; applications choose their validation/action policy.
- The inspected Web shell has no DOM semantic-tree or JSON state serializer; host Web accessibility integration is not claimed.
- Native AccessKit execution is a separate optional build gate and must be read with the validation record.
- Other component states are handled by root/theme recipe consumers; this row covers the authoritative editor behavior only.

## Accessibility and environment

### ui.contrast_system_palettes — High contrast and system color palettes

**P1 · Implemented profile**

Portable light/dark high-contrast palettes and host-supplied opaque semantic colors cover canvas/field/button/link/highlight/selection/mark/accent roles; final automatic policy preserves visible boundaries, supplies paired foregrounds and records provenance, with explicit per-component preserve exceptions.

Implementation: [src/style/system_colors.zig](../../src/style/system_colors.zig), [src/style/environment.zig](../../src/style/environment.zig), [src/theme/recipe.zig](../../src/theme/recipe.zig), [src/theme/recipe_controls.zig](../../src/theme/recipe_controls.zig), [src/theme/recipe_comptime.zig](../../src/theme/recipe_comptime.zig), [src/style/accessibility.zig](../../src/style/accessibility.zig).

Evidence:

- `both high contrast profiles preserve text controls selection and visible boundaries`
- `system colors override authored paint with provenance and explicit component exceptions`
- `forced color selection uses HighlightText in both front ends without duplicate semantics`
- `diagnostics consume resolved high contrast recipes and keep unknown backgrounds explicit`

Profile boundaries:

- The resolver consumes host color data and does not itself query native system palettes.
- Arbitrary host palettes, images, filters and translucent backdrops require actual samples; no universal contrast guarantee is inferred from a semantic role name.

### ui.text_scale_tolerance — User text scale and spacing tolerance

**P0 · Implemented profile**

Explicit text scaling updates semantic type tokens and actual text metrics; paragraph line/letter/word spacing overrides reach Stack layout; fit-sized controls expand for longer localized labels.

Text size, metric-based size adjustment, line/word/letter spacing and actual intrinsic/wrapped remeasurement are exposed to caller theme/text-scale policy.

Implementation: [src/style/environment.zig](../../src/style/environment.zig), [src/style/paragraph.zig](../../src/style/paragraph.zig), [src/theme/recipe.zig](../../src/theme/recipe.zig), [src/style/locale.zig](../../src/style/locale.zig), [src/text/layout/stack.zig](../../src/text/layout/stack.zig), [src/text/font/match.zig](../../src/text/font/match.zig), [src/text/layout/intrinsic.zig](../../src/text/layout/intrinsic.zig), [src/layout/units.zig](../../src/layout/units.zig).

Evidence:

- `default recipe respects environment text scale and keeps focus separate from selected border`
- `caller usage: resolved paragraph tokens drive the real shaping and multiline layout path`
- `locale font preferences and labels lower to real Frame text rows`
- `font requests select actual family faces before the ordinary text measure pass`
- `paragraph rows drive normal measure wrap query and transformed glyph emission`
- `intrinsic widths distinguish unbreakable words anywhere tabs and fit content in real layout`

Profile boundaries:

- Environment textFactor clamps the convenience scale to 0.5..4; direct typed sizes remain available.
- Applications still choose wrapping, scroll/reflow, maximum dimensions and minimum hit policies; no automatic claim is made that every fixed-size custom layout remains usable at every text setting.
- The toolkit does not guarantee every application avoids clipping; hosts must remeasure after user scale/spacing changes and choose content-preserving constraints.

### ui.reduced_effect_preferences — Reduced motion and transparency preferences

**P1 · Implemented profile**

Host reduced-motion/reduced-transparency inputs select explicit duration/surface alternatives while preserving existing runtime motion policy. Busy spinners use a stable phase and stop requesting visual updates under reduced motion, with equivalent runtime/CT output.

Implementation: [src/style/environment.zig](../../src/style/environment.zig), [src/theme/recipe.zig](../../src/theme/recipe.zig), [src/theme/recipe_extra_controls.zig](../../src/theme/recipe_extra_controls.zig), [src/widgets/base.zig](../../src/widgets/base.zig).

Evidence:

- `known accessibility inputs consume existing settings and explicit effect choices`
- `recipe spinner requests frames while busy and has a stable reduced-motion alternative in both front ends`
- `recipe spinner wake follows effective ancestor participation and the bound busy state in both front ends`

Profile boundaries:

- Essential animation is an explicit caller decision; arbitrary custom effects and scroll policy must consume the same preferences through their own native interfaces.
- Decorative surface opacity policy does not forcibly alter content/group alpha that may carry application meaning.

### ui.noncolor_semantics — State indication beyond color

**P1 · Implemented profile**

Checkbox checked/mixed marks, radio dots, moving switch/range thumbs, selected navigation indicators, text labels and support/error parts provide shapes or content in addition to color, with matching authoritative semantic-state export.

Implementation: [src/theme/recipe.zig](../../src/theme/recipe.zig), [src/theme/recipe_controls.zig](../../src/theme/recipe_controls.zig), [src/theme/recipe_extra_controls.zig](../../src/theme/recipe_extra_controls.zig), [src/theme/recipe_parts.zig](../../src/theme/recipe_parts.zig), [src/a11y/tree.zig](../../src/a11y/tree.zig).

Evidence:

- `system colors override authored paint with provenance and explicit component exceptions`
- `radio and range recipes preserve keyboard and pointer behavior with shared marks and two visible thumbs`
- `data and navigation parts feed actual semantic rows and tab selection behavior`
- `multiline recipe routes typing, read-only policy and support part to real editor output`
- `diagnostics compare recipe state with actual exported semantics including validation and busy`

Profile boundaries:

- Applications supply meaningful support/error wording and any domain-specific icon/pattern; the framework does not infer the meaning of arbitrary data.

## Scrolling

### ui.scrollbar_parts — Scrollbar part appearance

**P2 · Implemented profile**

Actual two-axis viewport emits styled track/thumb/corner/optional arrow parts and semantics, with hover/drag/input behavior and minimum thumb geometry.

Implementation: [src/widgets/scroll_area.zig](../../src/widgets/scroll_area.zig), [src/layout/scroll_policy.zig](../../src/layout/scroll_policy.zig).

Evidence:

- `two-axis styled viewport consumes input and emits semantic bars through ordinary Frame`
- `both-axis gutters converge, mirror and position thumbs with real offsets`
- `chaining, snap stops, reveal padding and content anchoring combine predictably`

Profile boundaries:

- The caller provides content extent and per-axis scroll state; visibility follows measured need and chosen gutter policy.

### ui.scrollbar_layout — Scrollbar axes, placement and gutters

**P2 · Implemented profile**

Overlay/classic/stable/both-edge gutters converge on a two-axis viewport, with configurable sides, RTL placement, thickness and corners.

Implementation: [src/widgets/scroll_area.zig](../../src/widgets/scroll_area.zig), [src/layout/scroll_policy.zig](../../src/layout/scroll_policy.zig).

Evidence:

- `two-axis styled viewport consumes input and emits semantic bars through ordinary Frame`
- `both-axis gutters converge, mirror and position thumbs with real offsets`
- `chaining, snap stops, reveal padding and content anchoring combine predictably`

Profile boundaries:

- When both axes alter available space, the bounded resolution pass decides whether each scrollbar is required.

### ui.scroll_behavior_policy — Optional scroll behavior policies

**P3 · Implemented profile**

Scroll consumption reports remainder for chaining, enforces axis/overscroll policy, chooses snap positions/stops, and composes with the existing caller-stepped scroll motion helpers.

Implementation: [src/layout/scroll_policy.zig](../../src/layout/scroll_policy.zig), [src/layout/scroll.zig](../../src/layout/scroll.zig), [src/widgets/scroll_area.zig](../../src/widgets/scroll_area.zig).

Evidence:

- `chaining, snap stops, reveal padding and content anchoring combine predictably`
- `clamp: scroll stays between the content start and its end`
- `scroll: a long list scrolled by a wheel, then to a focused row, with a sticky header`

Profile boundaries:

- Momentum/smooth timing is an explicit application policy; the geometry helper does not install an event loop or scheduler.

### ui.scroll_focus_reveal — Focused target reveal and scroll anchoring

**P1 · Implemented profile**

Nested reveal consumes target geometry, scroll padding/margin and current viewports; anchoring adjusts position when measured content changes.

Implementation: [src/layout/scroll_policy.zig](../../src/layout/scroll_policy.zig), [src/layout/scroll.zig](../../src/layout/scroll.zig).

Evidence:

- `chaining, snap stops, reveal padding and content anchoring combine predictably`

Profile boundaries:

- The host invokes reveal/anchor when focus or content changes and chooses instant versus animated movement.

## Component styling

### ui.control_part_catalog — Everyday control part recipes

**P2 · Implemented profile**

Dedicated shared-recipe adapters cover button/icon/label, checkbox/radio marks, switch, slider/two-thumb range, progress, spinner, single-line input and multiline editor/support parts. Radio/range reuse existing pure key/pointer behavior; spinner scheduling honors reduced motion. Composite failures preserve inert descriptor rows for later siblings and recover on the next valid frame; row participation is checked before actions; spinner wakes follow the completed subtree and bound busy state.

Implementation: [src/theme/recipe.zig](../../src/theme/recipe.zig), [src/theme/recipe_controls.zig](../../src/theme/recipe_controls.zig), [src/theme/recipe_comptime.zig](../../src/theme/recipe_comptime.zig), [src/theme/recipe_extra_controls.zig](../../src/theme/recipe_extra_controls.zig), [src/theme/recipe_extra_tests.zig](../../src/theme/recipe_extra_tests.zig), [src/theme/recipe_parts.zig](../../src/theme/recipe_parts.zig).

Evidence:

- `caller usage: custom icon/label retains button activation and disabled prevents it`
- `recipe controls: runtime/comptime draw and behavior parity through click, drag, text and theme changes`
- `radio and range recipes preserve keyboard and pointer behavior with shared marks and two visible thumbs`
- `extra recipe controls cancel disabled capture and keep read-only groups focusable without changes`
- `recipe spinner requests frames while busy and has a stable reduced-motion alternative in both front ends`
- `multiline recipe routes typing, read-only policy and support part to real editor output`
- `recipe spinner wake follows effective ancestor participation and the bound busy state in both front ends`
- `failed composite recipes preserve CT rows and later button activation then recover on the next frame`
- `combined state and environment row participation cancels captured range and radio actions in both front ends`

Profile boundaries:

- Range thumb and spinner-root dimensions are validated fixed pixel sizes in these convenience builders.
- Value bubbles, arbitrary tick collections and application-specific input prefix/suffix composition use explicit additional parts; they are not synthesized by the standard controls.

### ui.navigation_overlay_parts — Navigation and overlay part recipes

**P2 · Implemented profile**

Dedicated runtime menu, popover, tooltip, breadcrumb and toast compositions resolve plain recipe values into actual Frame rows and Texts while reusing native pure behavior. Compile-time Menu/Popover/Tooltip/Toast hooks reuse ComptimePage, and breadcrumb reuses ComptimeUi focus handling. Dynamic token/recipe/environment and optional menu content spans are caller-owned. Accelerator and indicator strings use named styled parts, separators emit actual noninteractive geometry and are skipped by menu navigation. Tooltip arrows are optional transformed-shape rows with independently resolved paint/geometry. Popover Part.text/Part.content optionally override label typography/bytes, preserving bound labels when null. Label bytes are borrowed until the existing bounded Strings copy; CT recipe content preflights remaining string capacity and reports NoSpace without overwriting. Recipe failures occur before runtime menu action commit; CT hook failure_field retains the first error until the next step. Hidden/collapsed popup panels remove their scrims, while read-only focused controls retain tooltips.

Dedicated shared-recipe menu/popover/tooltip/breadcrumb/toast compositions, plus navigation rows and tabs, reuse existing caller-owned state and pure behavior. Runtime/CT consumers exercise typography, menu accelerators/indicators/separators, optional tooltip arrows, submenu keys, disabled/read-only rows, focus, hidden popup/scrim participation, deadlines, Escape, explicit failure and ordinary popup children.

Implementation: [src/theme/recipe_overlays.zig](../../src/theme/recipe_overlays.zig), [src/widgets/popover.zig](../../src/widgets/popover.zig), [src/theme/recipe.zig](../../src/theme/recipe.zig), [src/theme/recipe_parts.zig](../../src/theme/recipe_parts.zig).

Evidence:

- `recipe menu: disabled items are skipped and read-only items cannot activate`
- `recipe menu: runtime and CT consume dynamic typography tokens and the same submenu keys`
- `overlay recipes: runtime popup content tooltip focus toast deadline and breadcrumb roles are consumed`
- `recipe popover: CT typography is opt-in per label and Escape closes the native overlay`
- `recipe overlays: CT tooltip focus and reduced-motion toast use the styled label consumer`
- `recipe breadcrumb: CT links follow Enter keep focus outlines and reject disabled activation`
- `recipe overlays: resolution failure is explicit preserves menu state and resets next frame only`
- `recipe menu accessories: runtime and CT style accelerators indicators separators and skip separator actions`
- `recipe tooltip arrow: optional part styles real geometry in runtime and CT without input or extra layout`
- `recipe overlay participation: hidden popup removes its scrim and read-only focused controls retain help`
- `data and navigation parts feed actual semantic rows and tab selection behavior`

Profile boundaries:

- ComptimePage does not own a keyboard focus manager. Its host supplies trigger focused/focus_visible state; open-menu keyboard sequences and Escape use the native menu behavior. ComptimeUi breadcrumb owns its normal focus chain.
- Call floating overlays after ordinary content under the root. Native placement uses previous trigger geometry below the trigger (or beside a submenu trigger); this adapter does not choose viewport-flipping placement automatically.
- Callers explicitly sequence frames while CT tooltip/toast timers are live. Runtime adapters request motion deadlines through the existing context.
- Arbitrary caller popup children preserve their original styles; H.label explicitly opts CT content labels into the popup recipe.
- Accelerators are display text; registering actual shortcuts remains the native caller-owned input/shortcut operation. MenuContent indicator text can represent submenu arrows; complex arrow textures/materials remain caller-owned.
- Tooltip arrow defaults to a transformed square and is opt-in. Its named part may supply caller-owned texture/material resources. It does not change the native fixed-below placement policy.
- The specialized native ComptimePage has no focus manager; its host supplies trigger focused/focus_visible state while native open-menu keyboard behavior runs.
- Overlay placement uses the native previous-frame anchor geometry and root-level floating layer contract.
- Arbitrary popup children keep their caller styles; named label opt-in applies recipe typography without rewriting unrelated content.
- Optional tooltip arrows are independently styled ordinary shapes with explicit border-box-relative placement; sophisticated anchor-aware arrow geometry remains caller-owned.

### ui.data_view_parts — List, tree and table visual parts

**P2 · Implemented profile**

Shared header/row/cell/disclosure/separator/selection recipes produce actual semantic table rows and matching runtime/CT draw output; arbitrary state/variant IDs permit logical-row striping and custom data-view marks without a retained model.

Implementation: [src/theme/recipe.zig](../../src/theme/recipe.zig), [src/theme/recipe_parts.zig](../../src/theme/recipe_parts.zig), [src/theme/recipe_part_comptime.zig](../../src/theme/recipe_part_comptime.zig), [src/style/resolve.zig](../../src/style/resolve.zig).

Evidence:

- `data and navigation parts feed actual semantic rows and tab selection behavior`
- `data part composition has runtime/comptime parity with dynamic state and environment`
- `caller usage: simultaneous states, orthogonal variants and local transparent overrides`

Profile boundaries:

- Sorting, virtualization reconciliation, frozen columns, row/column identity and selection storage remain caller-owned; derive style state from logical items rather than recycled visible slots.

## Application-specific styling

### ui.editor_canvas_parts — Extensible EDA and editor visual vocabulary

**P3 · Implemented profile**

Application-defined part/token identifiers lower to ordinary native box/text values and portable rendering inputs; generic open/text/leaf composition and editor gutter/line-number/support recipes need no EDA-specific core branch or registry.

Implementation: [src/style/resolve.zig](../../src/style/resolve.zig), [src/theme/recipe.zig](../../src/theme/recipe.zig), [src/theme/recipe_controls.zig](../../src/theme/recipe_controls.zig), [src/theme/recipe_parts.zig](../../src/theme/recipe_parts.zig).

Evidence:

- `recipe caller: custom thumb and app-defined part use direct data, no registry`
- `caller usage: custom icon/label retains button activation and disabled prevents it`
- `data part composition has runtime/comptime parity with dynamic state and environment`

Profile boundaries:

- Grid/port/wire/snap geometry, custom bounds and application semantics remain authored by the application using the portable primitive/custom drawing APIs.

## Style tooling

### ui.a11y_style_validation — Accessibility style diagnostics

**P2 · Implemented profile**

Bounded diagnostics report actual sampled contrast pairs, unknown backdrops, explicit target-size policy, missing focus outlines and semantic-state mismatches. Separate criterion labels and observed changed-pixel regions distinguish AA focus visibility/adjacent contrast from AAA focus appearance area and explicit exceptions.

Implementation: [src/style/accessibility.zig](../../src/style/accessibility.zig), [src/style/inspector.zig](../../src/style/inspector.zig), [src/style/system_colors.zig](../../src/style/system_colors.zig), [src/a11y/tree.zig](../../src/a11y/tree.zig).

Evidence:

- `diagnostics consume resolved high contrast recipes and keep unknown backgrounds explicit`
- `diagnostics compare recipe state with actual exported semantics including validation and busy`
- `native outline can satisfy AA focus visibility while failing the separate AAA area diagnostic`
- `both high contrast profiles preserve text controls selection and visible boundaries`

Profile boundaries:

- These are diagnostic data for host inspection/preview, not an automatic WCAG certification.
- The caller supplies final opaque samples, disjoint changed regions, perceived component geometry and any exception; occlusion, duration, neighboring target spacing, total reflow and unknown preference support are not guessed.

## Responsive styling

### ui.locale_theme_content — Locale-aware component presentation

**P3 · Implemented profile**

Caller-owned translation rows, exact-decimal numeral/grouping data, ordered locale font preferences and explicit directional-icon mirroring feed real labels/styles. Optional RTL/rounding conveniences sequence shared runtime/CT layout while preserving source semantic and keyboard reading order.

Implementation: [src/style/locale.zig](../../src/style/locale.zig), [src/style/environment.zig](../../src/style/environment.zig), [src/theme/recipe_controls.zig](../../src/theme/recipe_controls.zig), [src/widgets/base.zig](../../src/widgets/base.zig).

Evidence:

- `locale numeric data maps exact integers groups digits and decimal punctuation`
- `locale font preferences and labels lower to real Frame text rows`
- `runtime and comptime locale layout mirror boxes while Tab keeps source reading order`

Profile boundaries:

- No built-in translation/locale database or automatic remote font loading.
- Exponent/currency/percent formatting is supplied as host content; the exact-decimal helper rejects unsupported syntax.
- RTL side-table capacity must cover the entire built tree; automatic semantic reordering is deliberately absent.

## Rendering contracts

### visual.capability_profiles — Declared renderer capabilities and fallback policy

**P0 · Implemented profile**

Explicit stock and portable_sdr profiles; checked exact/approximation/unsupported decisions before submission.

Implementation: [src/render/capabilities.zig](../../src/render/capabilities.zig), [src/render/prepared.zig](../../src/render/prepared.zig).

Evidence:

- `capability decisions reject unaccepted approximation before preparing pixels`
- `checked rendering rejects stripped shaders before an ordinary backend draw`
- `image brush sampling requests preparation rather than a backend-default sampler`
- `drawRange rejects borrowed coverage aliases before modifying destination or scratch`
- `applyClips rejects aliased coverage in either clip list before modifying pixels`

Profile boundaries:

- Portable preparation requires caller-owned pixels and texture upload; raw Tier-0 backend calls remain caller-controlled.
- Native HDR, native materials, custom materials, inline custom and depth scenes are separate host capabilities; not inferred from OS names.

### visual.paint_bounds — Shared conservative paint bounds

**P0 · Implemented profile**

Common affine bounds for ordinary draw kinds; portable decorations report outward-aligned bounds.

Implementation: [src/draw/geometry.zig](../../src/draw/geometry.zig), [src/draw/damage.zig](../../src/draw/damage.zig), [src/draw/decoration.zig](../../src/draw/decoration.zig), [src/render/prepared.zig](../../src/render/prepared.zig).

Evidence:

- `paint bounds follow translated shadows and reject singular transforms`
- `damage: a resized node repaints the union of its old and new rect, one rect`
- `gradient border shadow and separate focus outline coexist in one texture`

Profile boundaries:

- Analytic shadow bounds use three sigma; true content-filter output bounds are explicit caller surfaces.
- The host must include a changed prepared resource revision in its frame/update flow.

### visual.alpha_representation — Alpha and color-transfer contracts

**P0 · Implemented profile**

RGBA8 effect surfaces are premultiplied encoded sRGB; upload export is explicitly straight. HDR planes are separate linear-light absolute luminance.

Implementation: [src/draw/surface.zig](../../src/draw/surface.zig), [src/draw/brushes.zig](../../src/draw/brushes.zig), [src/draw/compositor.zig](../../src/draw/compositor.zig), [src/draw/color_output.zig](../../src/draw/color_output.zig), [src/render/gles/styling.zig](../../src/render/gles/styling.zig).

Evidence:

- `texture export changes alpha representation once and preserves zero alpha`
- `bilinear sampling prevents a transparent red fringe and respects placement`
- `area filtering retains odd edges and premultiplies before linear light filtering`
- `ES3 prepared gradient border shadow isolated mask texture agrees with software within two bytes`
- `ES2 prepared gradient border shadow isolated mask texture agrees with software within two bytes`

Profile boundaries:

- RGBA8 preparation quantizes intermediate passes; float HDR processing is a separate explicit pipeline.
- The current texture shader premultiplies input, so exporting a premultiplied image to it without conversion is incorrect.

### visual.coordinate_spaces — Coherent paint, clip, text and hit coordinate spaces

**P0 · Implemented profile**

Layout, paint, text/custom transforms, inverse pointer mapping and exact ancestor rounded clips share explicit geometry.

Implementation: [src/draw/geometry.zig](../../src/draw/geometry.zig), [src/draw/paint.zig](../../src/draw/paint.zig), [src/draw/draw_list.zig](../../src/draw/draw_list.zig), [src/interact/hit.zig](../../src/interact/hit.zig), [src/render/prepared.zig](../../src/render/prepared.zig).

Evidence:

- `transformed pointer and rounded ancestor clip agree with paint geometry`
- `ordinary quad text and custom commands participate in an exact clipped isolated group`

Profile boundaries:

- Singular transforms do not produce interactive geometry; portable inverse-transform operations reject invalid matrices.
- Perspective hit mapping is a separate projective-plane operation, not silently inferred by ordinary 2D hit testing.

### visual.clip_geometry_contract — Shared clip geometry across draw kinds

**P0 · Implemented profile**

Rectangular fast paths remain direct; nested transformed rounded/path coverage clips use the portable prepared route.

Implementation: [src/draw/decoration.zig](../../src/draw/decoration.zig), [src/render/prepared.zig](../../src/render/prepared.zig), [src/draw/draw_list.zig](../../src/draw/draw_list.zig).

Evidence:

- `ordinary quad text and custom commands participate in an exact clipped isolated group`
- `existing path coverage feeds clips without a retained path manager`

Profile boundaries:

- Inline custom content participates in portable grouping only when a caller-provided raster image is supplied; missing content is an error.

### visual.decoration_composition — Composition of multiple visual decorations

**P0 · Implemented profile**

Portable composed decoration lowers to one ordinary straight-RGBA8 textured quad without changing the 136-byte Quad ABI.

Implementation: [src/draw/decoration.zig](../../src/draw/decoration.zig), [src/draw/brushes.zig](../../src/draw/brushes.zig), [src/render/prepared.zig](../../src/render/prepared.zig), [examples/styling/gallery.zig](../../examples/styling/gallery.zig), [src/render/gles/styling.zig](../../src/render/gles/styling.zig).

Evidence:

- `gradient border shadow and separate focus outline coexist in one texture`
- `prepared texture binds a current layout box and preserves layout border metrics`
- `ES3 prepared gradient border shadow isolated mask texture agrees with software within two bytes`
- `ES2 prepared gradient border shadow isolated mask texture agrees with software within two bytes`

Profile boundaries:

- Rich decoration is explicit preparation; changing it does not silently allocate a texture or add a retained cache.

## Color

### visual.rgba8 — Existing compact RGBA colors

**P1 · Implemented profile**

Existing packed Color channels and compact shader ABI retained.

Implementation: [src/core/types.zig](../../src/core/types.zig), [src/draw/color_math.zig](../../src/draw/color_math.zig), [src/draw/surface.zig](../../src/draw/surface.zig).

Evidence:

- `authoring values convert without a registry and pack only at the boundary`
- `layout: Quad is the 136-byte instance row the quad pipeline declares`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

### visual.color_conversions — Additional color authoring and conversion

**P2 · Implemented profile**

HSL/HWB, Lab/LCH D50, OKLab/OKLCH, P3, XYZ D50/D65, A98, ProPhoto, Rec2020 conversions; 148 CSS named colors in SVG authoring.

Implementation: [src/draw/color_math.zig](../../src/draw/color_math.zig), [src/draw/svg.zig](../../src/draw/svg.zig).

Evidence:

- `authoring values convert without a registry and pack only at the boundary`
- `OKLab round trip and explicit alpha representation`
- `XYZ and predefined wide gamut authoring spaces preserve white and extended gamut`
- `SVG font fragments use unclipped baseline coordinates and CPAL fallback colors`

Profile boundaries:

- Extended/out-of-gamut values survive authoring; RGBA8 packing clips channels. No general ICC profile engine is claimed.

### visual.color_interpolation — Explicit color mixing and interpolation

**P2 · Implemented profile**

Selectable sRGB, linear sRGB, OKLab and polar OKLCH with hue routes and explicit alpha premultiplication.

Implementation: [src/draw/color_math.zig](../../src/draw/color_math.zig), [src/draw/brushes.zig](../../src/draw/brushes.zig), [src/anim/motion.zig](../../src/anim/motion.zig), [src/style/properties.zig](../../src/style/properties.zig).

Evidence:

- `premultiplied interpolation avoids transparent endpoint fringes`
- `multi-stop hard boundaries, repeat, hints and transparent colors reach the sampler`
- `extended easing and typed tracks drive real style properties`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

## Output and platform effects

### visual.wide_gamut — Managed wide-gamut output

**P5 · Implemented profile**

Optional tagged float P3/Rec2020/sRGB plane conversion and actual RGBA16F/32F/RGB10A2 export with explicit SDR fallback.

Implementation: [src/draw/color_math.zig](../../src/draw/color_math.zig), [src/draw/color_output.zig](../../src/draw/color_output.zig), [src/render/capabilities.zig](../../src/render/capabilities.zig).

Evidence:

- `XYZ and predefined wide gamut authoring spaces preserve white and extended gamut`
- `floating surfaces preserve HDR highlights and export actual host texture data`
- `SDR import conversion and tone-map fallback preserve alpha and transparent black`

Profile boundaries:

- Stock RGBA8 decoration surfaces are sRGB; they do not preserve wide-gamut authoring until a float scene is supplied.
- The host configures and tags its swapchain/capture. Image ICC extraction, arbitrary ICC transforms and OS display-profile activation are outside this declared profile.
- SDR mapping offers clipping or luminance-preserving Reinhard, not an ICC perceptual intent gamut mapper.

### visual.hdr — HDR surfaces and tone mapping

**P5 · Implemented profile**

Optional linear absolute-cd/m2 surfaces, explicit SDR white, HDR/SDR source-over, PQ/HLG/linear encodings and tone-mapped RGBA8.

Implementation: [src/draw/color_output.zig](../../src/draw/color_output.zig), [src/render/capabilities.zig](../../src/render/capabilities.zig).

Evidence:

- `HDR transfer reference points and round trips use explicit luminance`
- `floating surfaces preserve HDR highlights and export actual host texture data`
- `SDR import conversion and tone-map fallback preserve alpha and transparent black`

Profile boundaries:

- Host display headroom, output-mode activation and platform swapchain/capture tagging remain explicit external capabilities.
- HLG follows the documented CSS draft transfer convention; it does not apply a display-dependent OOTF automatically.
- CPU float operations are real consumers; the stock Quad shader is not upgraded into a full float-HDR scene renderer.

## Backgrounds

### visual.solid_background — Solid fill and transparent background

**P1 · Implemented profile**

Legacy compact fill retained; typed rich brush tint is independent and literal transparent is a value.

Implementation: [src/core/types.zig](../../src/core/types.zig), [src/draw/paint.zig](../../src/draw/paint.zig), [src/draw/brushes.zig](../../src/draw/brushes.zig), [src/draw/decoration.zig](../../src/draw/decoration.zig), [src/style/properties.zig](../../src/style/properties.zig).

Evidence:

- `a textured node with no fill paints its texture untinted`
- `direct typed values reach existing box and text consumers; transparent and zero are values`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

### visual.background_layers — Ordered background paint layers

**P2 · Implemented profile**

Back-to-front arbitrary brush layers with per-layer alpha, operator, blend and clip.

Implementation: [src/draw/decoration.zig](../../src/draw/decoration.zig), [src/draw/backgrounds.zig](../../src/draw/backgrounds.zig), [examples/styling/gallery.zig](../../examples/styling/gallery.zig).

Evidence:

- `gradient border shadow and separate focus outline coexist in one texture`
- `background reference boxes and local/fixed attachment change actual sampled pixels`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

### visual.background_geometry — Background origin, clipping and attachment

**P2 · Implemented profile**

Actual box preparation and paint consumer for content/padding/border origin and clip, scroll, local overflow and fixed attachment.

Implementation: [src/draw/backgrounds.zig](../../src/draw/backgrounds.zig), [src/draw/decoration.zig](../../src/draw/decoration.zig).

Evidence:

- `background reference boxes and local/fixed attachment change actual sampled pixels`

Profile boundaries:

- Local attachment requires explicit overflow padding-box geometry and scroll offset; fixed attachment requires an explicit viewport or transformed containing block.
- The host supplies those inputs each frame; no hidden dependency on a global window or scroll registry.

## Gradients

### visual.linear_gradient — Linear gradient geometry

**P2 · Implemented profile**

Explicit endpoint gradients plus CSS-style zero-up clockwise angle/reference-box helper. Legacy two-color quad gradients retained.

Implementation: [src/draw/brushes.zig](../../src/draw/brushes.zig), [src/draw/backgrounds.zig](../../src/draw/backgrounds.zig).

Evidence:

- `multi-stop hard boundaries, repeat, hints and transparent colors reach the sampler`
- `percentage radii capsule and radial extent helpers feed real decoration`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

### visual.radial_gradient — Radial gradient geometry

**P2 · Implemented profile**

Circles/ellipses, offset centers/foci, closest/farthest side/corner sizes, general two-circle cone gradients.

Implementation: [src/draw/brushes.zig](../../src/draw/brushes.zig), [src/draw/backgrounds.zig](../../src/draw/backgrounds.zig), [src/draw/svg.zig](../../src/draw/svg.zig).

Evidence:

- `general two circle gradients preserve inner radii and transparent cone exterior`
- `percentage radii capsule and radial extent helpers feed real decoration`

Profile boundaries:

- Zero radius in the background helper uses a declared finite-pixel limit: final color for pad, weighted ramp average for repetition.
- Legacy SVG exactly-on-end-circle repeated focal degeneracy is rejected explicitly rather than approximated silently.

### visual.conic_gradient — Conic or sweep gradients

**P2 · Implemented profile**

CSS-style conic brush and OpenType Cartesian sweep with arbitrary/reversed angular interval, defined seam and repeat/reflect.

Implementation: [src/draw/brushes.zig](../../src/draw/brushes.zig).

Evidence:

- `linear light and conic geometry are consumed without scalar pixel tails`
- `OpenType sweep uses Cartesian angles and consumes reversed and degenerate intervals`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

### visual.gradient_stops — Arbitrary stops and transition hints

**P2 · Implemented profile**

Caller-prepared segment spans consume arbitrary ordered/out-of-range stops, hard duplicates, midpoint hints and interpolation space.

Implementation: [src/draw/brushes.zig](../../src/draw/brushes.zig).

Evidence:

- `multi-stop hard boundaries, repeat, hints and transparent colors reach the sampler`

Profile boundaries:

- Storage must include one segment per stop; invalid ordering or insufficient capacity returns an error before output preparation.

### visual.gradient_spread — Gradient repetition and spread modes

**P2 · Implemented profile**

Pad/repeat/reflect for all ramp-based brushes, with defined negative-coordinate and degenerate policies.

Implementation: [src/draw/brushes.zig](../../src/draw/brushes.zig).

Evidence:

- `multi-stop hard boundaries, repeat, hints and transparent colors reach the sampler`
- `OpenType sweep uses Cartesian angles and consumes reversed and degenerate intervals`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

## Backgrounds

### visual.foreground_decoration — Foreground and overlay decoration

**P2 · Implemented profile**

Explicit caller paint order and noninteractive frame paint-extra rows support foreground/selection/focus decoration.

Implementation: [src/draw/decoration.zig](../../src/draw/decoration.zig), [src/draw/outline.zig](../../src/draw/outline.zig), [src/runtime/frame.zig](../../src/runtime/frame.zig), [src/render/prepared.zig](../../src/render/prepared.zig).

Evidence:

- `gradient border shadow and separate focus outline coexist in one texture`
- `caller usage: combined states keep independent border/focus and failed resolution leaves frame balanced`

Profile boundaries:

- A rich foreground is painted after the content/group using the same public decoration operations; no automatic CSS pseudo-element or retained overlay engine is introduced.

## Borders, corners and outlines

### visual.border_edges — Independent border edges

**P2 · Implemented profile**

Independent L/T/R/B width, style and arbitrary brush, normalized unequal joins.

Implementation: [src/draw/decoration.zig](../../src/draw/decoration.zig), [src/layout/logical.zig](../../src/layout/logical.zig).

Evidence:

- `per-edge widths and colors leave the content box intact`
- `gradient border shadow and separate focus outline coexist in one texture`

Profile boundaries:

- Physical edge order is explicit; writing-mode/logical-edge resolution belongs to the layout resolver before preparing decoration.

### visual.border_patterns — Border patterns and continuous dash phase

**P2 · Implemented profile**

Solid/dashed/dotted/double/groove/ridge/inset/outset rectangle borders; continuous rounded perimeter phase; arbitrary path dash arrays.

Implementation: [src/draw/decoration.zig](../../src/draw/decoration.zig), [src/draw/vector.zig](../../src/draw/vector.zig).

Evidence:

- `gradient border shadow and separate focus outline coexist in one texture`
- `dash phase crosses vertices and joins ink across the closed seam`

Profile boundaries:

- A box Edge has a dash/gap pair; arbitrary dash arrays use the native vector stroke consumer. The DTCG importer rejects unrepresentable box patterns.

### visual.border_alignment — Inside, centered and outside borders

**P2 · Implemented profile**

Inside/center/outside placement with actual outward bounds and separate retained layout-border metrics.

Implementation: [src/draw/decoration.zig](../../src/draw/decoration.zig), [src/render/prepared.zig](../../src/render/prepared.zig).

Evidence:

- `per-edge widths and colors leave the content box intact`
- `prepared texture binds a current layout box and preserves layout border metrics`

Profile boundaries:

- Paint alignment itself does not alter layout; the caller chooses its layout border contribution.

### visual.corner_radii — Independent circular and elliptical corner radii

**P2 · Implemented profile**

Four x/y pairs, absolute/percentage resolution, capsule and proportional overlap normalization shared by shapes, layers, clips and borders.

Implementation: [src/draw/decoration.zig](../../src/draw/decoration.zig), [src/draw/backgrounds.zig](../../src/draw/backgrounds.zig).

Evidence:

- `radii normalize proportionally and elliptical clips transform coherently`
- `percentage radii capsule and radial extent helpers feed real decoration`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

### visual.corner_shapes — Specialist corner shapes

**P5 · Implemented profile**

Round/square/bevel/scoop/notch/squircle/general positive-exponent superellipse raster contours.

Implementation: [src/draw/decoration.zig](../../src/draw/decoration.zig), [examples/styling/gallery.zig](../../examples/styling/gallery.zig).

Evidence:

- `corner shapes and inset shadows consume their supplied options`
- `non round shadow distances follow bevel scoop and notch contours`

Profile boundaries:

- Thick borders use matching inset/outset authored-shape contours; they are not an exact Euclidean offset construction for arbitrary superellipses.
- Soft box shadows use the documented analytic contour-distance approximation; true silhouette convolution is separately available.

### visual.outlines — Independent outline and focus-ring paint

**P2 · Implemented profile**

Independent brush/pattern/width/offset shape-following paint; actual noninteractive border-box focus paint extras and bounds, with no reflow.

Implementation: [src/draw/decoration.zig](../../src/draw/decoration.zig), [src/draw/outline.zig](../../src/draw/outline.zig), [src/runtime/frame.zig](../../src/runtime/frame.zig), [src/theme/recipe_controls.zig](../../src/theme/recipe_controls.zig).

Evidence:

- `gradient border shadow and separate focus outline coexist in one texture`
- `caller usage: combined states keep independent border/focus and failed resolution leaves frame balanced`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

## Images

### visual.image_fit_position — Image fit and placement within a stable box

**P2 · Implemented profile**

Fill/contain/cover/none/scale-down plus fractional alignment and explicit stable destination box.

Implementation: [src/draw/brushes.zig](../../src/draw/brushes.zig), [src/draw/image_variants.zig](../../src/draw/image_variants.zig), [examples/styling/gallery.zig](../../examples/styling/gallery.zig).

Evidence:

- `bilinear sampling prevents a transparent red fringe and respects placement`
- `DPI variant choice changes the actual resource without changing logical placement`

Profile boundaries:

- Cover/none overflow clipping is an explicit layer/shape choice.

### visual.image_crop — Source cropping and texture coordinates

**P2 · Implemented profile**

Existing normalized UVs retained; rich source-pixel atlas crop clamps sampling to crop centers and supports eight orientations.

Implementation: [src/draw/brushes.zig](../../src/draw/brushes.zig), [src/draw/image_sampling.zig](../../src/draw/image_sampling.zig), [src/draw/draw_list.zig](../../src/draw/draw_list.zig).

Evidence:

- `EXIF rotations materialize and sample the same oriented pixels`
- `bilinear sampling prevents a transparent red fringe and respects placement`

Profile boundaries:

- The host reads image orientation metadata; the provided orientation enum then has an actual sampler/materializer.

### visual.image_tint — Independent image tint and alpha

**P2 · Implemented profile**

Explicit tint RGBA, independent layer opacity, untinted white default, and optional ordered color-filter pass.

Implementation: [src/draw/brushes.zig](../../src/draw/brushes.zig), [src/draw/decoration.zig](../../src/draw/decoration.zig), [src/draw/compositor.zig](../../src/draw/compositor.zig).

Evidence:

- `direct typed values reach existing box and text consumers; transparent and zero are values`
- `bilinear sampling prevents a transparent red fringe and respects placement`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

### visual.image_repeat — Image tiling and texture address modes

**P2 · Implemented profile**

Independent none/repeat/mirror/space/round axes on ordinary image brush, with explicit tile and distribution area.

Implementation: [src/draw/brushes.zig](../../src/draw/brushes.zig), [src/draw/masks.zig](../../src/draw/masks.zig), [examples/styling/gallery.zig](../../examples/styling/gallery.zig).

Evidence:

- `bilinear sampling prevents a transparent red fringe and respects placement`
- `placed repeated masks combine in order with explicit coverage mode`

Profile boundaries:

- Prepared pixels give every stock texture backend the same declared CPU result; native stock texture samplers are not implicitly assumed equivalent.

### visual.nine_slice — Nine-slice image skins

**P2 · Implemented profile**

Independent source/destination cuts, proportional fit, repeated/round/space edges and optional center, real image/mask consumers.

Implementation: [src/draw/brushes.zig](../../src/draw/brushes.zig), [src/draw/masks.zig](../../src/draw/masks.zig).

Evidence:

- `nine slice consumes fractional and large destination cuts`
- `nine slice mask border is consumed by a completed group and preflights storage`

Profile boundaries:

- Nine output rows are required by the helper even when fewer nonempty patches are returned.

### visual.image_sampling — Explicit texture sampling quality

**P2 · Implemented profile**

Nearest/bilinear and nearest/trilinear mip selection, explicit derivatives/LOD, nearest/linear/area resampling in sRGB or linear light.

Implementation: [src/draw/brushes.zig](../../src/draw/brushes.zig), [src/draw/image_sampling.zig](../../src/draw/image_sampling.zig), [src/render/capabilities.zig](../../src/render/capabilities.zig), [src/assets/image_mipmaps.zig](../../src/assets/image_mipmaps.zig).

Evidence:

- `area filtering retains odd edges and premultiplies before linear light filtering`
- `caller mip chain is consumed by fractional LOD sampling`
- `image brush sampling requests preparation rather than a backend-default sampler`

Profile boundaries:

- The existing byte mip builder/upload remains available; the new linear-light area builder preserves odd edge coverage.
- No automatic derivative inference from a retained scene or hardware anisotropic sampler is claimed.

### visual.image_resolution — Image resolution and device-scale selection

**P2 · Implemented profile**

Pure metadata selection of scale variants, stable logical intrinsic size, source orientation, actual brush binding, decode-size hints and mips.

Implementation: [src/draw/image_variants.zig](../../src/draw/image_variants.zig), [src/draw/image_sampling.zig](../../src/draw/image_sampling.zig), [src/draw/brushes.zig](../../src/draw/brushes.zig).

Evidence:

- `DPI variant choice changes the actual resource without changing logical placement`
- `caller mip chain is consumed by fractional LOD sampling`

Profile boundaries:

- Caller owns asynchronous loading and cache IDs; decode hints may be honored or full-size decoded, and both are validated by bind.

## Shadows

### visual.box_shadows — Composable outer box shadows

**P2 · Implemented profile**

Multiple ordered offset/spread/sigma/color box shadows following normalized corner shapes.

Implementation: [src/draw/decoration.zig](../../src/draw/decoration.zig), [src/draw/geometry.zig](../../src/draw/geometry.zig), [src/draw/damage.zig](../../src/draw/damage.zig).

Evidence:

- `gradient border shadow and separate focus outline coexist in one texture`
- `non round shadow distances follow bevel scoop and notch contours`
- `paint bounds follow translated shadows and reject singular transforms`

Profile boundaries:

- Analytic Gaussian contour-distance shadows are explicitly an approximation; request exact content-alpha convolution when needed.

### visual.inset_shadows — Inset box shadows

**P2 · Implemented profile**

Multiple inset shadows with independent offset/sigma/spread/color, clipped to the authored shape.

Implementation: [src/draw/decoration.zig](../../src/draw/decoration.zig).

Evidence:

- `corner shapes and inset shadows consume their supplied options`
- `gradient border shadow and separate focus outline coexist in one texture`

Profile boundaries:

- Uses the same declared analytic soft-edge approximation as outer box shadows.

### visual.content_shadows — Drop shadows from rendered content alpha

**P4 · Implemented profile**

Actual source-alpha extraction, separable blur, offset/color and explicit render-group input dependency.

Implementation: [src/draw/compositor.zig](../../src/draw/compositor.zig), [src/render/effects.zig](../../src/render/effects.zig), [src/render/prepared.zig](../../src/render/prepared.zig).

Evidence:

- `displacement and alpha drop shadow are rendered with explicit storage`
- `filter graph blends group pixels and propagates external changes`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

## Vector drawing

### visual.path_geometry — Reusable path geometry

**P3 · Implemented profile**

Existing reusable move/line/quadratic/cubic/close path extended with SVG elliptical arcs; bounded flattening and compound contours.

Implementation: [src/draw/paths.zig](../../src/draw/paths.zig), [src/draw/vector.zig](../../src/draw/vector.zig), [src/draw/svg.zig](../../src/draw/svg.zig).

Evidence:

- `elliptical arc construction reaches endpoints and radius correction stays finite`
- `flatten: every chord stays within the tolerance, and fewer chords for a looser one`
- `SVG path commands and transform lists preserve curves and authored bounds`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

### visual.vector_fills — Path fill rules and brushes

**P3 · Implemented profile**

Nonzero/even-odd existing coverage with actual solid/gradient/image brush sampler, affine brush inverse and opacity.

Implementation: [src/draw/paths.zig](../../src/draw/paths.zig), [src/draw/vector.zig](../../src/draw/vector.zig), [src/draw/svg.zig](../../src/draw/svg.zig).

Evidence:

- `fill: rules differ where contours overlap with the same winding`
- `path coverage consumes the gradient brush`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

### visual.vector_strokes — Stroke width, joins and caps

**P3 · Implemented profile**

Width, butt/round/square cap, miter/bevel/round join/miter limit reuse existing stroker and rich coverage paint.

Implementation: [src/draw/paths.zig](../../src/draw/paths.zig), [src/draw/vector.zig](../../src/draw/vector.zig).

Evidence:

- `stroke: pieces per segment, join and cap, all wound the same way`
- `stroke: a sharp miter past the limit becomes a bevel`
- `path coverage consumes the gradient brush`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

### visual.vector_dashes — Dashed paths and dash phase

**P3 · Implemented profile**

Arbitrary arrays, odd-pattern duplication, zero-entry policy, phase across vertices, closed seam joining, actual cap-aware stroking.

Implementation: [src/draw/vector.zig](../../src/draw/vector.zig), [src/draw/svg.zig](../../src/draw/svg.zig).

Evidence:

- `dash phase crosses vertices and joins ink across the closed seam`
- `SVG non scaling dashed strokes and fragment ancestor opacity are consumed`

Profile boundaries:

- Dash geometry requires explicit bounded output capacity; excessive split counts return InvalidDash.

### visual.vector_markers — Path markers and arrowheads

**P3 · Implemented profile**

Authored vertex start/mid/end markers with curve derivative tangents, automatic/start-reverse/fixed orientation and explicit units.

Implementation: [src/draw/vector.zig](../../src/draw/vector.zig), [examples/styling/gallery.zig](../../examples/styling/gallery.zig).

Evidence:

- `path markers use curve derivatives and caller chosen units`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

### visual.non_scaling_strokes — Non-scaling strokes and pixel-sized markers

**P3 · Implemented profile**

Geometry/logical/device stroke units and user/stroke/device marker units consume the actual transform/device scale.

Implementation: [src/draw/vector.zig](../../src/draw/vector.zig), [src/draw/svg.zig](../../src/draw/svg.zig).

Evidence:

- `non scaling device stroke retains pixel width under skew and scale`
- `SVG non scaling dashed strokes and fragment ancestor opacity are consumed`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

### visual.vector_import — Vector asset import and fidelity

**P3 · Implemented profile**

Existing TinyVG gains real two-color gradient and variable-width fidelity; declared static SVG subset lowers to native paths/brushes/layers.

Implementation: [src/draw/tinyvg.zig](../../src/draw/tinyvg.zig), [src/draw/svg.zig](../../src/draw/svg.zig), [src/draw/vector.zig](../../src/draw/vector.zig).

Evidence:

- `rich decoding retains both gradient colors and endpoint width changes`
- `TinyVG rich paint actually renders its gradient into a caller surface`
- `SVG actual gradient templates and isolated opacity overlap render into the surface`
- `SVG unsupported visual features and reference cycles are explicit`
- `SVG font fragments use unclipped baseline coordinates and CPAL fallback colors`

Profile boundaries:

- SVG supports shapes/path commands, transforms/viewBox, inline/inherited presentation, gradients/templates, currentColor/CPAL fallback, dashes and isolated opacity.
- Unsupported CSS selectors, use, clipPath, mask, filter, pattern, image, text, scripts, external assets and nested svg return explicit errors. This is not a browser or full OpenType-SVG conformance claim.
- Streaming imports can leave earlier completed shapes in a staging surface on a later authoring/capacity error; publish only after successful return when atomicity is required.

## Custom rendering

### visual.custom_materials — Existing custom shader materials

**P1 · Implemented profile**

Existing host shader registration/Style.material/params retained; checked backend profile distinguishes custom-material support.

Implementation: [src/core/types.zig](../../src/core/types.zig), [src/render/wgpu/wgpu.zig](../../src/render/wgpu/wgpu.zig), [src/render/shaders/material.wgsl](../../src/render/shaders/material.wgsl), [src/render/capabilities.zig](../../src/render/capabilities.zig), [src/render/prepared.zig](../../src/render/prepared.zig).

Evidence:

- `checked rendering rejects stripped shaders before an ordinary backend draw`

Profile boundaries:

- Portable preparation rejects arbitrary GPU material code; a software equivalent or explicit fallback must be supplied by the host.

### visual.custom_draw — Existing inline custom drawing and host interleaving

**P0 · Implemented profile**

Existing inline host interleaving remains; custom records carry geometry, transform, clip/radii and opacity, and portable groups require an explicit image.

Implementation: [src/draw/draw_list.zig](../../src/draw/draw_list.zig), [src/draw/paint.zig](../../src/draw/paint.zig), [src/render/prepared.zig](../../src/render/prepared.zig), [src/render/wgpu/custom_draw_sample.zig](../../src/render/wgpu/custom_draw_sample.zig).

Evidence:

- `a renderer's one switch per command draws every quad, run and custom once, in order`
- `ordinary quad text and custom commands participate in an exact clipped isolated group`

Profile boundaries:

- No callback or implicit GPU pass ownership is introduced. Custom draw implementations must honor the declared contract themselves or provide raster content.

## Clipping and masks

### visual.rectangular_clip — Rectangular clip fast path

**P0 · Implemented profile**

Existing rectangular clip/scissor fast route and exact portable intersections including empty/fractional bounds.

Implementation: [src/draw/geometry.zig](../../src/draw/geometry.zig), [src/draw/paint.zig](../../src/draw/paint.zig), [src/render/sw/sw.zig](../../src/render/sw/sw.zig), [src/render/prepared.zig](../../src/render/prepared.zig).

Evidence:

- `opaque rects: filled exactly, cut by the clip's pixel centres and the scissor`
- `ordinary quad text and custom commands participate in an exact clipped isolated group`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

### visual.rounded_clip — Exact nested rounded clipping

**P2 · Implemented profile**

Arbitrary clip spans intersect every rounded ancestor at shared subpixel positions, including text/images/custom raster content.

Implementation: [src/draw/decoration.zig](../../src/draw/decoration.zig), [src/render/prepared.zig](../../src/render/prepared.zig), [src/draw/geometry.zig](../../src/draw/geometry.zig).

Evidence:

- `radii normalize proportionally and elliptical clips transform coherently`
- `ordinary quad text and custom commands participate in an exact clipped isolated group`

Profile boundaries:

- A single stock shader clip descriptor does not encode an arbitrary nested chain; checked capability routing selects portable preparation.

### visual.path_clip — Clipping to arbitrary geometry

**P3 · Implemented profile**

Existing fill-rule path coverage becomes an explicit transformed coverage clip and intersects rounded/rectangular/path clips.

Implementation: [src/draw/decoration.zig](../../src/draw/decoration.zig), [src/draw/paths.zig](../../src/draw/paths.zig), [src/draw/vector.zig](../../src/draw/vector.zig), [src/render/prepared.zig](../../src/render/prepared.zig).

Evidence:

- `existing path coverage feeds clips without a retained path manager`
- `path coverage consumes the gradient brush`

Profile boundaries:

- Paint clips do not silently replace the ordinary 2D hit shape. Caller input policy chooses an explicit hit target/coverage test; arbitrary path clip semantics are not auto-attached to retained node input.

### visual.image_masks — Alpha and luminance masks

**P4 · Implemented profile**

Actual image/gradient/path-coverage alpha, encoded/linear luminance, inversion and group-once mask application.

Implementation: [src/draw/masks.zig](../../src/draw/masks.zig), [src/draw/compositor.zig](../../src/draw/compositor.zig), [src/draw/decoration.zig](../../src/draw/decoration.zig), [src/render/effects.zig](../../src/render/effects.zig), [src/render/gles/styling.zig](../../src/render/gles/styling.zig).

Evidence:

- `mask luminance, inversion and alpha are distinct`
- `placed repeated masks combine in order with explicit coverage mode`
- `nine slice mask border is consumed by a completed group and preflights storage`
- `ES3 prepared gradient border shadow isolated mask texture agrees with software within two bytes`
- `ES2 prepared gradient border shadow isolated mask texture agrees with software within two bytes`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

### visual.mask_layers — Mask placement and combination

**P4 · Implemented profile**

Explicit placement/inverse/region, image repetition/size, back-to-front add/subtract/intersect/exclude, actual nine-slice mask border and capacity diagnostics.

Implementation: [src/draw/masks.zig](../../src/draw/masks.zig), [src/draw/brushes.zig](../../src/draw/brushes.zig), [src/draw/compositor.zig](../../src/draw/compositor.zig), [src/render/effects.zig](../../src/render/effects.zig).

Evidence:

- `placed repeated masks combine in order with explicit coverage mode`
- `nine slice mask border is consumed by a completed group and preflights storage`

Profile boundaries:

- Every operator is applied to explicit initial coverage; subtract is source-out, not a destructive erase shorthand.

## Transforms

### visual.affine_transform — Complete 2D affine transform styling

**P2 · Implemented profile**

Translation/rotation/scale/skew/matrix and explicit transform origin/reference-box shared across paint/label/clip/input.

Implementation: [src/draw/geometry.zig](../../src/draw/geometry.zig), [src/draw/paint.zig](../../src/draw/paint.zig), [src/draw/svg.zig](../../src/draw/svg.zig), [src/interact/hit.zig](../../src/interact/hit.zig), [src/render/prepared.zig](../../src/render/prepared.zig).

Evidence:

- `transformed pointer and rounded ancestor clip agree with paint geometry`
- `ordinary quad text and custom commands participate in an exact clipped isolated group`
- `SVG path commands and transform lists preserve curves and authored bounds`

Profile boundaries:

- Transforms affect displayed geometry, not the surrounding layout calculation.

### visual.perspective_3d — Optional perspective and 3D composition

**P5 · Implemented profile**

Optional caller-ordered flattened planes: real 4x4 XYZ rotations/perspective/origin, inverse projective raster sampling and backface culling.

Implementation: [src/draw/projective.zig](../../src/draw/projective.zig), [src/render/capabilities.zig](../../src/render/capabilities.zig), [examples/styling/gallery.zig](../../examples/styling/gallery.zig).

Evidence:

- `projective raster samples non-affine UVs through the ordinary surface path`
- `3D origin rotation perspective and backface choices remain explicit`

Profile boundaries:

- No retained preserve-3D scene/depth sorting/occlusion engine is introduced. depth_scene is a distinct rejected capability unless the host supplies one.
- Crossing the projection plane is an explicit error rather than unbounded raster work.
- Hit testing of a plane uses its exposed inverse mapping; automatic projected descendant input routing is outside the ordinary affine node contract.

## Opacity and compositing

### visual.primitive_opacity — Existing inherited per-primitive opacity

**P0 · Implemented profile**

Legacy ancestor alpha multiplication remains; text and custom records receive explicit primitive alpha.

Implementation: [src/draw/paint.zig](../../src/draw/paint.zig), [src/draw/draw_list.zig](../../src/draw/draw_list.zig), [src/draw/inherit.zig](../../src/draw/inherit.zig), [src/render/prepared.zig](../../src/render/prepared.zig).

Evidence:

- `sweep 2: text runs get the content box, custom draws the node rect, both the parent clip`
- `ordinary quad text and custom commands participate in an exact clipped isolated group`

Profile boundaries:

- Per-primitive opacity retains its semantics; isolated group opacity uses a separate flatten-then-fade operation.

### visual.group_opacity — Exact opacity of a completed subtree

**P4 · Implemented profile**

Real caller-owned group surface, all participating ordinary draw kinds, nested explicit composition and opacity applied once.

Implementation: [src/render/prepared.zig](../../src/render/prepared.zig), [src/draw/compositor.zig](../../src/draw/compositor.zig), [src/draw/svg.zig](../../src/draw/svg.zig), [src/render/gles/styling.zig](../../src/render/gles/styling.zig).

Evidence:

- `isolated group opacity is applied once after opaque overlap`
- `ordinary quad text and custom commands participate in an exact clipped isolated group`
- `SVG actual gradient templates and isolated opacity overlap render into the surface`
- `ES3 prepared gradient border shadow isolated mask texture agrees with software within two bytes`
- `ES2 prepared gradient border shadow isolated mask texture agrees with software within two bytes`

Profile boundaries:

- Custom GPU commands need caller-provided raster equivalents for portable composition.
- No implicit nonoverlap proof or retained offscreen cache is added.

### visual.surface_layers — Explicit offscreen layer operations

**P4 · Implemented profile**

Caller-owned surfaces with explicit dimensions/stride/alpha, measurement, budgets, resource lifetimes and no hidden allocation.

Implementation: [src/draw/surface.zig](../../src/draw/surface.zig), [src/render/prepared.zig](../../src/render/prepared.zig), [src/render/effects.zig](../../src/render/effects.zig).

Evidence:

- `surface capacity and transparent padding are explicit`
- `ordinary quad text and custom commands participate in an exact clipped isolated group`
- `filter graph blends group pixels and propagates external changes`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

### visual.stacking_isolation — Local stacking and isolated groups

**P4 · Implemented profile**

Existing layer/sibling/hit order retained; an explicit completed offscreen range is an atomic isolated group at its composite position.

Implementation: [src/draw/order.zig](../../src/draw/order.zig), [src/layout/overlay.zig](../../src/layout/overlay.zig), [src/render/prepared.zig](../../src/render/prepared.zig), [src/draw/compositor.zig](../../src/draw/compositor.zig), [src/interact/hit.zig](../../src/interact/hit.zig).

Evidence:

- `stacking layers: a raised menu paints after every row; batch counts recorded`
- `atLayered: an open menu covers the later body row under it`
- `ordinary quad text and custom commands participate in an exact clipped isolated group`

Profile boundaries:

- This profile does not add a browser-like nested retained z-index engine. The caller sequences nested groups and their associated interaction order explicitly.

### visual.blend_modes — Artistic blend modes

**P4 · Implemented profile**

All 16 declared normal/artistic separable and nonseparable blend modes on premultiplied surfaces and isolated groups.

Implementation: [src/draw/compositor.zig](../../src/draw/compositor.zig), [src/draw/decoration.zig](../../src/draw/decoration.zig), [src/render/effects.zig](../../src/render/effects.zig), [examples/styling/gallery.zig](../../examples/styling/gallery.zig).

Evidence:

- `Porter Duff and blend modes produce premultiplied values`
- `filter graph blends group pixels and propagates external changes`

Profile boundaries:

- Artistic blend calculation is encoded sRGB for the RGBA8 compositor; float HDR source-over is a separate path.

### visual.compositing_operators — Porter-Duff and related compositing operators

**P4 · Implemented profile**

Clear/source/destination and all Porter-Duff in/out/atop/over/xor plus additive, with explicit offset/bounds.

Implementation: [src/draw/compositor.zig](../../src/draw/compositor.zig), [src/render/effects.zig](../../src/render/effects.zig).

Evidence:

- `Porter Duff and blend modes produce premultiplied values`
- `isolated group opacity is applied once after opaque overlap`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

## Filters

### visual.color_filters — Foreground color filters

**P4 · Implemented profile**

Brightness/contrast/saturation/grayscale/hue/invert/sepia/opacity/4x5 matrix in selected transfer space, concatenation and explicit ordered graph.

Implementation: [src/draw/compositor.zig](../../src/draw/compositor.zig), [src/render/effects.zig](../../src/render/effects.zig).

Evidence:

- `bounded backdrop snapshot blur and matrix passes are caller scheduled`
- `signed convolution and component tables are real filter consumers`

Profile boundaries:

- Fusing is valid only for compatible spaces and when intermediate clipping is not required; the API documents that condition.

### visual.foreground_blur — General foreground blur

**P4 · Implemented profile**

Actual separable Gaussian independent X/Y sigma/kernel, explicit source/scratch/destination and edge modes, caller resolution/bounds.

Implementation: [src/draw/compositor.zig](../../src/draw/compositor.zig), [src/render/effects.zig](../../src/render/effects.zig).

Evidence:

- `anisotropic blur consumes independent axes and preserves unblurred rows`
- `anisotropic graph blur preserves the identity axis and checks joint kernel capacity`
- `bounded backdrop snapshot blur and matrix passes are caller scheduled`

Profile boundaries:

- Changing effective resolution requires explicit resampling and bounds; no hidden adaptive downsampling.

### visual.backdrop_filters — Bounded backdrop filtering

**P4 · Implemented profile**

Explicit bounded scene snapshot, graph filters/tint/saturation, exact destination clips, change propagation and halo-aware refresh.

Implementation: [src/render/effects.zig](../../src/render/effects.zig), [src/draw/compositor.zig](../../src/draw/compositor.zig), [src/render/prepared.zig](../../src/render/prepared.zig), [examples/styling/gallery.zig](../../examples/styling/gallery.zig).

Evidence:

- `backdrop refresh follows changed background inside the blur halo`
- `bounded backdrop snapshot blur and matrix passes are caller scheduled`

Profile boundaries:

- The host identifies the backdrop source boundary and sequences capture before the foreground; no renderer-global scene capture.

### visual.specialist_filters — Optional filter graph extensions

**P5 · Implemented profile**

Real convolution, morphology, displacement, channel transfer, deterministic noise, point/spot/distant diffuse/specular lighting, arithmetic and multi-input graphs.

Implementation: [src/draw/filter_primitives.zig](../../src/draw/filter_primitives.zig), [src/draw/compositor.zig](../../src/draw/compositor.zig), [src/render/effects.zig](../../src/render/effects.zig).

Evidence:

- `signed convolution and component tables are real filter consumers`
- `noise is repeatable and supplied seed changes generated pixels`
- `distant point spot diffuse and specular lights shade an alpha height field`
- `displacement and alpha drop shadow are rendered with explicit storage`
- `filter graph blends group pixels and propagates external changes`

Profile boundaries:

- Noise is the documented deterministic native generator, not a bit-for-bit implementation of SVG legacy turbulence seed tables.
- Lighting color alpha must be one; apply explicit group opacity afterward.
- Primitive numerical authoring errors can stop a graph after earlier nodes were produced; capacities/graph references/storage are preflighted before execution.

## Motion and animation

### visual.property_tweens — Existing property tweening with semantic invalidation

**P3 · Implemented profile**

Existing property tweens plus typed track sampling and semantic paint/layout/text invalidation.

Implementation: [src/anim/tweens.zig](../../src/anim/tweens.zig), [src/anim/motion.zig](../../src/anim/motion.zig), [src/style/properties.zig](../../src/style/properties.zig), [src/runtime/context.zig](../../src/runtime/context.zig).

Evidence:

- `retarget: the same target keeps the leg; a new one starts from where it is`
- `extended easing and typed tracks drive real style properties`
- `paint-only changes do not request shaping or layout; text metrics do`
- `tween reservation exhaustion preserves live playback and never steps the discard row`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

### visual.easing — Extended easing functions

**P3 · Implemented profile**

Existing curves retained; cubic Bezier, all steps jump modes, piecewise linear and caller sampled curves with validation.

Implementation: [src/anim/tweens.zig](../../src/anim/tweens.zig), [src/anim/motion.zig](../../src/anim/motion.zig).

Evidence:

- `ease_table: every curve starts at 0, ends at 1 and never leaves [0, 1]`
- `extended easing and typed tracks drive real style properties`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

### visual.springs — Existing spring motion and control

**P3 · Implemented profile**

Existing explicit spring dynamics/velocity/retarget/threshold and idle integration retained. Checked reservation and isolated discard-row compatibility behavior prevent overflow from mutating another spring.

Implementation: [src/anim/anims.zig](../../src/anim/anims.zig), [src/runtime/context.zig](../../src/runtime/context.zig).

Evidence:

- `step: a spring lands on its target, then reports rest and stays idle`
- `step: every row is stepped as the scalar reference, across vectors and padding`
- `declared slider spring drives painted frames and honours reduced motion`
- `spring reservation exhaustion discards overflow without changing a live row`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

### visual.keyframes — Extended keyframe playback

**P3 · Implemented profile**

Typed timed keys and independent playback duration/delay/repeats/direction/fill/pause/seek, no hidden event dispatcher.

Implementation: [src/anim/keyframes.zig](../../src/anim/keyframes.zig), [src/anim/motion.zig](../../src/anim/motion.zig).

Evidence:

- `caller-owned playback handles delay alternation pause reverse and reduced motion`
- `extended easing and typed tracks drive real style properties`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

### visual.color_motion — Color transitions with explicit interpolation

**P3 · Implemented profile**

Motion calls the same selected color interpolation as static gradient authoring; legacy RGBA channel behavior remains available.

Implementation: [src/anim/motion.zig](../../src/anim/motion.zig), [src/draw/color_math.zig](../../src/draw/color_math.zig), [src/style/properties.zig](../../src/style/properties.zig).

Evidence:

- `premultiplied interpolation avoids transparent endpoint fringes`
- `extended easing and typed tracks drive real style properties`
- `color transition exhaustion settles all channels without partial reservations`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

### visual.layout_motion — Layout transition and FLIP expansion

**P3 · Implemented profile**

Existing identity/position FLIP springs retained; explicit before/after rectangle transform supports size transitions.

Implementation: [src/anim/flip.zig](../../src/anim/flip.zig), [src/anim/motion.zig](../../src/anim/motion.zig), [src/runtime/context.zig](../../src/runtime/context.zig).

Evidence:

- `animateLayout: a node pushed down by a growing sibling slides there, then rests`
- `path traversal morphing and size FLIP consume existing geometry`
- `FLIP exhaustion preserves prior registrations and reserves its two spring axes atomically`

Profile boundaries:

- Size FLIP scales the displayed subtree through a transform; it does not silently reflow/re-shape text at every intermediate size.
- Caller supplies updated before/after geometry on interruption and composes nested transforms explicitly.

### visual.motion_paths — Motion along a path

**P3 · Implemented profile**

Distance-based existing-polyline traversal returns position/tangent and an anchor/rotation-offset matrix.

Implementation: [src/anim/motion.zig](../../src/anim/motion.zig), [src/draw/paths.zig](../../src/draw/paths.zig).

Evidence:

- `path traversal morphing and size FLIP consume existing geometry`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

### visual.geometry_morph — Compatible path and shape morphing

**P3 · Implemented profile**

Real compatible command/point interpolation into caller Path storage; shape radii remain plain interpolatable values.

Implementation: [src/anim/motion.zig](../../src/anim/motion.zig), [src/draw/paths.zig](../../src/draw/paths.zig), [src/draw/decoration.zig](../../src/draw/decoration.zig).

Evidence:

- `path traversal morphing and size FLIP consume existing geometry`

Profile boundaries:

- Incompatible topology returns IncompatiblePath; the caller explicitly selects a discrete or two-surface crossfade policy. No hidden path remeshing.

### visual.reduced_motion — Existing reduced-motion and idle behavior

**P1 · Implemented profile**

Reduced-motion end state and explicit wake/idle rules retained and used by new playback.

Implementation: [src/anim/motion.zig](../../src/anim/motion.zig), [src/runtime/context.zig](../../src/runtime/context.zig), [src/runtime/scheduler.zig](../../src/runtime/scheduler.zig), [src/a11y/settings.zig](../../src/a11y/settings.zig).

Evidence:

- `caller-owned playback handles delay alternation pause reverse and reduced motion`
- `reduced motion: every animation shows its end state in the frame it changes; idle at once`
- `idle: zero frames and zero wakeups without input`

Profile boundaries:

- Essential-motion choice is caller policy through the reduced-motion argument; no global hidden override.

### visual.animation_lifecycle — Explicit playback lifecycle and completion

**P3 · Implemented profile**

New independent Playback supports delay/cancel/finish/pause/seek/reverse/completion and explicit hidden-subtree policy. Runtime animate/tween/sequence/FLIP use checked reservations, return settled targets/layout on exhaustion, and report per-frame anims/tweens/flips status bits.

Implementation: [src/anim/motion.zig](../../src/anim/motion.zig), [src/anim/anims.zig](../../src/anim/anims.zig), [src/anim/tweens.zig](../../src/anim/tweens.zig), [src/runtime/context.zig](../../src/runtime/context.zig), [src/anim/flip.zig](../../src/anim/flip.zig), [src/runtime/frame.zig](../../src/runtime/frame.zig).

Evidence:

- `caller-owned playback handles delay alternation pause reverse and reduced motion`
- `tween: wakes the host for its duration, lands, then the host sleeps`
- `animation exhaustion returns settled values without retargeting another control`
- `FLIP exhaustion preserves prior registrations and reserves its two spring axes atomically`
- `tween reservation exhaustion preserves live playback and never steps the discard row`
- `color transition exhaustion settles all channels without partial reservations`

Profile boundaries:

- Compatibility slot methods return a discard row beyond padded(cap), flagged by overflow and never stepped/retained. Checked callers use reserve/reserveScan to receive NoSpace.
- Completion is returned data; consuming it and scheduling a later frame stay under caller control.

## Output and platform effects

### visual.pixel_alignment — Pixel snapping and fractional geometry

**P0 · Implemented profile**

Fractional logical geometry retained; explicit device-scale edge snapping and outward texture-bound alignment happen at the chosen boundary.

Implementation: [src/draw/geometry.zig](../../src/draw/geometry.zig), [src/draw/decoration.zig](../../src/draw/decoration.zig), [src/render/prepared.zig](../../src/render/prepared.zig).

Evidence:

- `radii normalize together and snapped physical edges preserve scale`
- `radii normalize proportionally and elliptical clips transform coherently`

Profile boundaries:

- No additional restriction beyond the public operation's validated inputs and explicit storage capacities.

### visual.antialiasing — Shape and clip antialiasing policy

**P2 · Implemented profile**

1/4/16 shared shape/clip sample positions, existing path coverage and selected image sampling.

Implementation: [src/draw/decoration.zig](../../src/draw/decoration.zig), [src/draw/paths.zig](../../src/draw/paths.zig), [src/draw/masks.zig](../../src/draw/masks.zig), [src/draw/projective.zig](../../src/draw/projective.zig), [src/render/capabilities.zig](../../src/render/capabilities.zig).

Evidence:

- `fill: a half-pixel edge covers half, either winding direction`
- `radii normalize proportionally and elliptical clips transform coherently`
- `placed repeated masks combine in order with explicit coverage mode`

Profile boundaries:

- 1-sample quality is the explicit hard-edge policy. CPU and analytic GPU edges are different declared raster models; exact nested-clip comparison uses the portable prepared route.
- Finite 4/16-sample coverage is not an analytic area integral for arbitrary curves.

### visual.native_materials — Optional window-system materials

**P5 · Implemented profile**

Explicit AppKit visual-effect descriptor/submission and Windows DWM backdrop/corner/color calls, plus preference-aware fallback policy.

Implementation: [src/shell/materials.zig](../../src/shell/materials.zig), [src/shell/macos/macos.zig](../../src/shell/macos/macos.zig), [src/shell/win32/win32.zig](../../src/shell/win32/win32.zig), [src/render/capabilities.zig](../../src/render/capabilities.zig).

Evidence:

- `native material policy preserves unknown preferences and selects the solid fallback`

Profile boundaries:

- Native visual appearance varies by OS/version; platform smoke checks cannot be replaced by the Linux unit tests.
- Host supplies OS preference state and readable theme fallback; high-contrast and reduced-transparency are not guessed from an unset value.

### visual.effect_quality_limits — Effect quality and resource limits

**P0 · Implemented profile**

Explicit width/height/bytes/layer/clip/blur budgets, caller capacities, geometry and kernel validation, no hidden resource allocation.

Implementation: [src/render/prepared.zig](../../src/render/prepared.zig), [src/render/effects.zig](../../src/render/effects.zig), [src/draw/surface.zig](../../src/draw/surface.zig), [src/draw/brushes.zig](../../src/draw/brushes.zig), [src/draw/vector.zig](../../src/draw/vector.zig), [src/draw/svg.zig](../../src/draw/svg.zig), [src/draw/masks.zig](../../src/draw/masks.zig).

Evidence:

- `surface capacity and transparent padding are explicit`
- `aliased background and mask fail before rasterize clears the source`
- `SVG unsupported visual features and reference cycles are explicit`
- `nine slice mask border is consumed by a completed group and preflights storage`

Profile boundaries:

- Streaming vector imports use caller staging surfaces when all-or-nothing publication is required; later invalid input may leave prior completed shapes.
- Raw primitive work is bounded by its supplied dimensions/spans; orchestration budgets are an optional caller-controlled tier.

## Custom rendering

### visual.render_target_interop — Existing texture-in and render-to-texture routes

**P1 · Implemented profile**

Existing host texture-in/render-target/UV routes retained; portable CPU output binds an ordinary texture with explicit alpha/lifetime/pass boundaries.

Implementation: [src/draw/surface.zig](../../src/draw/surface.zig), [src/render/prepared.zig](../../src/render/prepared.zig), [src/render/iface.zig](../../src/render/iface.zig), [src/render/wgpu/host.zig](../../src/render/wgpu/host.zig), [src/render/gles/host.zig](../../src/render/gles/host.zig), [src/render/gles/styling.zig](../../src/render/gles/styling.zig).

Evidence:

- `texture export changes alpha representation once and preserves zero alpha`
- `prepared texture binds a current layout box and preserves layout border metrics`
- `ordinary quad text and custom commands participate in an exact clipped isolated group`
- `ES3 prepared gradient border shadow isolated mask texture agrees with software within two bytes`
- `ES2 prepared gradient border shadow isolated mask texture agrees with software within two bytes`

Profile boundaries:

- No automatic GPU readback or resource cache; host-produced images used in CPU groups need explicit accessible pixel sources.
