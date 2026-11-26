# Comprehensive styling for LCGF

> **Historical research snapshot.** This record predates implementation. See the [implemented styling guide](../../styling/README.md), [coverage profiles](../../styling/coverage.md), and [validation report](../../styling/validation.md) for the completed branch.

Research date: **2026-11-23**. Audited baseline: **`ed94db3da27882ef1c87d0dd15a382b4df39e2c2`** in `OmarSiwy/LCGF`. This historical snapshot records the research and proposed implementation program before runtime changes or new performance measurements. The implementation links above describe the subsequently completed work.

## Recommendation

Expand LCGF into a broadly expressive native 2D UI toolkit by making its existing capabilities easy to combine, completing their semantics, and adding missing options in small, tested slices. Keep plain data, caller-owned memory, independently callable passes, and the application's control of the frame. Higher-level themes, recipes, caches, and import tools should remain optional conveniences over those operations.

The most urgent work is not another isolated shader feature. The current code already has gradients, shadows, paths, animation, layout extensions, rich text machinery, and accessibility preferences. Its limitations include mutually exclusive paint features, incomplete transform/clip propagation, narrow public text options, and several differences between front ends and backends. A detailed source-based classification is in [source-audit.md](source-audit.md).

The user specifically requested Casey Muratori's API-design approach. [api-design.md](api-design.md) applies his original writing and lecture material to this project. Public signatures must follow concrete usage examples and preserve access to the lower-level operations. The types and subsystem boundaries proposed in this research are hypotheses to validate with those examples, not a fixed architecture to implement wholesale.

## Reading guide

| Need | Document |
|---|---|
| Every researched capability family, variants, current status, and proposed phase | [Capability inventory](inventory.md) |
| The same inventory for filtering and implementation tracking | [Machine-readable inventory](inventory.json) |
| What the source really does, with permanent links and exact evidence | [Source audit](source-audit.md) |
| API constraints and usage-first review | [API design](api-design.md) |
| Ordered work packages, dependencies, and meaningful completion criteria | [Implementation plan](implementation-plan.md) |
| Primary documentation and research provenance | [References](references.md) |

## What “comprehensive” means

The **158-group inventory** covers reusable styling concepts across layout, paint, typography, widget parts, states, themes, interaction, animation, accessibility, platform preferences, and optional advanced composition. CSS/SVG provide a useful catalog of semantics. LVGL, Qt Quick, Slint, and Flutter provide native implementation and API examples. The [CSS Snapshot 2026](https://www.w3.org/TR/css-2026/) distinguishes stable modules from less mature work; it is not a claim that LCGF should become a browser.

This is an extensive capability inventory, not a promise to implement every present and future CSS property. Specialist document layout, arbitrary shaders, native window materials, 3D, HDR, and experimental features remain explicitly scoped extensions. Arbitrary application drawing is already possible through host integration; that does not automatically make the same effect a portable built-in style property.

An option counts as supported only when it has defined input values, a consumer in the relevant layout/text/render path, correct interactions, advertised backend coverage, and an example through a supported front end. A field that is stored but ignored does not count. “Existing” also does not imply that every backend implements the option or every combination is valid.

## 1. Reuse the substantial existing foundation

The following are findings from the pinned source, not inferred from feature names in old planning documents. See the audit for limitations and exact paths.

| Existing foundation | Main extension needed |
|---|---|
| Fit, pixel, grow, and percentage sizes; min/max, padding, alignment, float, scroll | Better composition of existing optional layout passes, explicit unit/box semantics, logical edges and broader distribution |
| Flex margins, aspect ratio, shrink weights, row wrap and baseline; bounded grid; RTL and anchors | Supported convenience paths, documented algorithm limits, richer layout only where required |
| Solid fill, textured quads, two-color linear/radial gradients, dashed/dotted borders | Independent brushes and borders, more gradient stops, ordered decoration layers |
| Scalar per-corner radii, analytic Gaussian box shadows, nine-slice images | Elliptical corners, owned shadow lists, more image placement/sampling and border-image modes |
| Path fill/stroke, curve flattening, coverage-atlas emission, TinyVG | Accessible vector asset/paint integration, richer strokes and optional SVG import |
| Font loading, shaping, Unicode segmentation/bidi, fallback, paragraph layout, rich spans | One practical text path exposing paragraph options and using the same metrics for measurement and drawing |
| Tokens, light/dark themes, density, state looks, overrides, inheritance | Token identity, explicit unset/inherit, broader semantic roles, parts and combined-state resolution |
| Springs, tweens, color transitions, scalar keyframes, position FLIP | Reusable property metadata, timing/playback/interruption options, broader interpolators |
| High contrast, text scaling, reduced motion and focus helpers | Consistent component coverage, reduced transparency and richer system-color policy |
| Caller-controlled native/software/web rendering and custom draw escape hatches | Explicit capability and resource-budget contracts for additional effects |

The basic `TextStyle` currently has four fields: `px`, `color`, `font`, and `wrap`. The richer paragraph code exists elsewhere. Similarly, `Frame.end` is a convenient `Mono`-based sequence and `Frame.finish` intentionally allows callers to run their own passes. Preserve that useful granularity while offering well-tested convenience compositions for advanced text and layout.

## 2. Fix the semantics that combinations expose

### Independent decorations

`draw/features.zig` selects one stock feature through `params.x`. A single quad cannot independently select a gradient fill and a dashed border. Separate background, border, outline, shadow, and content descriptions should lower to one or more ordered primitives. Common solid widgets should keep the existing simple route. Avoid enumerating every combination of effects as a new shader kind.

Define a stable paint order: outer shadows, background layers, border, inset decoration, content/children, foreground decoration and outline, with explicit group effects. Exact CSS order is needed only for a declared CSS-compatible profile; native order must still be documented. Background clipping, descendant clipping, and pointer shapes remain distinct choices. [CSS Backgrounds](https://www.w3.org/TR/css-backgrounds-3/) and [Flutter BoxDecoration](https://api.flutter.dev/flutter/painting/BoxDecoration-class.html) illustrate the relevant distinctions.

### Coordinate spaces and bounds

The current affine transform is documented as paint-only. Quads receive the world transform; text and inline custom commands do not carry equivalent transform fields, and hit testing/clipping use layout geometry. The pure comptime paint path rejects nonidentity transforms. Complete the contract across local, layout, world, clip, and device coordinates before advertising transformed widgets as a general feature.

Keep layout bounds, conservative paint bounds, and hit geometry separate. A shadow extends paint bounds without increasing the click target. A small resize handle can have a larger hit target without a larger visible mark. Inverse transforms should map pointers into the intended local target; singular matrices need a defined behavior. Accessibility geometry must use the same final visual mapping where appropriate.

The audit identifies potential damage/culling/reordering errors because several bounds calculations use untransformed rectangles and omit shadow expansion. These are source-inspection findings requiring reproductions, not executed failing tests. One shared conservative-bounds operation should serve visibility, damage, overlap checks, and effect invalidation. Unknown custom bounds must disable unsafe optimizations or use caller-provided bounds.

### Primitive alpha and group opacity

Existing opacity multiplies descendant quad opacity and text-color alpha individually. Inline custom draw payloads do not carry inherited opacity; the host must account for it. Custom content rendered into a texture and displayed as a normal quad receives the normal quad opacity. Group opacity means composing the descendants and then fading the completed result. Two overlapping opaque shapes each at alpha 0.5 give overlap alpha `0.5 + 0.5 * (1 - 0.5) = 0.75` over a transparent target; a completed opaque group faded to 0.5 stays at alpha 0.5. These behaviors need distinct APIs or explicitly distinct modes. [Qt's layer discussion](https://doc.qt.io/qt-6/qml-qtquick-item.html) documents the same distinction.

Group semantics do not require every group to allocate a texture: a backend may use a cheaper equivalent when it can prove equivalence. The public result must remain stable. Images, text, paths, custom content, filters and exported screenshots also need explicit straight/premultiplied-alpha and transfer-function contracts.

### Nested clips

An intersected rectangle plus one set of radii cannot represent all intersections of several rounded clips. Text/custom clipping must agree with shape clipping. Keep cheap rectangle and single-rounded-clip paths, then add a caller-owned clip-chain or equivalent representation for general intersections. Alpha/luminance masks are a separate capability because they supply graded coverage. A mask should not accidentally change hit testing unless the application requests that policy. [CSS Masking](https://www.w3.org/TR/css-masking-1/)

### State and value identity

Use explicit presence/inheritance information. Numeric zero, transparent black, “not specified,” and “inherit” have different meanings. Existing zero sentinels and raw-color palette remapping lose some of those distinctions. Token references should retain their semantic identity even when two roles currently happen to have the same RGBA value.

Resolve overrides per property. A selected row can also be hovered and keyboard-focused. A pressed-state fill must not erase an unrelated selected outline. The suggested precedence is defaults, theme/component recipe, variant/size, attached or scoped rules, and local overrides; state/environment rules participate in the layer where they were authored. Accessibility policy should have an explicit place. This precedence is a proposal to validate, not a claim of CSS cascade conformance. [LVGL styles](https://lvgl.io/docs/open/common-widget-features/styles/overview), [Flutter state properties](https://api.flutter.dev/flutter/widgets/WidgetStateProperty-class.html)

## 3. Broad styling without a large cost for every node

Use different representations for authoring and execution. Authoring can express rich options; layout, interaction, and painting should read compact records containing only their relevant inputs. This follows LCGF's existing columns, 32-byte `Look`, and optional `Extra` rows. The current `Quad` is a tested 136-byte renderer ABI, so expanding it has consequences across every backend and generated shader.

Suggested boundaries to validate in usage code:

| Concern | Direct path | Optional convenience |
|---|---|---|
| Style values | Plain typed values and explicit patches | Reusable named recipes and token files |
| Resolution | Caller supplies inputs, output and scratch | Caller-owned cache keyed by relevant generations |
| Paint resources | Borrowed spans or caller-owned typed pools | Interned immutable brushes, stops, shadows and paths |
| State | Application/widget supplies state bits | Indexed rules and cached reachable combinations |
| Layout/text | Independently callable passes and result rows | Common frame-completion helpers or comptime-specialized pipelines |
| Effects | Explicit group commands, resource requests and host sequencing | Surface pools and cached effect plans owned by the application |

No theme manager, global registry, stylesheet parser, allocator or framework-owned loop should be required to draw a plain styled control. A caller that wants cached styles may opt in and own their storage/lifetimes. A caller that has its own resource manager should not have to mirror it into another one.

Store uncommon arrays outside common node records: gradient stops, per-side complex borders, shadow lists, rich font feature sets, clip chains and effect graphs. Use existing handles where they fit. Generation-checked references are useful for mutable caches; immutable direct spans can avoid registration entirely. Runtime capacity requirements must be queryable and failures explicit. Comptime UIs should calculate their required capacities and omit unused facilities where possible.

A property description should define its value type, default, inherited behavior, interpolation, validation, logical-edge mapping and invalidation effects. This can be compile-time metadata generating tables and documentation; it need not be a mandatory runtime registry. Extend the existing feature-usage analysis instead of introducing an unrelated system before real examples need it.

## 4. Invalidation is part of each feature

| Change | Work ordinarily required |
|---|---|
| Text foreground only | Paint; preserve shaping and line layout |
| Font, size, language, shaping features, variable axes | Font/run resolution and shaping; affected measurement/layout/paint |
| Available paragraph width | Line layout and geometry; some scripts need boundary-sensitive reshaping |
| Padding, border participating in box sizing, intrinsic image size | Measurement/layout and affected descendants |
| Transform or outline offset | Visual/hit bounds and paint; preserve unrelated layout |
| Gradient stop color | Paint resource/update and affected paint |
| Shadow/filter radius | Effect resource/bounds and union of old/new damaged extents |
| Theme token | Only consumers and inherited descendants that depend on it, stopping at overrides |
| Backdrop content | Effect consumers whose sampled source region changed |
| Device scale/font resource generation | Relevant raster/text/layout caches according to their actual dependency |

These are engineering targets, not current LCGF performance guarantees. They should be tested through normal front ends, including style changes during animations, image/font replacement, scrolling, and subtree reuse. A single “dirty” bit is insufficient to distinguish all these effects reliably.

Backdrop blur needs more than a blur shader. A panel samples already painted pixels, so content behind it can invalidate it while the panel itself is unchanged. Its sampling region, clipping, isolation boundary, filter edge behavior and ordering must be explicit. The [Filter Effects 2 draft](https://drafts.csswg.org/filter-effects-2/) is still draft material; LCGF should publish a precise native contract for its chosen behavior.

## 5. Performance strategy

Preserve the inexpensive path for plain controls and make expensive work proportional to actual use. Do not precompute every combination of many state bits. Store active animation tracks densely and remove completed tracks from scheduling. Partition effects by operation so a software span loop sees contiguous compatible data. Reuse layout/text/vector results when their actual inputs have not changed.

Measure SIMD candidates after the data flow is correct: span blending, gradient evaluation, bounds transforms, color conversion, convolution and animation interpolation. Parent-dependent propagation and draw-order dependencies are not independent rows. Do not globally sort translucent paint by material: overlap and group boundaries constrain valid batching. [Qt renderer documentation](https://doc.qt.io/qt-6/qtquick-visualcanvas-scenegraph-renderer.html)

Offscreen layers have real storage and bandwidth costs. One 1920×1080 RGBA8 surface contains 8,294,400 bytes, about 7.91 MiB, before allocator alignment, extra buffers, masks or multisampling. Full-window blur often requires multiple surfaces. This arithmetic is illustrative, not an LCGF measurement. [Flutter's performance guidance](https://docs.flutter.dev/perf/best-practices) discusses the cost of offscreen buffers and render-target switches. Cache small repeated decoration where beneficial; do not assume caching every widget is faster.

Every performance claim should state workload, toolchain, CPU/GPU, resolution, device scale, warm/cold state and selected backend. Measure end-to-end frames, CPU phases, p50/p95/p99 latency, bytes per node, temporary/offscreen bytes, draw calls, damaged pixels, compile time and binary size. Maintain equivalent output before comparing speed. Benchmarks from earlier unrelated work are not measurements of this styling proposal.

## 6. Capabilities and profiles

Profiles below are proposed deployment policies, separate from LCGF's architectural Tier 0/1/2 layering. They must not be confused with a claim that every backend already supports them.

| Profile | Intended coverage | Explicit boundary |
|---|---|---|
| Small embedded | Basic layout/text, solids/images/borders, chosen rounded/gradient primitives, prepared assets | Caller-bounded memory; unsupported effects diagnosed or replaced by an explicitly selected visual fallback |
| Full 2D | Composed decoration, advanced text, paths, transforms and complete clip semantics | Software/GPU parity for the advertised feature subset |
| Composited 2D | Isolated groups, masks, blend modes, color filters, blur and optional backdrop effects | Host-owned surface budget, maximum dimensions/radii/depth, explicit resource scheduling |
| Specialist | Managed wide gamut/HDR, native window materials, 3D, custom effect graphs and document publishing | Independent platform/dependency modules and documented fallback behavior |

Return capabilities with limits and quality/precision information, not just a boolean “supports styling.” Existing GLES2 deliberately omits the stock params effects and ignores custom materials; software cannot generally execute arbitrary GPU materials. A backend must be allowed to reject an unsupported request clearly. Approximate, prepared-asset and exact implementations should be reported separately.

## 7. Recommended first production work

Begin with two small concrete usage scenarios: a themed button whose text and border roles share the same initial color, and a clipped/transformed card with a label and shadow. The first reveals token identity, explicit transparent values and combined-state precedence. The second reveals shared geometry and paint-bounds requirements. Add the smallest direct operations that make these scenarios correct, then derive optional conveniences from their repeated use.

After those contracts, expose existing paragraph/flex/grid capabilities through supported common paths, implement composable decoration, and proceed through [the implementation plan](implementation-plan.md). Keep filters, full stylesheet compatibility and specialist graphics on their own opt-in paths. This gives everyday applications substantial expressive power while preserving the project's data and ownership model.
