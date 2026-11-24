# Complete styling capability inventory

Research date: **2026-11-23**. Baseline: **`ed94db3da27882ef1c87d0dd15a382b4df39e2c2`**. **158 capability groups**; the options within groups are variants, not a count of independently shipped features. Cross-cutting groups intentionally share contracts. No capabilities are implemented by this document.

[Main findings](README.md) · [Source audit](source-audit.md) · [API design](api-design.md) · [Implementation plan](implementation-plan.md) · [JSON](inventory.json) · [References](references.md)

## How to read the inventory

The current baseline and the proposed action are separate. “Partial” does not mean unusable; it may mean a working feature needs combinations or a supported front-end path. “Not found” is limited to this source audit. Arbitrary host drawing is not the same as a portable built-in style option. Acceptance criteria below are future completion targets, not results of tests already run.

| Baseline | Meaning |
|---|---|
| `integrated` | The audited standard path already provides the named capability; backend and combination limits still apply. |
| `low_level` | A lower-level operation already exists, but broader front-end integration or convenience is needed. |
| `partial` | Substantial related support exists, but options, semantics, combinations or coverage need extending. |
| `not_found` | No general built-in implementation of this capability was identified in the inspected baseline; this is a scoped source-audit finding, not proof that custom host code cannot do it. |
| `application_authored` | Existing extension paths allow applications to construct this behavior, but no common built-in styling contract provides it. |

| Phase | Capability groups | Focus |
|---|---:|---|
| P0 | 24 | Correctness, geometry, value identity, capacities and capability contracts |
| P1 | 30 | Expose existing capabilities; direct style composition, themes, states and parts |
| P2 | 44 | Composed everyday painting and typography |
| P3 | 38 | Advanced layout, responsiveness, vectors and motion |
| P4 | 11 | Optional layers, masks, compositing and filters |
| P5 | 11 | Specialist/platform/document extensions selected by actual demand |

Actions: **retain** — Preserve existing behavior and carry it through new paths.; **integrate** — Expose existing operations through supported caller paths.; **extend** — Broaden an existing implementation or its semantics.; **add** — Implement a missing common capability.; **optional** — Keep as a separately selected extension or application layer.

The cost column names the primary affected domain; it is not a quantitative benchmark or an assertion that other domains are free. Requirements describe semantic dependencies, not a mandate to create one new subsystem per phrase. All optional cache/registry guidance in [API design](api-design.md) applies to every row.

## Index

| ID | Capability | Baseline | Action | Phase |
|---|---|---|---|---|
| [`ui.property_contract`](#ui-property-contract) | Typed property metadata and support contract | partial | add | P0 |
| [`ui.bounded_style_storage`](#ui-bounded-style-storage) | Caller-owned optional style storage | partial | extend | P0 |
| [`ui.presence_inheritance`](#ui-presence-inheritance) | Explicit presence and inheritance | partial | extend | P0 |
| [`ui.semantic_tokens`](#ui-semantic-tokens) | Role-preserving semantic color tokens | partial | extend | P1 |
| [`ui.design_scales`](#ui-design-scales) | Spacing, typography and shape token scales | partial | extend | P1 |
| [`ui.theme_scope`](#ui-theme-scope) | Scoped themes and deterministic precedence | partial | extend | P1 |
| [`ui.part_identifiers`](#ui-part-identifiers) | Reusable widget part styles | partial | add | P1 |
| [`ui.variants_recipes`](#ui-variants-recipes) | Named variants and reusable component recipes | partial | extend | P1 |
| [`ui.combined_states`](#ui-combined-states) | Combinable state-dependent styling | partial | extend | P1 |
| [`ui.resolver_generations`](#ui-resolver-generations) | Shared style handles and targeted invalidation | partial | add | P1 |
| [`ui.typed_authoring`](#ui-typed-authoring) | Unified runtime and compile-time authoring | partial | integrate | P1 |
| [`ui.token_import`](#ui-token-import) | Optional design-token interchange | not_found | optional | P3 |
| [`ui.stylesheet_compiler`](#ui-stylesheet-compiler) | Optional CSS-like authoring compiler | application_authored | optional | P5 |
| [`ui.style_inspector`](#ui-style-inspector) | Computed-style and dependency inspector | partial | add | P2 |
| [`ui.size_constraints`](#ui-size-constraints) | Preferred, minimum and maximum dimensions | partial | integrate | P1 |
| [`ui.intrinsic_measurement`](#ui-intrinsic-measurement) | Intrinsic content measurement semantics | partial | extend | P3 |
| [`ui.relative_units`](#ui-relative-units) | Relative length units and bounded expressions | partial | extend | P3 |
| [`ui.box_spacing`](#ui-box-spacing) | Per-edge padding and margins | partial | integrate | P1 |
| [`ui.row_column_gaps`](#ui-row-column-gaps) | Independent gaps and line spacing | partial | extend | P3 |
| [`ui.logical_edges`](#ui-logical-edges) | Direction-aware logical edges and dimensions | partial | extend | P3 |
| [`ui.flex_distribution`](#ui-flex-distribution) | Flex basis, growth and shrink semantics | partial | extend | P3 |
| [`ui.flex_wrap_baseline`](#ui-flex-wrap-baseline) | Wrapping, line layout and baseline alignment | partial | extend | P3 |
| [`ui.alignment_distribution`](#ui-alignment-distribution) | Container and item alignment distribution | partial | extend | P3 |
| [`ui.grid_basics`](#ui-grid-basics) | Public integration of bounded grid | low_level | integrate | P1 |
| [`ui.grid_advanced`](#ui-grid-advanced) | Richer grid tracks and placement | not_found | optional | P3 |
| [`ui.subgrid`](#ui-subgrid) | Subgrid alignment across nested components | not_found | optional | P3 |
| [`ui.out_of_flow`](#ui-out-of-flow) | Out-of-flow placement and containing blocks | partial | extend | P1 |
| [`ui.anchored_overlays`](#ui-anchored-overlays) | Menus and popovers anchored to geometry | low_level | integrate | P1 |
| [`ui.fixed_sticky`](#ui-fixed-sticky) | Fixed and sticky positioning | not_found | add | P3 |
| [`ui.layer_order`](#ui-layer-order) | Consistent paint and hit layer order | low_level | integrate | P0 |
| [`ui.visibility_participation`](#ui-visibility-participation) | Visibility, layout and input participation | partial | extend | P0 |
| [`ui.overflow_modes`](#ui-overflow-modes) | Overflow and scrolling semantics | partial | extend | P1 |
| [`ui.containment_virtualization`](#ui-containment-virtualization) | Containment and virtualized measurement boundaries | partial | extend | P3 |
| [`ui.custom_layout_protocol`](#ui-custom-layout-protocol) | Custom layout through explicit passes | low_level | extend | P1 |
| [`ui.pixel_rounding`](#ui-pixel-rounding) | Logical geometry and pixel rounding policy | partial | extend | P0 |
| [`ui.responsive_conditions`](#ui-responsive-conditions) | Viewport and container style conditions | application_authored | add | P3 |
| [`ui.environment_conditions`](#ui-environment-conditions) | Environment and input-capability conditions | partial | extend | P1 |
| [`ui.safe_area_occlusion`](#ui-safe-area-occlusion) | Safe-area and viewport occlusion inputs | application_authored | add | P3 |
| [`ui.special_layout_modules`](#ui-special-layout-modules) | Specialized native and document layouts | application_authored | optional | P5 |
| [`ui.public_text_pipeline`](#ui-public-text-pipeline) | Advanced text in the normal frame path | partial | integrate | P1 |
| [`ui.font_selection`](#ui-font-selection) | Family, resource and style matching | partial | extend | P2 |
| [`ui.font_weight_width_style`](#ui-font-weight-width-style) | Font weight, width and slant selection | partial | extend | P2 |
| [`ui.font_formats_variations`](#ui-font-formats-variations) | Extended font formats and variable/color fonts | partial | optional | P5 |
| [`ui.shaping_features`](#ui-shaping-features) | Shaping feature and run-property control | partial | extend | P2 |
| [`ui.bidi_itemization`](#ui-bidi-itemization) | Bidi, script and language integration | low_level | integrate | P1 |
| [`ui.cluster_fallback`](#ui-cluster-fallback) | Cluster-aware font fallback | partial | extend | P0 |
| [`ui.grapheme_editing`](#ui-grapheme-editing) | Grapheme-safe indexing and editing | partial | extend | P0 |
| [`ui.paragraph_alignment`](#ui-paragraph-alignment) | Paragraph alignment and justification | low_level | integrate | P1 |
| [`ui.whitespace_tabs`](#ui-whitespace-tabs) | Whitespace, newlines and tabs | partial | extend | P2 |
| [`ui.wrap_hyphenation`](#ui-wrap-hyphenation) | Line-breaking policies and hyphenation | partial | extend | P3 |
| [`ui.text_overflow`](#ui-text-overflow) | Truncation and maximum visible lines | low_level | extend | P1 |
| [`ui.line_metrics`](#ui-line-metrics) | Line height, leading and baseline metrics | partial | extend | P2 |
| [`ui.text_spacing`](#ui-text-spacing) | Letter and word spacing | not_found | add | P2 |
| [`ui.rich_run_segmentation`](#ui-rich-run-segmentation) | Rich text shaping runs versus paint spans | partial | extend | P0 |
| [`ui.text_decorations`](#ui-text-decorations) | Text decorations | not_found | add | P2 |
| [`ui.inline_objects_baselines`](#ui-inline-objects-baselines) | Inline objects and baseline shifts | not_found | add | P3 |
| [`ui.text_paint_spans`](#ui-text-paint-spans) | Foreground, background and highlight paint for text | partial | extend | P2 |
| [`ui.editing_parts`](#ui-editing-parts) | Editable text visual parts | partial | extend | P2 |
| [`ui.locale_text_transform`](#ui-locale-text-transform) | Locale-aware display text transformations | not_found | optional | P3 |
| [`ui.advanced_typographic_features`](#ui-advanced-typographic-features) | OpenType typographic variants | partial | extend | P3 |
| [`ui.text_cache_contract`](#ui-text-cache-contract) | Text cache and invalidation contract | partial | extend | P0 |
| [`ui.vertical_ruby`](#ui-vertical-ruby) | Vertical writing and ruby annotations | not_found | optional | P5 |
| [`ui.document_typography`](#ui-document-typography) | Specialist document typography | not_found | optional | P5 |
| [`ui.cursor_styles`](#ui-cursor-styles) | Pointer cursor appearance | partial | extend | P2 |
| [`ui.hit_target_geometry`](#ui-hit-target-geometry) | Visual and hit-target geometry policy | partial | extend | P0 |
| [`ui.focus_policy`](#ui-focus-policy) | Keyboard-visible focus styling policy | partial | extend | P1 |
| [`ui.disabled_readonly_semantics`](#ui-disabled-readonly-semantics) | Behavioral state and visual-state consistency | partial | extend | P0 |
| [`ui.contrast_system_palettes`](#ui-contrast-system-palettes) | High contrast and system color palettes | partial | extend | P1 |
| [`ui.text_scale_tolerance`](#ui-text-scale-tolerance) | User text scale and spacing tolerance | partial | extend | P0 |
| [`ui.reduced_effect_preferences`](#ui-reduced-effect-preferences) | Reduced motion and transparency preferences | partial | extend | P1 |
| [`ui.noncolor_semantics`](#ui-noncolor-semantics) | State indication beyond color | partial | extend | P1 |
| [`ui.scrollbar_parts`](#ui-scrollbar-parts) | Scrollbar part appearance | partial | extend | P2 |
| [`ui.scrollbar_layout`](#ui-scrollbar-layout) | Scrollbar axes, placement and gutters | partial | extend | P2 |
| [`ui.scroll_behavior_policy`](#ui-scroll-behavior-policy) | Optional scroll behavior policies | partial | extend | P3 |
| [`ui.scroll_focus_reveal`](#ui-scroll-focus-reveal) | Focused target reveal and scroll anchoring | partial | extend | P1 |
| [`ui.control_part_catalog`](#ui-control-part-catalog) | Everyday control part recipes | partial | extend | P2 |
| [`ui.navigation_overlay_parts`](#ui-navigation-overlay-parts) | Navigation and overlay part recipes | partial | extend | P2 |
| [`ui.data_view_parts`](#ui-data-view-parts) | List, tree and table visual parts | partial | extend | P2 |
| [`ui.editor_canvas_parts`](#ui-editor-canvas-parts) | Extensible EDA and editor visual vocabulary | application_authored | optional | P3 |
| [`ui.a11y_style_validation`](#ui-a11y-style-validation) | Accessibility style diagnostics | partial | extend | P2 |
| [`ui.locale_theme_content`](#ui-locale-theme-content) | Locale-aware component presentation | partial | extend | P3 |
| [`visual.capability_profiles`](#visual-capability-profiles) | Declared renderer capabilities and fallback policy | partial | extend | P0 |
| [`visual.paint_bounds`](#visual-paint-bounds) | Shared conservative paint bounds | partial | extend | P0 |
| [`visual.alpha_representation`](#visual-alpha-representation) | Alpha and color-transfer contracts | partial | extend | P0 |
| [`visual.coordinate_spaces`](#visual-coordinate-spaces) | Coherent paint, clip, text and hit coordinate spaces | partial | extend | P0 |
| [`visual.clip_geometry_contract`](#visual-clip-geometry-contract) | Shared clip geometry across draw kinds | partial | extend | P0 |
| [`visual.decoration_composition`](#visual-decoration-composition) | Composition of multiple visual decorations | partial | extend | P0 |
| [`visual.rgba8`](#visual-rgba8) | Existing compact RGBA colors | integrated | retain | P1 |
| [`visual.color_conversions`](#visual-color-conversions) | Additional color authoring and conversion | not_found | add | P2 |
| [`visual.color_interpolation`](#visual-color-interpolation) | Explicit color mixing and interpolation | partial | extend | P2 |
| [`visual.wide_gamut`](#visual-wide-gamut) | Managed wide-gamut output | not_found | optional | P5 |
| [`visual.hdr`](#visual-hdr) | HDR surfaces and tone mapping | not_found | optional | P5 |
| [`visual.solid_background`](#visual-solid-background) | Solid fill and transparent background | partial | extend | P1 |
| [`visual.background_layers`](#visual-background-layers) | Ordered background paint layers | application_authored | add | P2 |
| [`visual.background_geometry`](#visual-background-geometry) | Background origin, clipping and attachment | partial | extend | P2 |
| [`visual.linear_gradient`](#visual-linear-gradient) | Linear gradient geometry | partial | extend | P2 |
| [`visual.radial_gradient`](#visual-radial-gradient) | Radial gradient geometry | partial | extend | P2 |
| [`visual.conic_gradient`](#visual-conic-gradient) | Conic or sweep gradients | not_found | add | P2 |
| [`visual.gradient_stops`](#visual-gradient-stops) | Arbitrary stops and transition hints | partial | extend | P2 |
| [`visual.gradient_spread`](#visual-gradient-spread) | Gradient repetition and spread modes | not_found | add | P2 |
| [`visual.foreground_decoration`](#visual-foreground-decoration) | Foreground and overlay decoration | low_level | integrate | P2 |
| [`visual.border_edges`](#visual-border-edges) | Independent border edges | partial | extend | P2 |
| [`visual.border_patterns`](#visual-border-patterns) | Border patterns and continuous dash phase | partial | extend | P2 |
| [`visual.border_alignment`](#visual-border-alignment) | Inside, centered and outside borders | not_found | add | P2 |
| [`visual.corner_radii`](#visual-corner-radii) | Independent circular and elliptical corner radii | partial | extend | P2 |
| [`visual.corner_shapes`](#visual-corner-shapes) | Specialist corner shapes | not_found | optional | P5 |
| [`visual.outlines`](#visual-outlines) | Independent outline and focus-ring paint | partial | extend | P2 |
| [`visual.image_fit_position`](#visual-image-fit-position) | Image fit and placement within a stable box | partial | extend | P2 |
| [`visual.image_crop`](#visual-image-crop) | Source cropping and texture coordinates | integrated | extend | P2 |
| [`visual.image_tint`](#visual-image-tint) | Independent image tint and alpha | partial | extend | P2 |
| [`visual.image_repeat`](#visual-image-repeat) | Image tiling and texture address modes | not_found | add | P2 |
| [`visual.nine_slice`](#visual-nine-slice) | Nine-slice image skins | partial | extend | P2 |
| [`visual.image_sampling`](#visual-image-sampling) | Explicit texture sampling quality | partial | extend | P2 |
| [`visual.image_resolution`](#visual-image-resolution) | Image resolution and device-scale selection | partial | extend | P2 |
| [`visual.box_shadows`](#visual-box-shadows) | Composable outer box shadows | partial | extend | P2 |
| [`visual.inset_shadows`](#visual-inset-shadows) | Inset box shadows | not_found | add | P2 |
| [`visual.content_shadows`](#visual-content-shadows) | Drop shadows from rendered content alpha | not_found | optional | P4 |
| [`visual.path_geometry`](#visual-path-geometry) | Reusable path geometry | low_level | integrate | P3 |
| [`visual.vector_fills`](#visual-vector-fills) | Path fill rules and brushes | low_level | extend | P3 |
| [`visual.vector_strokes`](#visual-vector-strokes) | Stroke width, joins and caps | low_level | integrate | P3 |
| [`visual.vector_dashes`](#visual-vector-dashes) | Dashed paths and dash phase | not_found | add | P3 |
| [`visual.vector_markers`](#visual-vector-markers) | Path markers and arrowheads | application_authored | add | P3 |
| [`visual.non_scaling_strokes`](#visual-non-scaling-strokes) | Non-scaling strokes and pixel-sized markers | not_found | add | P3 |
| [`visual.vector_import`](#visual-vector-import) | Vector asset import and fidelity | partial | extend | P3 |
| [`visual.custom_materials`](#visual-custom-materials) | Existing custom shader materials | low_level | extend | P1 |
| [`visual.custom_draw`](#visual-custom-draw) | Existing inline custom drawing and host interleaving | low_level | extend | P0 |
| [`visual.rectangular_clip`](#visual-rectangular-clip) | Rectangular clip fast path | integrated | retain | P0 |
| [`visual.rounded_clip`](#visual-rounded-clip) | Exact nested rounded clipping | partial | extend | P2 |
| [`visual.path_clip`](#visual-path-clip) | Clipping to arbitrary geometry | not_found | add | P3 |
| [`visual.image_masks`](#visual-image-masks) | Alpha and luminance masks | not_found | optional | P4 |
| [`visual.mask_layers`](#visual-mask-layers) | Mask placement and combination | not_found | optional | P4 |
| [`visual.affine_transform`](#visual-affine-transform) | Complete 2D affine transform styling | partial | extend | P2 |
| [`visual.perspective_3d`](#visual-perspective-3d) | Optional perspective and 3D composition | not_found | optional | P5 |
| [`visual.primitive_opacity`](#visual-primitive-opacity) | Existing inherited per-primitive opacity | partial | extend | P0 |
| [`visual.group_opacity`](#visual-group-opacity) | Exact opacity of a completed subtree | not_found | optional | P4 |
| [`visual.surface_layers`](#visual-surface-layers) | Explicit offscreen layer operations | application_authored | add | P4 |
| [`visual.stacking_isolation`](#visual-stacking-isolation) | Local stacking and isolated groups | partial | extend | P4 |
| [`visual.blend_modes`](#visual-blend-modes) | Artistic blend modes | not_found | optional | P4 |
| [`visual.compositing_operators`](#visual-compositing-operators) | Porter-Duff and related compositing operators | partial | extend | P4 |
| [`visual.color_filters`](#visual-color-filters) | Foreground color filters | application_authored | add | P4 |
| [`visual.foreground_blur`](#visual-foreground-blur) | General foreground blur | not_found | optional | P4 |
| [`visual.backdrop_filters`](#visual-backdrop-filters) | Bounded backdrop filtering | not_found | optional | P4 |
| [`visual.specialist_filters`](#visual-specialist-filters) | Optional filter graph extensions | application_authored | optional | P5 |
| [`visual.property_tweens`](#visual-property-tweens) | Existing property tweening with semantic invalidation | integrated | extend | P3 |
| [`visual.easing`](#visual-easing) | Extended easing functions | partial | extend | P3 |
| [`visual.springs`](#visual-springs) | Existing spring motion and control | integrated | extend | P3 |
| [`visual.keyframes`](#visual-keyframes) | Extended keyframe playback | partial | extend | P3 |
| [`visual.color_motion`](#visual-color-motion) | Color transitions with explicit interpolation | partial | extend | P3 |
| [`visual.layout_motion`](#visual-layout-motion) | Layout transition and FLIP expansion | partial | extend | P3 |
| [`visual.motion_paths`](#visual-motion-paths) | Motion along a path | not_found | optional | P3 |
| [`visual.geometry_morph`](#visual-geometry-morph) | Compatible path and shape morphing | not_found | optional | P3 |
| [`visual.reduced_motion`](#visual-reduced-motion) | Existing reduced-motion and idle behavior | integrated | retain | P1 |
| [`visual.animation_lifecycle`](#visual-animation-lifecycle) | Explicit playback lifecycle and completion | partial | extend | P3 |
| [`visual.pixel_alignment`](#visual-pixel-alignment) | Pixel snapping and fractional geometry | partial | extend | P0 |
| [`visual.antialiasing`](#visual-antialiasing) | Shape and clip antialiasing policy | partial | extend | P2 |
| [`visual.native_materials`](#visual-native-materials) | Optional window-system materials | not_found | optional | P5 |
| [`visual.effect_quality_limits`](#visual-effect-quality-limits) | Effect quality and resource limits | partial | extend | P0 |
| [`visual.render_target_interop`](#visual-render-target-interop) | Existing texture-in and render-to-texture routes | low_level | retain | P1 |

## Style system

<a id="ui-property-contract"></a>
### Typed property metadata and support contract

**ID:** `ui.property_contract` · **Baseline:** `partial` · **Action:** `add` · **Phase:** P0 · **Primary cost:** resolve

**Options:** value type; default; inheritance; interpolation kind; validation; invalidation domains; backend requirements.

**Current source:** Style/TextStyle, theme helpers and feature usage exist, but no unified property metadata and support contract spanning layout/text/paint/parts was found.

**Recommendation:** Define semantics before expanding property count; preserve a direct plain-data path with compile-time metadata and no required runtime registry.

**Requirements:** Compile-time property metadata without a mandatory runtime registry; Generated validation and documentation; Explicit capability profiles.

**Completion criterion:** Every accepted property has a consumer, stated fallback or rejection; a paint-only token change does not trigger layout.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/theme/theme.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/theme/theme.zig), [src/comptime/features.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/comptime/features.zig).

**Primary references:** [R035](references.md#r035).

<a id="ui-bounded-style-storage"></a>
### Caller-owned optional style storage

**ID:** `ui.bounded_style_storage` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P0 · **Primary cost:** resolve

**Options:** immutable style spans; generation-checked indices; bounded property pools; capacity errors; feature stripping.

**Current source:** Tree uses optional Extra rows and compact Look storage; DESIGN requires caller-owned memory and a dependency-free Tier 0.

**Recommendation:** Preserve the compact ordinary widget path; do not place every option in every node.

**Requirements:** Capacity-declared side tables; No hidden allocations; Read-only compile-time tables.

**Completion criterion:** Exhausting a declared pool returns a deterministic failure without allocation, corruption or silently missing properties.

**Source paths:** [src/core/tree.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/tree.zig), [docs/DESIGN.md](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/docs/DESIGN.md).

**Primary references:** [R034](references.md#r034).

<a id="ui-presence-inheritance"></a>
### Explicit presence and inheritance

**ID:** `ui.presence_inheritance` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P0 · **Primary cost:** resolve

**Options:** unset; inherit; initial/default; literal zero; literal transparent; selected inheritable text properties.

**Current source:** theme.Inherited resolves caller-owned color/px columns but treats zero as inherit; explicit transparent and zero are ambiguous.

**Recommendation:** Replace sentinel semantics with explicit presence while preserving existing callers through an adapter.

**Requirements:** Presence bits or tagged values; Inheritance pass; Override boundaries.

**Completion criterion:** A transparent literal stays transparent under a colored parent; inherit follows the parent; an explicit override stops propagation.

**Source paths:** [src/theme/theme.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/theme/theme.zig), [src/runtime/frame.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/runtime/frame.zig).

**Primary references:** [R051](references.md#r051).

<a id="ui-resolver-generations"></a>
### Shared style handles and targeted invalidation

**ID:** `ui.resolver_generations` · **Baseline:** `partial` · **Action:** `add` · **Phase:** P1 · **Primary cost:** resolve

**Options:** interned immutable styles; token generations; scope generations; state generations; environment dependency masks; resolved style IDs.

**Current source:** Theme/build helpers and incremental layout exist; no unified style dependency resolver was found.

**Recommendation:** Offer caller-owned caching as an optional acceleration of the direct plain-data path; do not require a global style registry or theme manager.

**Requirements:** Optional caller-owned interning/cache tables; Direct uncached plain-data path; Separate dirty domains; Generation overflow policy.

**Completion criterion:** Hovering one control in a large list recomputes its affected style values without re-resolving unrelated rows.

**Source paths:** [src/theme/theme.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/theme/theme.zig), [src/layout/incremental.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/incremental.zig), [src/runtime/frame.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/runtime/frame.zig).

**Primary references:** [R034](references.md#r034), [R007](references.md#r007).


## Themes and tokens

<a id="ui-semantic-tokens"></a>
### Role-preserving semantic color tokens

**ID:** `ui.semantic_tokens` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P1 · **Primary cost:** resolve

**Options:** surface levels; foreground/on-colors; accent/on-accent; muted; disabled; border; focus; link; success; warning; error; info; selection.

**Current source:** Six color roles exist; recolor matches raw packed color values and requires distinct source colors.

**Recommendation:** Extend existing roles and preserve identity through lowering rather than remapping equal raw colors.

**Requirements:** Typed token references; Token identity retention; Generation tracking.

**Completion criterion:** Two roles can share the same original RGBA value and diverge on theme change while an equal literal remains unchanged.

**Source paths:** [src/theme/theme.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/theme/theme.zig), [src/widgets/base.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/base.zig).

**Primary references:** [R037](references.md#r037), [R001](references.md#r001).

<a id="ui-design-scales"></a>
### Spacing, typography and shape token scales

**ID:** `ui.design_scales` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P1 · **Primary cost:** resolve

**Options:** spacing scale; radius scale; font families; font sizes; font weights; line heights; stroke widths; elevation recipes; density profiles.

**Current source:** Five-step spacing/radius/text-size scales and density exist; richer typography and component scales are not unified.

**Recommendation:** Retain current scale APIs and add semantic aliases plus composite typography recipes.

**Requirements:** Typed primitive and composite tokens; Component token bindings.

**Completion criterion:** Changing density updates dependent spacing and hit targets without accidentally scaling physical strokes or fixed assets.

**Source paths:** [src/theme/theme.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/theme/theme.zig).

**Primary references:** [R037](references.md#r037), [R001](references.md#r001).

<a id="ui-theme-scope"></a>
### Scoped themes and deterministic precedence

**ID:** `ui.theme_scope` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P1 · **Primary cost:** resolve

**Options:** application theme; subtree scope; component default; variant; size; attached override; local explicit value; environment policy.

**Current source:** Runtime themes, per-widget overrides and compile-time folded themes exist; a general layered scoped resolver is absent.

**Recommendation:** Document precedence and preserve component-local overrides during a global theme change.

**Requirements:** Scope indices; Explicit merge order; Property-wise resolution.

**Completion criterion:** A nested theme changes its descendants only; the inspector can identify the winning source for conflicting values.

**Source paths:** [src/theme/theme.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/theme/theme.zig), [src/widgets/base.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/base.zig), [src/runtime/frame.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/runtime/frame.zig).

**Primary references:** [R051](references.md#r051), [R001](references.md#r001).


## Component styling

<a id="ui-part-identifiers"></a>
### Reusable widget part styles

**ID:** `ui.part_identifiers` · **Baseline:** `partial` · **Action:** `add` · **Phase:** P1 · **Primary cost:** resolve

**Options:** background; content; label; icon; indicator; track; thumb; selection; caret; focus ring; custom parts.

**Current source:** Widgets author their own visuals and options; a consistent reusable part/variant/state contract was not found.

**Recommendation:** Allow direct part parameters and optional shared recipes without requiring a full node allocation or global registry for each decorative mark.

**Requirements:** Stable part IDs; Part-specific defaults; Owner geometry/state mapping.

**Completion criterion:** A shared thumb recipe styles slider and range handles without changing their value or input semantics.

**Source paths:** [src/widgets/base.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/base.zig), [src/theme/theme.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/theme/theme.zig).

**Primary references:** [R034](references.md#r034), [R020](references.md#r020).

<a id="ui-variants-recipes"></a>
### Named variants and reusable component recipes

**ID:** `ui.variants_recipes` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P1 · **Primary cost:** resolve

**Options:** intent; size; density; orientation; selected appearance; destructive appearance; custom recipe composition.

**Current source:** Widget-specific variants and options exist, but naming and override composition are not unified.

**Recommendation:** Allow direct plain-data recipe composition plus optional pre-resolved reuse; keep behavior separate and avoid mandatory registry setup.

**Requirements:** Plain recipe values; optional references for reuse; Stable variant identifiers; Composition rules.

**Completion criterion:** Combining a small destructive button variant with a local text-color override preserves the remaining recipe values.

**Source paths:** [src/widgets/base.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/base.zig), [src/theme/theme.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/theme/theme.zig), [src/widgets/button.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/button.zig).

**Primary references:** [R020](references.md#r020), [R001](references.md#r001).

<a id="ui-combined-states"></a>
### Combinable state-dependent styling

**ID:** `ui.combined_states` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P1 · **Primary cost:** resolve

**Options:** hover; pressed/held; focus; focus-visible; focus-within; disabled; selected; checked; indeterminate; expanded; read-only; invalid; busy; dragging; drop target; scrolling; custom bits.

**Current source:** theme.States contains eight hover/held/focused combinations; widgets have local states and a11y exposes additional semantic states.

**Recommendation:** Resolve ordered overrides without allocating a table for every theoretical state combination.

**Requirements:** Required and forbidden state masks; Property-wise precedence; Direct ordered state-rule evaluation; optional caller-owned cache of reached combinations.

**Completion criterion:** Selected plus hovered plus keyboard-focused retains selection and visible focus; disabled behavior cannot be enabled by a paint override.

**Source paths:** [src/theme/theme.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/theme/theme.zig), [src/widgets/base.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/base.zig), [src/a11y/tree.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/a11y/tree.zig).

**Primary references:** [R007](references.md#r007), [R080](references.md#r080).

<a id="ui-control-part-catalog"></a>
### Everyday control part recipes

**ID:** `ui.control_part_catalog` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** resolve

**Options:** button labels/icons; checkbox/radio marks; switch track/thumb; slider/range track/ticks/value bubble; progress track/fill; spinner; input support text.

**Current source:** All these widgets largely exist with local paint/options, but no consistent shared part recipe surface spans them.

**Recommendation:** Standardize styling of existing controls while retaining widget-specific semantics.

**Requirements:** Shared part vocabulary and direct part recipes; optional lookup; Widget recipe adapters; State mapping.

**Completion criterion:** A shared theme can style all listed controls and their disabled/focused/selected states without copying widget implementations.

**Source paths:** [src/widgets/base.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/base.zig), [src/widgets/button.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/button.zig), [src/widgets/checkbox.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/checkbox.zig), [src/widgets/radio.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/radio.zig), [src/widgets/switch.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/switch.zig), [src/widgets/slider.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/slider.zig), [src/widgets/range.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/range.zig), [src/widgets/progress.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/progress.zig).

**Primary references:** [R020](references.md#r020), [R034](references.md#r034).

<a id="ui-navigation-overlay-parts"></a>
### Navigation and overlay part recipes

**ID:** `ui.navigation_overlay_parts` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** resolve

**Options:** menu rows; accelerator text; submenu arrows; separators; popover surface; tooltip arrow; tab indicator; tab close button; breadcrumb separator; toast/status appearance.

**Current source:** Menu, popover, tooltip, tabs, breadcrumb, toast and related widgets exist with individual options.

**Recommendation:** Expose parts consistently and reuse anchor, typography and paint systems.

**Requirements:** Shared part/state recipes; Overlay placement integration; Common text/spacing tokens.

**Completion criterion:** A theme change updates every popup/navigation part while preserving accelerator alignment, overflow behavior and focus navigation.

**Source paths:** [src/widgets/menu.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/menu.zig), [src/widgets/popover.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/popover.zig), [src/widgets/tooltip.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/tooltip.zig), [src/widgets/tabs.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/tabs.zig), [src/widgets/breadcrumb.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/breadcrumb.zig), [src/widgets/toast.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/toast.zig).

**Primary references:** [R020](references.md#r020), [R001](references.md#r001).

<a id="ui-data-view-parts"></a>
### List, tree and table visual parts

**ID:** `ui.data_view_parts` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** resolve

**Options:** rows; alternating rows; cells; headers; sort indicators; selection; expanders; indent guides; drop markers; frozen dividers; resize handles.

**Current source:** List/tree/table/vlist widgets exist, but broad cross-widget part styling is not unified.

**Recommendation:** Keep row/cell style metadata compact and independent from materialized visible widgets.

**Requirements:** Part recipes over virtualized items; Logical row/column identity; Header/selection state mapping.

**Completion criterion:** Alternating and selected styles track logical rows after virtualization/reordering, while keyboard focus remains independently visible.

**Source paths:** [src/widgets/list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/list.zig), [src/widgets/tree.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/tree.zig), [src/widgets/table.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/table.zig), [src/widgets/vlist.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/vlist.zig).

**Primary references:** [R020](references.md#r020), [R034](references.md#r034).


## Style authoring

<a id="ui-typed-authoring"></a>
### Unified runtime and compile-time authoring

**ID:** `ui.typed_authoring` · **Baseline:** `partial` · **Action:** `integrate` · **Phase:** P1 · **Primary cost:** resolve

**Options:** typed Zig literals; comptime constants; shared style handles; explicit pass sequencing; runtime theme input; comptime theme folding.

**Current source:** Typed styles and both runtime/comptime front ends exist; advanced side tables require manual finishing sequences.

**Recommendation:** Preserve fine-grained passes and add useful diagonal conveniences; advanced use must not require a manager, object graph or mandatory caching.

**Requirements:** Direct plain-data input; Fine-grained caller-sequenced passes; Optional diagonal convenience adapters; Runtime/comptime parity fixtures.

**Completion criterion:** One styled control produces equivalent supported draw output in runtime and compile-time paths with explicit unsupported diagnostics.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/runtime/frame.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/runtime/frame.zig), [src/comptime/paint.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/comptime/paint.zig), [src/widgets/base.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/base.zig).

**Primary references:** [R034](references.md#r034).

<a id="ui-token-import"></a>
### Optional design-token interchange

**ID:** `ui.token_import` · **Baseline:** `not_found` · **Action:** `optional` · **Phase:** P3 · **Primary cost:** tooling

**Options:** DTCG typed tokens; aliases; groups; composite values; code generation; resource blob generation; cycle diagnostics.

**Current source:** No built-in DTCG import or external typed token compiler was identified in the audited source.

**Recommendation:** Keep interchange outside Tier 0 and generate constants or bounded data; DTCG is a Community Group specification.

**Requirements:** Offline parser/compiler; Schema validation; Resolved alias graph.

**Completion criterion:** Alias cycles and type mismatches fail during import; generated tokens preserve role identity and deterministic output.

**Source paths:** [src/theme/theme.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/theme/theme.zig).

**Primary references:** [R037](references.md#r037).

<a id="ui-stylesheet-compiler"></a>
### Optional CSS-like authoring compiler

**ID:** `ui.stylesheet_compiler` · **Baseline:** `application_authored` · **Action:** `optional` · **Phase:** P5 · **Primary cost:** tooling

**Options:** scoped classes; type/part/state rules; imports; cascade layers; selector compilation; diagnostics; declared conformance subset.

**Current source:** Core is typed Zig; markup/parser documents describe future authoring work rather than a complete stylesheet system.

**Recommendation:** Add only with a concrete consumer; CSS syntax must lower to the same typed IR instead of adding per-frame parsing.

**Requirements:** Separate compiler module; Supported grammar contract; Compiled rule dependencies.

**Completion criterion:** Unsupported syntax is diagnosed; accepted rules compile deterministically and never scan source strings during rendering.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/theme/theme.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/theme/theme.zig), [docs/plans/markup.md](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/docs/plans/markup.md).

**Primary references:** [R051](references.md#r051), [R080](references.md#r080).


## Style tooling

<a id="ui-style-inspector"></a>
### Computed-style and dependency inspector

**ID:** `ui.style_inspector` · **Baseline:** `partial` · **Action:** `add` · **Phase:** P2 · **Primary cost:** tooling

**Options:** resolved value; winning declaration; token/role origin; inherited source; part/state match; dirty reason; capability warning; capacity usage.

**Current source:** Source has devtools-related facilities and checks, but no unified computed-style provenance contract was identified.

**Recommendation:** Compile provenance out of release profiles; emit bounded diagnostic records rather than runtime callbacks.

**Requirements:** Debug provenance side tables; Resolver trace rows; Read-only inspection API.

**Completion criterion:** A conflicting state/variant override can be explained to the exact source and invalidation reason without changing program behavior.

**Source paths:** [src/theme/theme.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/theme/theme.zig), [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/layout/check.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/check.zig).

**Primary references:** [R051](references.md#r051), [R035](references.md#r035).

<a id="ui-a11y-style-validation"></a>
### Accessibility style diagnostics

**ID:** `ui.a11y_style_validation` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** tooling

**Options:** contrast analysis; focus visibility preview; target-size visualization; text-scale preview; system-color preview; state consistency; unsupported preference diagnostics.

**Current source:** Contrast checks, accessibility settings and widget/runtime harnesses exist; a comprehensive style validation view is not unified.

**Recommendation:** Build on current checks and report evaluation assumptions; do not label a theme automatically WCAG compliant.

**Requirements:** Resolved style inspection; Actual background assumptions; Semantic state export.

**Completion criterion:** Diagnostics identify actual failing color pairs and small targets, and distinguish AA focus-visible requirements from AAA focus-appearance criteria.

**Source paths:** [src/a11y/settings.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/a11y/settings.zig), [src/a11y/settings_data.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/a11y/settings_data.zig), [src/a11y/tree.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/a11y/tree.zig), [src/widgets/base.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/base.zig).

**Primary references:** [R081](references.md#r081), [R084](references.md#r084), [R085](references.md#r085), [R083](references.md#r083), [R086](references.md#r086).


## Layout and geometry

<a id="ui-size-constraints"></a>
### Preferred, minimum and maximum dimensions

**ID:** `ui.size_constraints` · **Baseline:** `partial` · **Action:** `integrate` · **Phase:** P1 · **Primary cost:** layout

**Options:** fit; fixed pixels; grow; percentage; min/max width; min/max height; preferred aspect ratio.

**Current source:** Core Style supports fit/px/grow/pct and min/max; aspect ratio is in the flex side table.

**Recommendation:** Retain existing dimensions and expose aspect ratio while specifying over-constrained outcomes.

**Requirements:** Unified dimension input; Defined constraint precedence; Intrinsic measurement rows.

**Completion criterion:** Conflicting min/max and aspect ratio produce documented deterministic sizes; percentage values are not incorrectly advertised as new.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/layout/layout.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/layout.zig), [src/layout/flex.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/flex.zig).

**Primary references:** [R068](references.md#r068).

<a id="ui-intrinsic-measurement"></a>
### Intrinsic content measurement semantics

**ID:** `ui.intrinsic_measurement` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P3 · **Primary cost:** layout

**Options:** minimum-content; maximum-content; fit-content; available-space constraints; preferred size; baseline measurement.

**Current source:** Fit sizing and text/image measurement exist; complete CSS intrinsic-size keywords and semantics are not exposed.

**Recommendation:** Provide a native intrinsic-sizing contract before considering exact CSS compatibility.

**Requirements:** Caller-sequenced measurement pass; Constraint/result rows; Cycle handling.

**Completion criterion:** A wrapped label and unwrapped label report different meaningful minima, and measured sizes agree with final line layout.

**Source paths:** [src/layout/layout.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/layout.zig), [src/text/layout/lines.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/lines.zig), [src/text/layout/stack.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/stack.zig), [src/widgets/image.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/image.zig).

**Primary references:** [R068](references.md#r068), [R022](references.md#r022).

<a id="ui-relative-units"></a>
### Relative length units and bounded expressions

**ID:** `ui.relative_units` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P3 · **Primary cost:** layout

**Options:** logical units; device pixels; parent percent; font-relative; root-font-relative; viewport-relative; container-relative; min/max/clamp; length plus percentage.

**Current source:** Core supports pixel and percentage sizes; broader relative units and expression evaluation are not unified.

**Recommendation:** Use validated bounded expressions, not an unbounded interpreter in hot layout loops.

**Requirements:** Typed expression nodes; Reference-basis metadata; Resolution stage contract.

**Completion criterion:** Changing text scale affects font-relative spacing while device-pixel strokes stay fixed; indefinite percentage bases follow documented behavior.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/layout/layout.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/layout.zig).

**Primary references:** [R075](references.md#r075).

<a id="ui-box-spacing"></a>
### Per-edge padding and margins

**ID:** `ui.box_spacing` · **Baseline:** `partial` · **Action:** `integrate` · **Phase:** P1 · **Primary cost:** layout

**Options:** physical edge padding; physical edge margins; non-collapsing margins; auto margins where supported; negative margin policy; box-sizing policy.

**Current source:** Core has four-side padding; flex side tables contain non-collapsing margins.

**Recommendation:** Expose existing margins and document non-collapsing native semantics; choose explicit policy for negative values.

**Requirements:** Shared edge records; Explicit box-sizing and validation; Front-end flex adapter.

**Completion criterion:** Margins influence placement without changing paint content bounds; nested margins never collapse implicitly.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/layout/flex.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/flex.zig), [src/layout/layout.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/layout.zig).

**Primary references:** [R035](references.md#r035), [R068](references.md#r068).

<a id="ui-row-column-gaps"></a>
### Independent gaps and line spacing

**ID:** `ui.row_column_gaps` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P3 · **Primary cost:** layout

**Options:** row gap; column gap; main-axis gap; cross-axis gap; wrap-line spacing.

**Current source:** Core has one gap; grid has row/column gaps and flex has wrapping-related spacing.

**Recommendation:** Allow separate axes while preserving the current single-gap shorthand.

**Requirements:** Axis-resolved gap fields; Shared gap semantics.

**Completion criterion:** A wrapping panel can have different item and line spacing, and orientation changes map each gap predictably.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/layout/flex.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/flex.zig), [src/layout/grid.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/grid.zig).

**Primary references:** [R046](references.md#r046), [R056](references.md#r056).

<a id="ui-logical-edges"></a>
### Direction-aware logical edges and dimensions

**ID:** `ui.logical_edges` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P3 · **Primary cost:** layout

**Options:** inline/block size; start/end padding; start/end margin; logical border mapping; logical inset; start/end alignment.

**Current source:** Rtl supports inherited LTR/RTL, logical inline padding and mirroring; other logical properties are not generalized.

**Recommendation:** Broaden the existing RTL helper rather than adding a second direction model.

**Requirements:** Direction/writing-mode resolution; Physical/logical conflict rules; Logical property metadata.

**Completion criterion:** Switching LTR to RTL mirrors logical margins and anchors while explicitly physical left/right values obey documented precedence.

**Source paths:** [src/layout/rtl.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/rtl.zig), [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/layout/flex.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/flex.zig).

**Primary references:** [R061](references.md#r061), [R076](references.md#r076).

<a id="ui-flex-distribution"></a>
### Flex basis, growth and shrink semantics

**ID:** `ui.flex_distribution` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P3 · **Primary cost:** layout

**Options:** grow weights; shrink weights; flex basis; min/max freezing; bounded native regrow; explicit compatible profile.

**Current source:** Core grow/shrink and flex weighted shrink/bounded two-pass regrow exist; no named basis and no full CSS freeze algorithm.

**Recommendation:** Keep the bounded native profile and add richer behavior only behind an explicit algorithm choice.

**Requirements:** Declared native versus compatible algorithm; Basis measurement; Bounded work policy.

**Completion criterion:** Unequal shrink weights respect minimum sizes; native bounded results and any CSS-compatible results are separately documented and tested.

**Source paths:** [src/layout/flex.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/flex.zig), [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig).

**Primary references:** [R056](references.md#r056).

<a id="ui-flex-wrap-baseline"></a>
### Wrapping, line layout and baseline alignment

**ID:** `ui.flex_wrap_baseline` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P3 · **Primary cost:** layout

**Options:** row wrap; column wrap; reverse order; line alignment; per-child cross alignment; first/last baseline; mixed text/icon baselines.

**Current source:** Flex supports row wrapping, self cross alignment and baseline on non-wrapping rows; limitations are real.

**Recommendation:** Expose present wrapping first and extend column/multiline baseline behavior with explicit semantics.

**Requirements:** Line tables; Baseline rows; Direction-aware order.

**Completion criterion:** Wrapped rows of mixed font sizes align by the selected baseline without clipping; unsupported profile combinations reject explicitly.

**Source paths:** [src/layout/flex.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/flex.zig), [src/layout/wrap.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/wrap.zig), [src/layout/baseline.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/baseline.zig).

**Primary references:** [R056](references.md#r056), [R046](references.md#r046).

<a id="ui-alignment-distribution"></a>
### Container and item alignment distribution

**ID:** `ui.alignment_distribution` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P3 · **Primary cost:** layout

**Options:** start; end; center; stretch; space-between; space-around; space-evenly; safe overflow; self override.

**Current source:** Core main/cross alignment covers start/center/end; flex/grid add limited self/stretch/line behavior.

**Recommendation:** Distinguish content distribution from individual item alignment.

**Requirements:** Free-space distribution rules; Logical axis resolution; Overflow policy.

**Completion criterion:** Space-evenly includes both outer gaps; safe alignment keeps overflowing content reachable instead of centering it offscreen.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/layout/flex.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/flex.zig), [src/layout/grid.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/grid.zig).

**Primary references:** [R046](references.md#r046).

<a id="ui-grid-basics"></a>
### Public integration of bounded grid

**ID:** `ui.grid_basics` · **Baseline:** `low_level` · **Action:** `integrate` · **Phase:** P1 · **Primary cost:** layout

**Options:** fixed tracks; fit tracks; fractional tracks; explicit cells; spans; row/column gaps; sparse auto placement; alignment.

**Current source:** Grid exports px/fit/fr tracks, spans and sparse row-order placement with one sizing round and no implicit growth.

**Recommendation:** Expose existing grid honestly as a bounded native layout rather than CSS Grid conformance.

**Requirements:** Normal frame adapter; Caller-owned track/cell arrays; Overflow diagnostics.

**Completion criterion:** A normal frontend can build a spanned grid; out-of-capacity placement preserves the documented overflow flag and never writes outside buffers.

**Source paths:** [src/layout/grid.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/grid.zig), [src/runtime/frame.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/runtime/frame.zig).

**Primary references:** [R057](references.md#r057).

<a id="ui-grid-advanced"></a>
### Richer grid tracks and placement

**ID:** `ui.grid_advanced` · **Baseline:** `not_found` · **Action:** `optional` · **Phase:** P3 · **Primary cost:** layout

**Options:** minmax; fit-content limit; auto-fit; auto-fill; implicit tracks; named lines; named areas; dense placement.

**Current source:** The audited grid intentionally lacks these richer track and placement features.

**Recommendation:** Implement as a richer selectable profile after basic grid integration.

**Requirements:** Richer track IR; Explicit iteration/capacity budget; Intrinsic measurement integration.

**Completion criterion:** Automatic track creation respects capacity, named areas resolve deterministically and dense placement never changes semantic focus order implicitly.

**Source paths:** [src/layout/grid.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/grid.zig).

**Primary references:** [R057](references.md#r057).

<a id="ui-subgrid"></a>
### Subgrid alignment across nested components

**ID:** `ui.subgrid` · **Baseline:** `not_found` · **Action:** `optional` · **Phase:** P3 · **Primary cost:** layout

**Options:** shared column tracks; shared row tracks; inherited gaps; span constraints; baseline participation.

**Current source:** No subgrid contract was found in the bounded grid implementation.

**Recommendation:** Make subgrid optional and dependency-driven; a simple shared-column helper may satisfy early use cases.

**Requirements:** Parent track dependency graph; Nested measurement ordering; Cycle prevention.

**Completion criterion:** Nested form rows align to parent tracks and update after a parent resize without indefinite layout retries.

**Source paths:** [src/layout/grid.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/grid.zig).

**Primary references:** [R057](references.md#r057).

<a id="ui-visibility-participation"></a>
### Visibility, layout and input participation

**ID:** `ui.visibility_participation` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P0 · **Primary cost:** layout

**Options:** visible; hidden with reserved space; excluded from layout; paint suppression; hit-test exclusion; semantic exclusion.

**Current source:** Clipping/visibility flags and opacity exist, but a unified author-facing contract separating participation modes was not found.

**Recommendation:** Define independent meanings instead of using zero opacity as a universal hiding mechanism.

**Requirements:** Independent participation flags; Layout/paint/hit/a11y consumers.

**Completion criterion:** Hidden-reserved content keeps space; excluded content does not; transparent interactive content follows its explicit hit policy.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/layout/layout.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/layout.zig), [src/interact/hit.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/interact/hit.zig), [src/a11y/tree.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/a11y/tree.zig).

**Primary references:** [R022](references.md#r022), [R074](references.md#r074).

<a id="ui-overflow-modes"></a>
### Overflow and scrolling semantics

**ID:** `ui.overflow_modes` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P1 · **Primary cost:** layout

**Options:** visible; clip; scroll; auto; horizontal/vertical axes; clip-only versus scroll container; scroll extent.

**Current source:** Core scroll/clip fields and scroll helpers exist; rounded/nested clips have separate rendering limits.

**Recommendation:** Unify existing scroll and clip flags without claiming clip geometry fixes that belong to the renderer.

**Requirements:** Overflow mode records; Shared scroll extents; Explicit axis interaction.

**Completion criterion:** A clip-only container cannot scroll programmatically by accident; automatic bars use the same content extents as input scrolling.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/layout/layout.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/layout.zig), [src/layout/scroll.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/scroll.zig).

**Primary references:** [R063](references.md#r063).

<a id="ui-containment-virtualization"></a>
### Containment and virtualized measurement boundaries

**ID:** `ui.containment_virtualization` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P3 · **Primary cost:** layout

**Options:** layout containment; size containment; known intrinsic placeholder; visible-range realization; content extent; bounded invalidation.

**Current source:** Incremental layout and virtual-list widgets exist; general containment/responsive dependency semantics are not exposed.

**Recommendation:** Reuse virtualized paths while defining which ancestor measurements are independent of descendants.

**Requirements:** Containment flags; Virtualized result rows; Accurate scroll extents.

**Completion criterion:** Offscreen row styling does not force realization of every row; changing a size-affecting token updates total scroll extent correctly.

**Source paths:** [src/layout/incremental.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/incremental.zig), [src/widgets/vlist.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/vlist.zig), [src/layout/layout.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/layout.zig).

**Primary references:** [R054](references.md#r054).

<a id="ui-custom-layout-protocol"></a>
### Custom layout through explicit passes

**ID:** `ui.custom_layout_protocol` · **Baseline:** `low_level` · **Action:** `extend` · **Phase:** P1 · **Primary cost:** layout

**Options:** caller-sequenced measurement; constraint rows; measurement result rows; arrange pass; baseline results; comptime specialization.

**Current source:** Frame.finish permits caller-performed layout and core design requires data-oriented caller-owned passes.

**Recommendation:** Standardize data exchange and compile-time specialization; do not inject hidden allocation or callback dispatch into Tier 0.

**Requirements:** Stable measurement/result schema; Capacity bounds; No runtime per-widget callbacks.

**Completion criterion:** A custom radial layout can use supplied rows and finish through normal paint/input processing with no runtime per-widget callback or hidden allocation.

**Source paths:** [src/runtime/frame.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/runtime/frame.zig), [src/layout/layout.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/layout.zig), [docs/DESIGN.md](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/docs/DESIGN.md).

**Primary references:** [R022](references.md#r022).

<a id="ui-pixel-rounding"></a>
### Logical geometry and pixel rounding policy

**ID:** `ui.pixel_rounding` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P0 · **Primary cost:** layout

**Options:** fractional logical coordinates; device scale; layout snapping; stroke alignment; text metric consistency; rounding accumulation.

**Current source:** Layout finalization snaps rectangles; transformations and text paths introduce additional geometry considerations.

**Recommendation:** Keep fractional geometry until the chosen raster stage and define rounding consistently across sibling distribution.

**Requirements:** Documented logical/device spaces; Shared final conversion; Scale-change invalidation.

**Completion criterion:** Fractional scaling does not accumulate gaps across a long row, and caret geometry agrees with painted glyph metrics.

**Source paths:** [src/layout/layout.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/layout.zig), [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/text/layout/lines.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/lines.zig).

**Primary references:** [R075](references.md#r075).


## Positioning and layering

<a id="ui-out-of-flow"></a>
### Out-of-flow placement and containing blocks

**ID:** `ui.out_of_flow` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P1 · **Primary cost:** layout

**Options:** parent-origin float; absolute insets; relative offsets; anchor/pivot coordinates; explicit containing block.

**Current source:** Style.float and offset exist; float places outside flow at the parent content origin, not a complete positioning model.

**Recommendation:** Preserve float semantics and add explicit position modes instead of overloading one boolean.

**Requirements:** Containing-block IDs; Unified coordinate contract; Measured versus positioned size.

**Completion criterion:** An absolutely positioned badge is excluded from sibling layout and resolves percentage insets against the documented containing box.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/layout/layout.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/layout.zig), [src/layout/overlay.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/overlay.zig).

**Primary references:** [R065](references.md#r065).

<a id="ui-anchored-overlays"></a>
### Menus and popovers anchored to geometry

**ID:** `ui.anchored_overlays` · **Baseline:** `low_level` · **Action:** `integrate` · **Phase:** P1 · **Primary cost:** layout

**Options:** anchor rect/widget; pivot; offset; preferred side; flip fallback; shift fallback; viewport constraints.

**Current source:** overlay exports anchors/pivots, offsets, viewport flipping and zstack facilities.

**Recommendation:** Integrate existing anchors into consistent popover/menu recipes; extend fallback policies without callback allocation.

**Requirements:** Anchor/result rows; Frame sequencing; Clip and focus coordination.

**Completion criterion:** A tooltip near each viewport edge chooses a visible fallback and remains anchored after its target moves.

**Source paths:** [src/layout/overlay.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/overlay.zig), [src/widgets/popover.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/popover.zig), [src/widgets/tooltip.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/tooltip.zig).

**Primary references:** [R047](references.md#r047).

<a id="ui-fixed-sticky"></a>
### Fixed and sticky positioning

**ID:** `ui.fixed_sticky` · **Baseline:** `not_found` · **Action:** `add` · **Phase:** P3 · **Primary cost:** layout

**Options:** viewport-fixed; overlay-root-fixed; sticky start/end; scroll-container constraint; sticky stacking policy.

**Current source:** The float flag and overlay helpers do not establish a general fixed/sticky style contract.

**Recommendation:** Define which coordinate spaces and scroll ancestors govern these modes.

**Requirements:** Scroll-container ancestry; Sticky constraint pass; Paint/hit ordering rules.

**Completion criterion:** A sticky table header remains within its scroll container and stops at its end; nested clipping and input coordinates remain correct.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/layout/overlay.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/overlay.zig), [src/layout/scroll.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/scroll.zig).

**Primary references:** [R065](references.md#r065).

<a id="ui-layer-order"></a>
### Consistent paint and hit layer order

**ID:** `ui.layer_order` · **Baseline:** `low_level` · **Action:** `integrate` · **Phase:** P0 · **Primary cost:** resolve

**Options:** zstack; stable numeric levels; inherited levels; paint order; hit order; local isolated context as optional.

**Current source:** Layers uses 256 global levels inheriting the parent maximum; layered paint and hit helpers exist but are separate paths.

**Recommendation:** Connect existing layered paint and hit paths before adding richer stacking-context semantics.

**Requirements:** Single ordering contract; Shared ordered IDs; Explicit global versus local context semantics.

**Completion criterion:** The visually topmost overlapping eligible widget receives input; global level behavior is not mislabeled nested CSS isolation.

**Source paths:** [src/layout/overlay.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/overlay.zig), [src/draw/paint.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paint.zig), [src/interact/hit.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/interact/hit.zig).

**Primary references:** [R065](references.md#r065).


## Responsive styling

<a id="ui-responsive-conditions"></a>
### Viewport and container style conditions

**ID:** `ui.responsive_conditions` · **Baseline:** `application_authored` · **Action:** `add` · **Phase:** P3 · **Primary cost:** resolve

**Options:** width/height ranges; named breakpoints; orientation; container size class; scoped predicates; boundary subscriptions.

**Current source:** Applications can inspect viewport/platform and choose typed styles; no shared declarative condition resolver was found.

**Recommendation:** Use typed predicates with explicit dependencies; dock panels should respond to their own size.

**Requirements:** Condition IDs; Environment/container generations; Cycle-free query contract.

**Completion criterion:** Resizing one dock panel changes its compact variant without restyling unrelated panels or creating size-query oscillation.

**Source paths:** [src/runtime/frame.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/runtime/frame.zig), [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/layout/incremental.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/incremental.zig).

**Primary references:** [R054](references.md#r054), [R078](references.md#r078).

<a id="ui-environment-conditions"></a>
### Environment and input-capability conditions

**ID:** `ui.environment_conditions` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P1 · **Primary cost:** platform

**Options:** system scheme; system accent; text scale; pointer precision; hover capability; touch density; locale/direction; unknown preference.

**Current source:** Platform dark/accent helpers, density and accessibility settings exist; a uniform condition interface does not.

**Recommendation:** Integrate existing helpers and expose only host-observed capabilities without pretending all backends have every preference.

**Requirements:** Host-fed environment rows; Unknown-value semantics; Per-category subscriptions.

**Completion criterion:** Changing a hover capability updates affected recipes only; unknown is distinguishable from an explicit false preference.

**Source paths:** [src/theme/theme.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/theme/theme.zig), [src/a11y/settings_data.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/a11y/settings_data.zig), [src/runtime/frame.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/runtime/frame.zig).

**Primary references:** [R078](references.md#r078).

<a id="ui-safe-area-occlusion"></a>
### Safe-area and viewport occlusion inputs

**ID:** `ui.safe_area_occlusion` · **Baseline:** `application_authored` · **Action:** `add` · **Phase:** P3 · **Primary cost:** platform

**Options:** safe insets; keyboard occlusion; window decorations; usable overlay rectangle; host display cutouts.

**Current source:** Overlay placement uses viewport constraints; richer host occlusion/safe-area data was not identified as a style contract.

**Recommendation:** Let the host provide geometry; keep OS discovery outside Tier 0.

**Requirements:** Host-provided usable-region rows; Anchor/layout integration.

**Completion criterion:** A focused input and its popup remain within the supplied usable rectangle when a keyboard occlusion region appears.

**Source paths:** [src/layout/overlay.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/overlay.zig), [src/runtime/frame.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/runtime/frame.zig).

**Primary references:** [R047](references.md#r047), [R075](references.md#r075).

<a id="ui-locale-theme-content"></a>
### Locale-aware component presentation

**ID:** `ui.locale_theme_content` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P3 · **Primary cost:** platform

**Options:** LTR/RTL recipes; localized label expansion; numeric formatting hooks; locale font preferences; icon mirroring policy; reading order.

**Current source:** RTL helpers, Unicode text and widgets exist; integrated locale-aware style/content policy remains distributed.

**Recommendation:** Keep translation/number formatting host-authored while style recipes accommodate expansion and intentional icon mirroring.

**Requirements:** Host locale data; Logical layout integration; Explicit mirroring metadata.

**Completion criterion:** Switching locale expands labels without clipping, mirrors only designated icons and preserves semantic keyboard reading order.

**Source paths:** [src/layout/rtl.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/rtl.zig), [src/theme/theme.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/theme/theme.zig), [src/text/unicode/bidi.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/unicode/bidi.zig), [src/widgets/base.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/base.zig).

**Primary references:** [R061](references.md#r061), [R076](references.md#r076), [R015](references.md#r015).


## Optional document and specialized layout

<a id="ui-special-layout-modules"></a>
### Specialized native and document layouts

**ID:** `ui.special_layout_modules` · **Baseline:** `application_authored` · **Action:** `optional` · **Phase:** P5 · **Primary cost:** layout

**Options:** radial; dock; flow; masonry; constraint layout; multicolumn text; paged fragmentation; table border collapse; floats.

**Current source:** Core supplies row/column, bounded flex/grid and explicit pass escape hatches; these specialized models are not general built-ins.

**Recommendation:** Build actual-use-case modules without burdening every node or claiming complete document layout.

**Requirements:** Separate algorithm modules; Declared measurement semantics; Memory/work budgets.

**Completion criterion:** An enabled module publishes its supported semantics and capacity limits; disabled modules add no per-node storage requirement.

**Source paths:** [src/layout/layout.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/layout.zig), [src/layout/flex.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/flex.zig), [src/layout/grid.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/grid.zig), [src/runtime/frame.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/runtime/frame.zig).

**Primary references:** [R056](references.md#r056), [R057](references.md#r057), [R065](references.md#r065).

<a id="ui-document-typography"></a>
### Specialist document typography

**ID:** `ui.document_typography` · **Baseline:** `not_found` · **Action:** `optional` · **Phase:** P5 · **Primary cost:** text

**Options:** hanging punctuation; drop caps; text on paths; publication justification; mathematical layout; counters/lists; footnotes; page-specific typography.

**Current source:** No general document compositor or these specialized typography contracts were found in the audited UI text pipeline.

**Recommendation:** Keep these outside the native control core and add modules for demonstrated consumers.

**Requirements:** Optional document model; Specialized measurement/shaping modules; Explicit resource budgets.

**Completion criterion:** An optional module declares a bounded supported subset and can be disabled without adding ordinary label storage or work.

**Source paths:** [src/text/layout/lines.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/lines.zig), [src/text/layout/spans.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/spans.zig), [src/draw/paths.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paths.zig).

**Primary references:** [R069](references.md#r069), [R060](references.md#r060), [R070](references.md#r070).


## Typography

<a id="ui-public-text-pipeline"></a>
### Advanced text in the normal frame path

**ID:** `ui.public_text_pipeline` · **Baseline:** `partial` · **Action:** `integrate` · **Phase:** P1 · **Primary cost:** text

**Options:** font-backed measurement; paragraph options; shaping features; rich spans; runtime/comptime profile reporting; explicit backend selection.

**Current source:** TextStyle exposes px/color/font/wrap; normal Frame.end uses Mono while advanced layout requires manual stage/finish.

**Recommendation:** Expose existing text algorithms before implementing replacements.

**Requirements:** Shared text profile input; Normal finish adapter; Measurement/render metric parity.

**Completion criterion:** An ordinary frame can render and measure a centered wrapped proportional-font label with the same metrics used by hit queries.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/runtime/frame.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/runtime/frame.zig), [src/text/layout/stack.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/stack.zig), [src/text/layout/lines.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/lines.zig).

**Primary references:** [R024](references.md#r024), [R031](references.md#r031).

<a id="ui-font-selection"></a>
### Family, resource and style matching

**ID:** `ui.font_selection` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** text

**Options:** font handles; family lists; system families; embedded families; fallback families; deterministic matching; font-loading generation.

**Current source:** Font handles, OpenType loading, OS discovery and fallback chains exist; no high-level family/style matching contract is unified.

**Recommendation:** Keep explicit handles available and add deterministic resource matching above the existing loader.

**Requirements:** Caller-supplied face/family catalogs and matching metadata; optional registry adapter; Host discovery adapters; Matching metadata.

**Completion criterion:** A missing requested family chooses the documented fallback; loading a new matching font invalidates dependent metrics without corrupting handles.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/text/font/opentype.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/font/opentype.zig), [src/text/fallback/fallback.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/fallback/fallback.zig), [src/text/fallback/system.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/fallback/system.zig).

**Primary references:** [R041](references.md#r041), [R005](references.md#r005).

<a id="ui-font-weight-width-style"></a>
### Font weight, width and slant selection

**ID:** `ui.font_weight_width_style` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** text

**Options:** named/numeric weights; normal/italic/oblique; condensed/expanded width; synthesis policy; face metadata.

**Current source:** opentype.Style selects bold/italic bits; named weights, stretch and synthesis policy are not exposed through TextStyle.

**Recommendation:** Prefer actual font faces and make synthetic bold/oblique an explicit fallback policy.

**Requirements:** Expanded face metadata; Matching rules; Raster cache identity.

**Completion criterion:** A requested weight selects the correct face when present and follows the stated synthesis fallback when absent.

**Source paths:** [src/text/font/opentype.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/font/opentype.zig), [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig).

**Primary references:** [R041](references.md#r041).

<a id="ui-shaping-features"></a>
### Shaping feature and run-property control

**ID:** `ui.shaping_features` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** text

**Options:** liga; kern; mark/mkmk; feature tags; feature ranges; script; language; direction; shaper profile.

**Current source:** Built-in Features exposes liga/kern/mark/mkmk; optional HarfBuzz guesses run properties and uses default features.

**Recommendation:** Expose existing toggles and explicit run metadata while distinguishing the capabilities of each shaper.

**Requirements:** Feature-list spans; Explicit run properties; Built-in/HarfBuzz capability mapping.

**Completion criterion:** Toggling a supported ligature feature changes the intended run without changing unrelated text; unsupported features are reported by profile.

**Source paths:** [src/text/shape/shape.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/shape/shape.zig), [src/text/shape/harfbuzz.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/shape/harfbuzz.zig), [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig).

**Primary references:** [R031](references.md#r031), [R041](references.md#r041).

<a id="ui-paragraph-alignment"></a>
### Paragraph alignment and justification

**ID:** `ui.paragraph_alignment` · **Baseline:** `low_level` · **Action:** `integrate` · **Phase:** P1 · **Primary cost:** text

**Options:** logical start/end; center; alignment factor; justification; last-line policy; direction-aware alignment.

**Current source:** lines exposes alignment factor, justify and direction; Stack.layoutAt initializes start alignment.

**Recommendation:** Expose existing alignment and justification through the normal API; add missing last-line semantics explicitly.

**Requirements:** Public paragraph options; Line metrics propagation; Shaper-aware justification.

**Completion criterion:** Centered, end-aligned and justified paragraphs use the same measured line widths as painting, including RTL runs.

**Source paths:** [src/text/layout/lines.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/lines.zig), [src/text/layout/stack.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/stack.zig), [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig).

**Primary references:** [R069](references.md#r069), [R024](references.md#r024).

<a id="ui-whitespace-tabs"></a>
### Whitespace, newlines and tabs

**ID:** `ui.whitespace_tabs` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** text

**Options:** preserve/collapse; preserved line breaks; no-wrap modes; tab size; tab stops; trailing-space policy.

**Current source:** No-wrap, mandatory newline breaks, a final empty line after a trailing newline and hanging trailing-space behavior already exist. Configurable collapse/preserve policy and tab sizing/stops remain extensions.

**Recommendation:** Apply visual whitespace policy without rewriting the stored document.

**Requirements:** Display-to-source mapping; Whitespace normalization policy; Tab measurement.

**Completion criterion:** Preserved tabs align predictably and copying a visually collapsed label retains the documented original-text behavior.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/text/layout/stack.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/stack.zig), [src/text/layout/lines.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/lines.zig), [src/text/edit/buffer.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/edit/buffer.zig).

**Primary references:** [R069](references.md#r069).

<a id="ui-wrap-hyphenation"></a>
### Line-breaking policies and hyphenation

**ID:** `ui.wrap_hyphenation` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P3 · **Primary cost:** text

**Options:** word wrapping; cluster emergency wrapping; strict/loose language breaks; manual soft hyphen; automatic hyphenation; balanced wrapping.

**Current source:** Unicode line breaking and cluster-safe emergency wrapping exist; richer policies/hyphenation are not a unified public contract.

**Recommendation:** Retain the existing fast breaker; make language dictionaries and balanced wrapping optional.

**Requirements:** Language-aware break policy; Optional hyphenation data; Bounded line optimization.

**Completion criterion:** Emergency wrapping preserves clusters; a discretionary hyphen appears only at a chosen break and layout remains bounded.

**Source paths:** [src/text/layout/lines.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/lines.zig), [src/text/unicode/line.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/unicode/line.zig).

**Primary references:** [R038](references.md#r038), [R069](references.md#r069).

<a id="ui-text-overflow"></a>
### Truncation and maximum visible lines

**ID:** `ui.text_overflow` · **Baseline:** `low_level` · **Action:** `extend` · **Phase:** P1 · **Primary cost:** text

**Options:** clip; end ellipsis; start ellipsis; middle ellipsis; custom marker; max lines; fade; full-value access.

**Current source:** lines has maximum-line ellipsizing and metrics; TextStyle and normal Frame.end do not expose the complete capability.

**Recommendation:** Integrate existing ellipsize/max-line support first; add start/middle modes with explicit logical-direction behavior.

**Requirements:** Public overflow options; Cluster-safe marker fitting; Accessible original value.

**Completion criterion:** A middle-truncated path preserves its selected suffix, never splits a cluster and exposes its full value to copying/accessibility.

**Source paths:** [src/text/layout/lines.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/lines.zig), [src/text/layout/stack.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/stack.zig), [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig).

**Primary references:** [R063](references.md#r063), [R024](references.md#r024).

<a id="ui-line-metrics"></a>
### Line height, leading and baseline metrics

**ID:** `ui.line_metrics` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** text

**Options:** line-height factor; absolute line height; leading distribution; baseline type; baseline offset; paragraph spacing; metric access; leading trim.

**Current source:** Paragraph metrics and manual modification are available, but no unified style contract controls these metrics.

**Recommendation:** Distinguish logical line boxes from ink bounds and expose metrics needed by component alignment.

**Requirements:** Run and line metric rows; Mixed-font baseline policy; Ink versus logical bounds.

**Completion criterion:** Mixed font sizes share the selected baseline; larger line spacing avoids glyph/caret clipping and produces matching measured height.

**Source paths:** [src/text/layout/lines.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/lines.zig), [src/text/layout/spans.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/spans.zig), [src/text/font/opentype.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/font/opentype.zig).

**Primary references:** [R060](references.md#r060), [R005](references.md#r005).

<a id="ui-text-spacing"></a>
### Letter and word spacing

**ID:** `ui.text_spacing` · **Baseline:** `not_found` · **Action:** `add` · **Phase:** P2 · **Primary cost:** text

**Options:** letter spacing; word spacing; font-relative spacing; negative spacing policy; script-safe spacing; justification interaction.

**Current source:** A unified TextStyle spacing contract was not identified; existing paragraph metrics can be manually altered.

**Recommendation:** Adjust advances with script-aware rules and keep shaping and spacing responsibilities explicit.

**Requirements:** Cluster-aware advance adjustment; Script restrictions; Measurement invalidation.

**Completion criterion:** Spacing changes update measured width, hit positions and painting consistently without separating required joining behavior.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/text/layout/lines.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/lines.zig), [src/text/shape/shape.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/shape/shape.zig).

**Primary references:** [R069](references.md#r069), [R005](references.md#r005).

<a id="ui-rich-run-segmentation"></a>
### Rich text shaping runs versus paint spans

**ID:** `ui.rich_run_segmentation` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P0 · **Primary cost:** text

**Options:** font/size runs; color-only spans; selection spans; background spans; shared shaping context; cluster overlap policy.

**Current source:** Spans supports byte-range font/size/color changes but every span boundary interrupts shaping, including color-only boundaries.

**Recommendation:** Do not reshape or break ligatures merely because a color/highlight boundary changes.

**Requirements:** Separate shaping and paint spans; Cluster-aware style application; Stable source indices.

**Completion criterion:** Adding a color-only highlight preserves glyph selection, positions and paragraph width; paint segmentation alone changes.

**Source paths:** [src/text/layout/spans.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/spans.zig), [src/text/shape/shape.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/shape/shape.zig), [src/text/layout/lines.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/lines.zig).

**Primary references:** [R031](references.md#r031), [R005](references.md#r005).

<a id="ui-text-decorations"></a>
### Text decorations

**ID:** `ui.text_decorations` · **Baseline:** `not_found` · **Action:** `add` · **Phase:** P2 · **Primary cost:** paint

**Options:** underline; overline; strikethrough; color; thickness; offset; solid/double/dotted/dashed/wavy; skip ink; emphasis marks.

**Current source:** No unified decoration style contract was identified alongside existing rich spans and text primitives.

**Recommendation:** Use shared decoration records and preserve shaping; keep less common emphasis marks optional.

**Requirements:** Decoration runs; Font metrics; Paint/effect bounds; Optional skip-ink geometry.

**Completion criterion:** Underline offset and thickness follow resized text; decoration bounds participate in damage and do not alter glyph metrics.

**Source paths:** [src/text/layout/spans.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/spans.zig), [src/text/layout/lines.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/lines.zig), [src/draw/draw_list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig).

**Primary references:** [R070](references.md#r070).

<a id="ui-inline-objects-baselines"></a>
### Inline objects and baseline shifts

**ID:** `ui.inline_objects_baselines` · **Baseline:** `not_found` · **Action:** `add` · **Phase:** P3 · **Primary cost:** text

**Options:** inline icons; embedded widgets as measured boxes; superscript; subscript; baseline shift; vertical alignment; placeholder runs.

**Current source:** Rich spans cover font/size/color; generic inline objects and styled baseline-shift records were not identified.

**Recommendation:** Use caller-supplied measured rows for inline objects rather than runtime measurement callbacks.

**Requirements:** Measured inline object rows; Baseline/line-box negotiation; Logical index policy.

**Completion criterion:** An inline icon and subscript affect line height correctly and remain selectable/navigable according to the documented index policy.

**Source paths:** [src/text/layout/spans.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/spans.zig), [src/text/layout/lines.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/lines.zig), [src/layout/baseline.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/baseline.zig).

**Primary references:** [R060](references.md#r060), [R005](references.md#r005).

<a id="ui-text-paint-spans"></a>
### Foreground, background and highlight paint for text

**ID:** `ui.text_paint_spans` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** paint

**Options:** solid foreground; background spans; semantic highlight; shared paint references; optional gradient/stroke text capability.

**Current source:** Rich spans support color; general text paint objects, backgrounds and complex paint propagation are not unified.

**Recommendation:** Reuse the general paint system and avoid breaking shaping at paint-only boundaries.

**Requirements:** Paint-only spans; Shared paint resource IDs; Text renderer capability reporting.

**Completion criterion:** Changing a highlight background or foreground role repaints without changing shaped glyphs; unsupported text paint kinds fail explicitly.

**Source paths:** [src/text/layout/spans.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/spans.zig), [src/draw/draw_list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig), [src/draw/paint.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paint.zig).

**Primary references:** [R005](references.md#r005).

<a id="ui-advanced-typographic-features"></a>
### OpenType typographic variants

**ID:** `ui.advanced_typographic_features` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P3 · **Primary cost:** text

**Options:** tabular/proportional numerals; lining/oldstyle numerals; fractions; slashed zero; small caps; stylistic sets; alternate glyphs; localized forms.

**Current source:** Built-in shaping supports a limited feature set; arbitrary advanced feature selection is not exposed in TextStyle.

**Recommendation:** Offer useful numeric variants first for engineering tables while preserving a low-level feature list.

**Requirements:** Typed feature conveniences; Low-level tag mapping; Shaper support metadata.

**Completion criterion:** Tabular digits align changing values without layout jitter when supported; unsupported variants are diagnosed rather than falsely advertised.

**Source paths:** [src/text/shape/shape.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/shape/shape.zig), [src/text/shape/harfbuzz.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/shape/harfbuzz.zig), [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig).

**Primary references:** [R041](references.md#r041).


## Optional typography

<a id="ui-font-formats-variations"></a>
### Extended font formats and variable/color fonts

**ID:** `ui.font_formats_variations` · **Baseline:** `partial` · **Action:** `optional` · **Phase:** P5 · **Primary cost:** text

**Options:** CFF outlines; CFF2; variable axes; named instances; optical sizing; color glyph formats; font palette selection.

**Current source:** Loader supports TrueType outlines and TTC face selection and explicitly rejects OTTO/CFF; general variable/color-font support is not established.

**Recommendation:** Keep format support explicit and enable additional formats per profile rather than implying all OpenType is supported.

**Requirements:** Optional parser/raster modules; Axis-aware caches; Capability checks; Bounded font data validation.

**Completion criterion:** Unsupported formats fail clearly; enabled variable axes alter geometry and metrics with distinct cache keys.

**Source paths:** [src/text/font/opentype.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/font/opentype.zig), [src/text/shape/harfbuzz.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/shape/harfbuzz.zig).

**Primary references:** [R041](references.md#r041), [R005](references.md#r005).

<a id="ui-vertical-ruby"></a>
### Vertical writing and ruby annotations

**ID:** `ui.vertical_ruby` · **Baseline:** `not_found` · **Action:** `optional` · **Phase:** P5 · **Primary cost:** text

**Options:** vertical right-to-left; vertical left-to-right; sideways text; glyph orientation; ruby placement; vertical baselines.

**Current source:** RTL helpers mirror the x-axis and Unicode bidi exists, but this is not a complete writing-mode/ruby layout system.

**Recommendation:** Add a separate advanced text profile only when applications require it.

**Requirements:** Writing-mode-aware layout; Vertical shaping metrics; Ruby annotation model.

**Completion criterion:** Vertical text uses correct glyph orientation and logical edges; ruby contributes documented line extents without disrupting base-text indexing.

**Source paths:** [src/layout/rtl.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/rtl.zig), [src/text/layout/lines.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/lines.zig), [src/text/shape/harfbuzz.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/shape/harfbuzz.zig).

**Primary references:** [R076](references.md#r076), [R060](references.md#r060).


## Typography and internationalization

<a id="ui-bidi-itemization"></a>
### Bidi, script and language integration

**ID:** `ui.bidi_itemization` · **Baseline:** `low_level` · **Action:** `integrate` · **Phase:** P1 · **Primary cost:** text

**Options:** paragraph direction; bidi isolation; script itemization; language runs; visual/logical index mapping; mixed RTL/LTR text.

**Current source:** Unicode script/bidi modules and paragraph reorder exist; front-end itemization and shaper composition require explicit sequencing.

**Recommendation:** Reuse existing Unicode machinery and make the advanced text profile sequencing explicit.

**Requirements:** Run itemization pass; Shared logical/visual mapping; Shaper direction contract.

**Completion criterion:** Arabic mixed with Latin labels and numbers preserves correct visual order and stable logical selection indices.

**Source paths:** [src/text/unicode/bidi.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/unicode/bidi.zig), [src/text/unicode/script.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/unicode/script.zig), [src/text/layout/lines.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/lines.zig), [src/text/shape/harfbuzz.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/shape/harfbuzz.zig).

**Primary references:** [R040](references.md#r040), [R031](references.md#r031).

<a id="ui-cluster-fallback"></a>
### Cluster-aware font fallback

**ID:** `ui.cluster_fallback` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P0 · **Primary cost:** text

**Options:** family chains; script fallback; combining sequences; variation selectors; emoji joins; missing-glyph diagnostics.

**Current source:** Fallback Chain/Runs exists but built-in fallback resolves per character, requiring care for joined/variation/complex sequences.

**Recommendation:** Preserve shaping context across fallback and avoid splitting sequences that require a single font decision.

**Requirements:** Cluster-level fallback decisions; Shaping-context preservation; Fallback cache keys.

**Completion criterion:** A supported joined emoji or base-plus-mark sequence is not broken by per-code-point fallback when one font can render the sequence.

**Source paths:** [src/text/fallback/fallback.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/fallback/fallback.zig), [src/text/shape/cluster.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/shape/cluster.zig), [src/text/unicode/grapheme.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/unicode/grapheme.zig).

**Primary references:** [R039](references.md#r039), [R031](references.md#r031).

<a id="ui-grapheme-editing"></a>
### Grapheme-safe indexing and editing

**ID:** `ui.grapheme_editing` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P0 · **Primary cost:** text

**Options:** cursor motion; selection; deletion; word navigation; cluster-safe truncation; UTF-8 validation.

**Current source:** Standard text widgets already use edit.Editor, with grapheme-based movement/backspace/delete and optional bidi mapping; Unicode grapheme/word and cluster-aware wrapping modules also exist. Consistent mappings and conformance across all new styling/truncation paths still need verification.

**Recommendation:** Preserve existing algorithms through all new styling paths rather than reimplementing byte-based shortcuts.

**Requirements:** Consistent text-index units; Edit/layout cluster mapping; Conformance fixtures.

**Completion criterion:** Caret movement, backspace and ellipsis never split an extended grapheme cluster, including combined marks and supported emoji sequences.

**Source paths:** [src/text/unicode/grapheme.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/unicode/grapheme.zig), [src/text/unicode/word.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/unicode/word.zig), [src/text/edit/edit.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/edit/edit.zig), [src/text/edit/moves.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/edit/moves.zig), [src/text/layout/lines.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/lines.zig), [src/widgets/textfield.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/textfield.zig), [src/widgets/textarea.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/textarea.zig).

**Primary references:** [R039](references.md#r039), [R038](references.md#r038).

<a id="ui-locale-text-transform"></a>
### Locale-aware display text transformations

**ID:** `ui.locale_text_transform` · **Baseline:** `not_found` · **Action:** `optional` · **Phase:** P3 · **Primary cost:** text

**Options:** uppercase; lowercase; title case; full-width forms; display-only mapping; source-to-display indices.

**Current source:** No unified locale-aware transform style and mapping contract was identified.

**Recommendation:** Treat transformation as a display layer with explicit locale and preserve original content.

**Requirements:** Unicode case data; Locale handling; Source/display index map.

**Completion criterion:** Locale-sensitive case conversion can change displayed length while selection/copy behavior remains defined against the original text.

**Source paths:** [src/text/unicode/property.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/unicode/property.zig), [src/text/layout/lines.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/lines.zig).

**Primary references:** [R069](references.md#r069).


## Typography and interaction

<a id="ui-editing-parts"></a>
### Editable text visual parts

**ID:** `ui.editing_parts` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** paint

**Options:** caret color/width/shape; blink preference; active/inactive selection; placeholder; IME composition underline; error marker; selection handles; prefix/suffix.

**Current source:** Textfield/textarea include caret, selection and IME plumbing; a uniform part-style contract is absent.

**Recommendation:** Keep text input semantics in the edit system and expose visuals through common part/state recipes.

**Requirements:** Part IDs for editing state; Edit/layout coordinate mapping; Host IME integration.

**Completion criterion:** A theme swap updates caret/selection/composition appearance without losing composition text, selection endpoints or keyboard focus.

**Source paths:** [src/widgets/textfield.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/textfield.zig), [src/widgets/textarea.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/textarea.zig), [src/text/edit/edit.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/edit/edit.zig), [src/text/layout/spans.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/spans.zig).

**Primary references:** [R020](references.md#r020), [R074](references.md#r074).


## Typography infrastructure

<a id="ui-text-cache-contract"></a>
### Text cache and invalidation contract

**ID:** `ui.text_cache_contract` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P0 · **Primary cost:** text

**Options:** font-match cache; shaped-run cache; paragraph-layout cache; glyph raster cache; font generations; variation/feature/language keys; color-only reuse.

**Current source:** Shaping/cache/layout modules exist; a comprehensive new styling dependency contract is needed across public paths.

**Recommendation:** Reuse current caches and invalidate only stages dependent on changed properties, allowing boundary-sensitive reshaping where required.

**Requirements:** Explicit cache key schemas; Generation-aware resources; Separate text dirty domains.

**Completion criterion:** Color-only changes reuse shaped runs; font-feature/language changes invalidate them; width changes yield correct line breaks and caret positions.

**Source paths:** [src/text/shape/cache.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/shape/cache.zig), [src/text/layout/stack.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/stack.zig), [src/text/layout/lines.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/lines.zig), [src/text/layout/spans.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/spans.zig).

**Primary references:** [R031](references.md#r031), [R005](references.md#r005).


## Interaction styling

<a id="ui-cursor-styles"></a>
### Pointer cursor appearance

**ID:** `ui.cursor_styles` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** platform

**Options:** arrow; text; pointer; crosshair; move; grab/grabbing; resize directions; forbidden; progress; custom cursor/hotspot.

**Current source:** Context.Cursor already defines arrow, pointer, text, grab and horizontal/vertical resize; Frame.setCursor emits host cursor intent with last-request-wins semantics, and text widgets use it. More cursor types, custom hotspots and style-driven eligibility/ordering remain extensions.

**Recommendation:** Resolve cursor intent as data and let the platform host apply supported cursors.

**Requirements:** Resolved cursor IDs; Host cursor adapter; Topmost hit target policy.

**Completion criterion:** Overlapping widgets select the topmost eligible cursor; custom hotspots are scaled consistently and unsupported cursors use an explicit fallback.

**Source paths:** [src/runtime/context.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/runtime/context.zig), [src/runtime/frame.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/runtime/frame.zig), [src/widgets/textfield.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/textfield.zig), [src/widgets/textarea.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/textarea.zig), [src/interact/hit.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/interact/hit.zig), [src/interact/interaction.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/interact/interaction.zig).

**Primary references:** [R074](references.md#r074).

<a id="ui-hit-target-geometry"></a>
### Visual and hit-target geometry policy

**ID:** `ui.hit_target_geometry` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P0 · **Primary cost:** resolve

**Options:** hit padding; minimum target size; shape hit testing; pass-through; self versus subtree exclusion; transformed input.

**Current source:** Hit testing includes near-target selection with topmost tie-breaking and configurable global touch slop (default eight logical pixels). Style.transform remains paint-only; per-node expansion, shape policies and transform-consistent input remain extensions.

**Recommendation:** Separate usable hit geometry from decorative geometry and define overlap priority for enlarged targets.

**Requirements:** Inverse coordinate transforms; Independent hit bounds; Shared clipping/ordering contract.

**Completion criterion:** A visually transformed button receives clicks where it is painted; expanded neighboring targets resolve overlap deterministically.

**Source paths:** [src/interact/hit.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/interact/hit.zig), [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/interact/interaction.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/interact/interaction.zig).

**Primary references:** [R085](references.md#r085), [R074](references.md#r074).

<a id="ui-focus-policy"></a>
### Keyboard-visible focus styling policy

**ID:** `ui.focus_policy` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P1 · **Primary cost:** resolve

**Options:** focus-visible; focus-within; always-show-focus; focus part; modality policy; focus retained under hover; focus scroll reveal.

**Current source:** Focus already tracks modality-sensitive visibility; key/pointer transitions update it, ring respects it, and runtime supports always_show_focus. Reuse this state for consistent parts/recipes; add focus-within and broader composed decoration/reveal behavior.

**Recommendation:** Preserve focus semantics and use dedicated outline decoration from the paint system.

**Requirements:** Reuse and propagate existing input-modality/focus state; Focus part mapping; Non-layout-changing focus paint.

**Completion criterion:** Keyboard navigation produces a visible focus indicator without changing layout; hover/selected states cannot erase it unintentionally.

**Source paths:** [src/interact/focus.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/interact/focus.zig), [src/runtime/context.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/runtime/context.zig), [src/theme/theme.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/theme/theme.zig), [src/a11y/settings_data.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/a11y/settings_data.zig).

**Primary references:** [R083](references.md#r083), [R082](references.md#r082), [R080](references.md#r080).

<a id="ui-disabled-readonly-semantics"></a>
### Behavioral state and visual-state consistency

**ID:** `ui.disabled_readonly_semantics` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P0 · **Primary cost:** resolve

**Options:** disabled; read-only; busy; invalid; required; selected; expanded; state propagation.

**Current source:** Widgets and accessibility records expose several states, but styling state recipes are narrower and inconsistent.

**Recommendation:** Have styles observe semantic state; do not treat disabled colors as the mechanism that disables input.

**Requirements:** Single semantic state source; Style observers; Input and a11y synchronization.

**Completion criterion:** A disabled control is non-activating regardless of its colors, and read-only text can preserve allowed selection/copy behavior.

**Source paths:** [src/widgets/base.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/base.zig), [src/a11y/tree.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/a11y/tree.zig), [src/interact/interaction.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/interact/interaction.zig).

**Primary references:** [R007](references.md#r007), [R015](references.md#r015).


## Accessibility and environment

<a id="ui-contrast-system-palettes"></a>
### High contrast and system color palettes

**ID:** `ui.contrast_system_palettes` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P1 · **Primary cost:** platform

**Options:** light high-contrast; dark high-contrast; system semantic colors; forced-color policy; contrast checks; per-component exceptions.

**Current source:** High-contrast settings and contrast checks already exist; high-contrast light/system-color policies need broader integration.

**Recommendation:** Extend existing accessibility palette handling while preserving intended state distinctions beyond hue.

**Requirements:** Semantic role mapping; Platform palette input; Contrast-aware recipes.

**Completion criterion:** Switching high contrast preserves legible text and identifiable control boundaries in both light and dark profiles.

**Source paths:** [src/a11y/settings.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/a11y/settings.zig), [src/a11y/settings_data.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/a11y/settings_data.zig), [src/theme/theme.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/theme/theme.zig).

**Primary references:** [R081](references.md#r081), [R084](references.md#r084), [R078](references.md#r078).

<a id="ui-text-scale-tolerance"></a>
### User text scale and spacing tolerance

**ID:** `ui.text_scale_tolerance` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P0 · **Primary cost:** layout

**Options:** text scaling; line spacing override; word spacing override; letter spacing override; reflow; minimum readable text; content preservation.

**Current source:** Settings already supplies text scale; richer spacing options and every component layout must participate consistently.

**Recommendation:** Retain text-scale support and make all public text/control paths tolerant of user overrides.

**Requirements:** User typography preferences; Constraint-aware component layout; No fixed-height clipping assumptions.

**Completion criterion:** Large text and user spacing settings do not clip labels, hide values or make primary controls unreachable.

**Source paths:** [src/a11y/settings.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/a11y/settings.zig), [src/a11y/settings_data.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/a11y/settings_data.zig), [src/theme/theme.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/theme/theme.zig), [src/text/layout/lines.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/lines.zig).

**Primary references:** [R086](references.md#r086), [R081](references.md#r081).

<a id="ui-reduced-effect-preferences"></a>
### Reduced motion and transparency preferences

**ID:** `ui.reduced_effect_preferences` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P1 · **Primary cost:** platform

**Options:** existing reduced-motion behavior; reduced transparency; opaque surfaces; static busy alternative; scroll motion preference; explicit policy for essential animation.

**Current source:** Reduced motion already affects runtime animations; reduced-transparency and general effect fallback policies are not unified.

**Recommendation:** Connect existing reduced-motion behavior to the resolver and add reduced-transparency policy without redesigning motion internals.

**Requirements:** Host preference rows; Effect/recipe fallback mapping; Preserve animation integration.

**Completion criterion:** Preference changes replace translucent surfaces with readable opaque equivalents and preserve already-supported reduced-motion behavior.

**Source paths:** [src/a11y/settings_data.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/a11y/settings_data.zig), [src/a11y/settings.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/a11y/settings.zig), [src/runtime/frame.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/runtime/frame.zig), [src/theme/theme.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/theme/theme.zig).

**Primary references:** [R078](references.md#r078).

<a id="ui-noncolor-semantics"></a>
### State indication beyond color

**ID:** `ui.noncolor_semantics` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P1 · **Primary cost:** resolve

**Options:** icons; text labels; patterns; underline; shape differences; selected markers; error/supporting text; a11y state mapping.

**Current source:** Widgets provide marks and accessibility states; a consistent recipe contract enforcing multi-channel state indication is not established.

**Recommendation:** Provide useful default recipes that remain understandable when colors are unavailable or overridden.

**Requirements:** Semantic state/part mapping; Accessible labels; Recipe validation.

**Completion criterion:** Error, checked and selected states remain distinguishable in a grayscale/system-color rendering and agree with accessibility state.

**Source paths:** [src/widgets/base.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/base.zig), [src/a11y/tree.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/a11y/tree.zig), [src/widgets/check.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/check.zig).

**Primary references:** [R084](references.md#r084), [R020](references.md#r020).


## Scrolling

<a id="ui-scrollbar-parts"></a>
### Scrollbar part appearance

**ID:** `ui.scrollbar_parts` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** paint

**Options:** track; thumb; corner; optional arrow buttons; colors; radii; borders; minimum thumb; hover/drag appearance; active/auto visibility.

**Current source:** Scroll widget has a vertical track/thumb and keyboard controls; bar_px is fixed at 8.

**Recommendation:** Replace fixed paint constants with part recipes and keep thumb hit geometry usable.

**Requirements:** Scrollbar part IDs; Resolved geometry/paint rows; Visibility-state policy.

**Completion criterion:** A themed scrollbar supports distinct hover/drag states and never paints a thumb below the configured minimum length.

**Source paths:** [src/widgets/scroll.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/scroll.zig), [src/theme/theme.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/theme/theme.zig).

**Primary references:** [R067](references.md#r067), [R033](references.md#r033).

<a id="ui-scrollbar-layout"></a>
### Scrollbar axes, placement and gutters

**ID:** `ui.scrollbar_layout` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** layout

**Options:** horizontal; vertical; both axes; RTL placement; overlay; reserved classic gutter; stable gutter; both-edge gutter; thickness.

**Current source:** Current widget primarily exposes a vertical bar with fixed width; no complete placement/gutter contract is present.

**Recommendation:** Keep reserved space independent from visibility and avoid oscillating layout when bars appear.

**Requirements:** Axis-aware scrollbar layout; Content viewport calculation; Stable overflow convergence.

**Completion criterion:** Content near an overflow threshold settles without repeated bar show/hide cycles; RTL placement and two-axis corner geometry are correct.

**Source paths:** [src/widgets/scroll.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/scroll.zig), [src/layout/scroll.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/scroll.zig), [src/layout/rtl.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/rtl.zig).

**Primary references:** [R063](references.md#r063), [R067](references.md#r067).

<a id="ui-scroll-behavior-policy"></a>
### Optional scroll behavior policies

**ID:** `ui.scroll_behavior_policy` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P3 · **Primary cost:** resolve

**Options:** scroll axes; momentum; chaining; overscroll; snap alignment; snap stops; scroll padding; scroll margin; smooth policy.

**Current source:** Lower-level scroll helpers and widget input exist; broad unified snap/overscroll/chain style policies were not established by the audit.

**Recommendation:** Keep behavior adjacent to styling and preserve caller control over scrolling mechanics.

**Requirements:** Separate behavior policy rows; Scroll ancestry; Snap target data; Host input normalization.

**Completion criterion:** Nested scroll containers follow an explicit chaining policy; snap targets remain reachable and reduced-motion preferences are respected.

**Source paths:** [src/layout/scroll.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/scroll.zig), [src/widgets/scroll.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/scroll.zig), [src/interact/gestures.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/interact/gestures.zig).

**Primary references:** [R066](references.md#r066), [R064](references.md#r064), [R033](references.md#r033).

<a id="ui-scroll-focus-reveal"></a>
### Focused target reveal and scroll anchoring

**ID:** `ui.scroll_focus_reveal` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P1 · **Primary cost:** resolve

**Options:** reveal focused control; nested reveal; scroll padding; keep visible region; stable selected-item view; content-change anchor.

**Current source:** Focus, scroll and keyboard helpers exist; a unified cross-container reveal/anchoring contract was not identified.

**Recommendation:** Use an explicit caller-sequenced reveal pass rather than hidden recursive callbacks.

**Requirements:** Focus-to-scroll target rows; Ancestor scroll sequence; Content anchor IDs.

**Completion criterion:** Tabbing to an offscreen input reveals it through nested scrollers without unexpectedly jumping unrelated containers.

**Source paths:** [src/interact/focus.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/interact/focus.zig), [src/widgets/scroll.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/scroll.zig), [src/layout/scroll.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/scroll.zig).

**Primary references:** [R033](references.md#r033), [R066](references.md#r066).


## Application-specific styling

<a id="ui-editor-canvas-parts"></a>
### Extensible EDA and editor visual vocabulary

**ID:** `ui.editor_canvas_parts` · **Baseline:** `application_authored` · **Action:** `optional` · **Phase:** P3 · **Primary cost:** resolve

**Options:** canvas/grid; crosshair; selection rectangle; snap marker; ports; wires; labels; handles; splitter; toolbar/status parts.

**Current source:** Custom materials/draw commands and common widgets provide extension paths; a domain-specific EDA style catalog is not built in.

**Recommendation:** Allow application-defined part/token values or IDs so domain recipes do not expand core Style for every object kind; registration and shared lookup remain optional.

**Requirements:** Application-defined part/token IDs; Portable primitive composition; Explicit custom bounds.

**Completion criterion:** An application supplies port/wire/selection recipes and changes themes without adding domain-specific branches to core rendering.

**Source paths:** [src/draw/draw_list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig), [src/widgets/splitter.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/splitter.zig), [src/widgets/toolbar.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/toolbar.zig), [src/widgets/statusbar.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/statusbar.zig).

**Primary references:** [R034](references.md#r034).


## Rendering contracts

<a id="visual-capability-profiles"></a>
### Declared renderer capabilities and fallback policy

**ID:** `visual.capability_profiles` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P0 · **Primary cost:** tooling

**Options:** exact support; explicit approximation; unsupported diagnostic; compile-time feature selection; caller-selected fallback.

**Current source:** features.Usage and comptime feature analysis exist; software strips selected kinds, while ES2 omits params effects and ignores material handles.

**Recommendation:** Extend existing usage reporting into a capability contract; do not make simple draw functions depend on a registry.

**Requirements:** backend capability descriptors; existing feature-usage analysis; fallback policy passed by the caller.

**Completion criterion:** A requested unsupported effect produces the caller-selected fallback or a diagnostic on every advertised backend, including ES2 and software.

**Source paths:** [src/draw/features.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/features.zig), [src/comptime/features.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/comptime/features.zig), [src/render/sw/sw.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/sw/sw.zig), [src/render/gles/es2.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/gles/es2.zig), [src/render/iface.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/iface.zig).

**Primary references:** [R023](references.md#r023).

<a id="visual-paint-bounds"></a>
### Shared conservative paint bounds

**ID:** `visual.paint_bounds` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P0 · **Primary cost:** paint

**Options:** transformed corners; stroke and outline growth; shadow and filter expansion; old/new damage union; custom-content bounds.

**Current source:** Visibility, damage culling and overlap tests use layout-space rect/clip bounds; transforms and three-sigma shadow growth are not incorporated consistently.

**Recommendation:** Centralize pure bounds calculations and let callers supply conservative bounds for custom commands; disable unsafe optimizations when bounds are unknown.

**Requirements:** pure bounds functions; shared damage/culling/order use; explicit unknown-bounds policy.

**Completion criterion:** A node translated from offscreen to onscreen and a shadow whose sigma changes are neither culled nor incompletely repainted.

**Source paths:** [src/layout/layout.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/layout.zig), [src/draw/damage.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/damage.zig), [src/draw/order.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/order.zig), [src/draw/features.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/features.zig), [src/render/shaders/quad.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl).

**Primary references:** [R019](references.md#r019), [R049](references.md#r049).

<a id="visual-alpha-representation"></a>
### Alpha and color-transfer contracts

**ID:** `visual.alpha_representation` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P0 · **Primary cost:** paint

**Options:** straight-alpha input; premultiplied surface storage; defined texture import conversion; explicit blend space; transparent-pixel handling.

**Current source:** RGBA8 colors and source-over rendering exist, but a general end-to-end contract covering imported images, effects and intermediate surfaces is not exposed.

**Recommendation:** Make representation and transfer choices explicit at resource boundaries without requiring a managed resource subsystem for ordinary colors.

**Requirements:** documented resource formats; software/GPU conversion parity; surface-format metadata.

**Completion criterion:** Transparent colored texels and alpha gradients avoid dark fringes across import, filtering and compositing, with documented software/GPU tolerance.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/render/shaders/quad.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl), [src/render/sw/sw.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/sw/sw.zig), [src/assets/image_atlas.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/assets/image_atlas.zig).

**Primary references:** [R052](references.md#r052), [R044](references.md#r044).

<a id="visual-coordinate-spaces"></a>
### Coherent paint, clip, text and hit coordinate spaces

**ID:** `visual.coordinate_spaces` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P0 · **Primary cost:** paint

**Options:** layout space; local paint space; world transform; inverse pointer mapping; singular-matrix policy.

**Current source:** Style.transform affects quads; text/custom payloads, clipping and hit testing do not share that transform contract.

**Recommendation:** Keep a clearly named paint-only mode if useful, and add a coherent subtree mode through explicit data and passes.

**Requirements:** shared transform utilities; text/custom command propagation; inverse-transform hit testing.

**Completion criterion:** A transformed labeled control paints, clips and responds at the same location; singular transforms have deterministic documented behavior.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/draw/inherit.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/inherit.zig), [src/draw/paint.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paint.zig), [src/draw/draw_list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig), [src/interact/hit.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/interact/hit.zig), [src/comptime/paint.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/comptime/paint.zig).

**Primary references:** [R071](references.md#r071).

<a id="visual-clip-geometry-contract"></a>
### Shared clip geometry across draw kinds

**ID:** `visual.clip_geometry_contract` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P0 · **Primary cost:** paint

**Options:** clip stack or equivalent indexed records; intersection; rectangular fast path; text/custom propagation; separate hit shape.

**Current source:** Quads carry one rounded clip tuple, while text and custom commands carry only rectangular clips; nested rounded intersections are reduced incompletely.

**Recommendation:** Expose plain clip records and bounded caller storage; optional builders may simplify nesting without hiding ownership.

**Requirements:** caller-owned clip records; shared clip references; backend lowering.

**Completion criterion:** Nested rounded clips produce the same visible intersection for backgrounds, labels, images and participating custom content.

**Source paths:** [src/draw/inherit.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/inherit.zig), [src/layout/layout.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/layout.zig), [src/draw/draw_list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig), [src/draw/paint.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paint.zig), [src/interact/hit.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/interact/hit.zig).

**Primary references:** [R062](references.md#r062), [R003](references.md#r003).

<a id="visual-decoration-composition"></a>
### Composition of multiple visual decorations

**ID:** `visual.decoration_composition` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P0 · **Primary cost:** paint

**Options:** fill plus image; gradient plus patterned border; multiple backgrounds; shadow plus radius plus clip; foreground decoration.

**Current source:** Stock params.x selects one feature per quad, so gradients, nine-slice mapping and patterned borders cannot all be selected on one node.

**Recommendation:** Compose existing low-level primitives into ordered commands; make any recipe or cache optional and avoid combinatorial feature enums.

**Requirements:** ordered plain-data paint descriptions; bounded draw expansion; preserved simple-quad fast path.

**Completion criterion:** One control displays a gradient, dashed border, image layer, rounded clipping and shadow together with stable ordering and bounded command count.

**Source paths:** [src/draw/features.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/features.zig), [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/draw/paint.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paint.zig), [src/draw/draw_list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig), [src/render/shaders/quad.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl).

**Primary references:** [R049](references.md#r049), [R003](references.md#r003).


## Color

<a id="visual-rgba8"></a>
### Existing compact RGBA colors

**ID:** `visual.rgba8` · **Baseline:** `integrated` · **Action:** `retain` · **Phase:** P1 · **Primary cost:** resolve

**Options:** rgb; rgba; hex; transparent; white; black.

**Current source:** types.Color provides packed RGBA8 and existing constructors used by normal Style and TextStyle fields.

**Recommendation:** Retain the cheap value type and constructors as the everyday path.

**Requirements:** preserved packed ABI; plain value constructors.

**Completion criterion:** Existing source code and exact packed channel values retain their meaning after richer color options are introduced.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig).

**Primary references:** [R052](references.md#r052).

<a id="visual-color-conversions"></a>
### Additional color authoring and conversion

**ID:** `visual.color_conversions` · **Baseline:** `not_found` · **Action:** `add` · **Phase:** P2 · **Primary cost:** resolve

**Options:** HSL; HWB; Lab/LCH; OKLab/OKLCH; named authoring colors; conversion and gamut policy.

**Current source:** The audited general color API is RGBA8; no broad typed authoring/conversion family was found.

**Recommendation:** Offer pure constructors/converters that can run once or at comptime; do not put string parsing or color conversion in per-pixel loops.

**Requirements:** pure conversion functions; explicit output gamut; optional authoring adapters.

**Completion criterion:** Reference conversion vectors round-trip within stated tolerances, and out-of-gamut input follows the documented policy.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig).

**Primary references:** [R052](references.md#r052).

<a id="visual-color-interpolation"></a>
### Explicit color mixing and interpolation

**ID:** `visual.color_interpolation` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** resolve

**Options:** sRGB; linear-light RGB; OKLab; polar hue direction; premultiplied-alpha interpolation.

**Current source:** Two-color gradients and runtime color transitions exist, but selectable perceptual/linear and alpha-aware interpolation are not a unified contract.

**Recommendation:** Use one explicit interpolation description for optional rich gradients and color motion while preserving the legacy result by default.

**Requirements:** pure interpolation functions; brush and animation reuse; defined alpha treatment.

**Completion criterion:** Known midpoint colors and transparent-endpoint cases match the selected space in both static gradients and animated colors.

**Source paths:** [src/draw/features.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/features.zig), [src/runtime/frame.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/runtime/frame.zig), [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/render/shaders/quad.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl).

**Primary references:** [R052](references.md#r052).


## Output and platform effects

<a id="visual-wide-gamut"></a>
### Managed wide-gamut output

**ID:** `visual.wide_gamut` · **Baseline:** `not_found` · **Action:** `optional` · **Phase:** P5 · **Primary cost:** platform

**Options:** Display-P3 authoring; output color-space metadata; gamut mapping; SDR fallback; image color-space conversion.

**Current source:** No general wide-gamut paint, surface and output contract was found in the audited RGBA8 pipeline.

**Recommendation:** Add an optional complete output profile; retain SDR as a documented supported path.

**Requirements:** backend surface-format support; platform output metadata; image conversion; capture/export policy.

**Completion criterion:** Wide-gamut content remains correctly tagged through rendering and capture, with an explicit consistent SDR conversion on unsupported targets.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/render/iface.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/iface.zig), [src/render/wgpu/wgpu.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/wgpu/wgpu.zig), [src/render/sw/sw.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/sw/sw.zig).

**Primary references:** [R052](references.md#r052).

<a id="visual-hdr"></a>
### HDR surfaces and tone mapping

**ID:** `visual.hdr` · **Baseline:** `not_found` · **Action:** `optional` · **Phase:** P5 · **Primary cost:** platform

**Options:** extended range; SDR reference white; display headroom; tone mapping; PQ/HLG or linear output profile; HDR/SDR mixing.

**Current source:** No HDR surface, headroom or tone-mapping API was found; current colors are packed RGBA8.

**Recommendation:** Treat HDR as a complete optional backend/platform profile, informed by the draft specification rather than a mandatory core color expansion.

**Requirements:** floating/extended-range surfaces; platform compositor support; display metadata; defined fallback.

**Completion criterion:** SDR controls retain their intended luminance in an HDR scene and unsupported displays receive a documented tone-mapped result.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/render/iface.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/iface.zig), [src/render/wgpu/wgpu.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/wgpu/wgpu.zig).

**Primary references:** [R053](references.md#r053).

<a id="visual-pixel-alignment"></a>
### Pixel snapping and fractional geometry

**ID:** `visual.pixel_alignment` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P0 · **Primary cost:** paint

**Options:** logical coordinates; device-scale conversion; pixel-aligned borders; fractional borders; deferred snapping.

**Current source:** layout.finalize snaps layout rectangles; the complete relationship among nested transforms, fractional edges and device-scale output needs a shared contract.

**Recommendation:** Keep logical geometry explicit and apply a documented snapping policy without repeated ancestor rounding.

**Requirements:** defined rounding stage; device-scale input; paint/clip/hit agreement.

**Completion criterion:** A one-device-pixel line remains stable at supported scales, and nested fractional transforms do not accumulate avoidable alignment drift.

**Source paths:** [src/layout/layout.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/layout.zig), [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/render/shaders/quad.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl).

**Primary references:** [R018](references.md#r018).

<a id="visual-antialiasing"></a>
### Shape and clip antialiasing policy

**ID:** `visual.antialiasing` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** paint

**Options:** coverage-based shapes; hard-edge option; path coverage; clip-edge quality; backend quality profile.

**Current source:** Rounded quad and path coverage rendering exist, but a portable author-visible quality policy across all shapes and clips is not unified.

**Recommendation:** Expose quality only where it changes a meaningful choice; preserve good defaults and exact rectangular fast paths.

**Requirements:** existing coverage algorithms; quality capability reporting; consistent clip compositing.

**Completion criterion:** Thin shapes and nested clip edges avoid double-darkening/seams, with a documented software/GPU comparison tolerance.

**Source paths:** [src/render/shaders/quad.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl), [src/render/sw/sw.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/sw/sw.zig), [src/draw/paths.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paths.zig).

**Primary references:** [R018](references.md#r018), [R017](references.md#r017).

<a id="visual-native-materials"></a>
### Optional window-system materials

**ID:** `visual.native_materials` · **Baseline:** `not_found` · **Action:** `optional` · **Phase:** P5 · **Primary cost:** platform

**Options:** macOS visual-effect material; Windows Mica; active/inactive appearance; transparency preference; solid fallback.

**Current source:** Custom host rendering exists, but no built-in native visual-effect/Mica material bridge was established by the audit.

**Recommendation:** Offer optional host-side adapters; keep native window materials separate from in-app backdrop blur.

**Requirements:** optional platform adapters; window integration owned by host; preference/fallback reporting.

**Completion criterion:** Unsupported platforms and reduced-transparency/high-contrast conditions select a readable explicit fallback without changing core renderer ownership.

**Source paths:** [docs/guide/custom.md](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/docs/guide/custom.md), [src/render/iface.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/iface.zig).

**Primary references:** [R013](references.md#r013), [R032](references.md#r032).

<a id="visual-effect-quality-limits"></a>
### Effect quality and resource limits

**ID:** `visual.effect_quality_limits` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P0 · **Primary cost:** tooling

**Options:** offscreen byte limit; surface dimensions; blur radius; clip depth; path complexity; gradient stops; resolution scale.

**Current source:** Caller-owned bounded buffers and feature stripping are established architecture, but new effects need explicit compatible limits and overflow behavior.

**Recommendation:** Extend the existing bounded-memory philosophy; let callers choose budgets and quality rather than allocating hidden full-window surfaces.

**Requirements:** plain capacity descriptors; per-operation requirements; diagnostics; optional quality presets.

**Completion criterion:** Every effect exposes or validates required capacity and exceeding it never leaves partially rendered or semantically ambiguous output.

**Source paths:** [docs/DESIGN.md](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/docs/DESIGN.md), [src/draw/features.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/features.zig), [src/render/iface.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/iface.zig), [src/draw/draw_list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig).

**Primary references:** [R016](references.md#r016), [R021](references.md#r021).


## Backgrounds

<a id="visual-solid-background"></a>
### Solid fill and transparent background

**ID:** `visual.solid_background` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P1 · **Primary cost:** paint

**Options:** solid RGBA fill; no paint; transparent paint; independent image tint.

**Current source:** Style.fill is integrated, but transparent fill becomes a white tint for a nonwhite texture, conflating absence and literal transparency.

**Recommendation:** Preserve direct solid fills and provide an unambiguous way to distinguish no fill, transparent fill and texture tint.

**Requirements:** explicit presence semantics; backward-compatible fill/tint lowering.

**Completion criterion:** An intentionally transparent image tint is distinguishable from an omitted tint without changing plain solid-fill output.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/draw/paint.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paint.zig).

**Primary references:** [R049](references.md#r049).

<a id="visual-background-layers"></a>
### Ordered background paint layers

**ID:** `visual.background_layers` · **Baseline:** `application_authored` · **Action:** `add` · **Phase:** P2 · **Primary cost:** paint

**Options:** solid base; image layers; gradient layers; per-layer alpha; ordered combination.

**Current source:** Applications can stack separate nodes/custom draws, but the normal style has no general ordered background-list contract.

**Recommendation:** Accept plain slices of layer descriptions and optionally provide recipes; keep the one-layer fast path.

**Requirements:** caller-provided layer slices; paint ordering; bounds and clip integration.

**Completion criterion:** Transparent upper layers reveal lower layers in the declared order, and resizing updates geometry without changing ordering.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/draw/paint.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paint.zig), [src/draw/features.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/features.zig).

**Primary references:** [R049](references.md#r049).

<a id="visual-background-geometry"></a>
### Background origin, clipping and attachment

**ID:** `visual.background_geometry` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** paint

**Options:** content/padding/border reference box; per-layer clip box; local positioning; scroll-relative attachment; fixed attachment where supported.

**Current source:** Fill/texture painting uses the existing node rectangle and inherited clipping; independent per-background reference boxes and attachments are not integrated.

**Recommendation:** Define geometry per layer using explicit references; reserve viewport-fixed behavior for a declared profile.

**Requirements:** box geometry access; scroll coordinate semantics; layer-specific bounds.

**Completion criterion:** Changing padding or scrolling moves each layer according to its chosen reference box and attachment without moving unrelated content.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/draw/paint.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paint.zig), [src/layout/layout.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/layout.zig).

**Primary references:** [R049](references.md#r049).

<a id="visual-foreground-decoration"></a>
### Foreground and overlay decoration

**ID:** `visual.foreground_decoration` · **Baseline:** `low_level` · **Action:** `integrate` · **Phase:** P2 · **Primary cost:** paint

**Options:** foreground brush; selection overlay; focus overlay; content-under/over ordering; noninteractive decorative layers.

**Current source:** Custom rendering supports underlay/overlay and inline commands; applications can author extra nodes in paint order.

**Recommendation:** Offer optional helpers that emit ordinary ordered commands while preserving direct interleaving and the host render loop.

**Requirements:** explicit command ordering; noninteractive decoration policy; shared bounds.

**Completion criterion:** A foreground decoration consistently covers content without intercepting input or requiring a second hidden event target.

**Source paths:** [docs/guide/custom.md](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/docs/guide/custom.md), [src/core/customs.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/customs.zig), [src/draw/paint.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paint.zig), [src/draw/draw_list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig).

**Primary references:** [R003](references.md#r003).


## Gradients

<a id="visual-linear-gradient"></a>
### Linear gradient geometry

**ID:** `visual.linear_gradient` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** paint

**Options:** angle; explicit endpoints; logical bounds reference; arbitrary stop span.

**Current source:** features.linear provides a two-color gradient with an angle using node fill as the first color.

**Recommendation:** Retain the two-color helper and lower richer linear brushes to the same simple path when possible.

**Requirements:** existing stock linear path; optional richer brush description.

**Completion criterion:** Existing angles preserve their results, while endpoint-based gradients remain stable under resizing and fractional transforms.

**Source paths:** [src/draw/features.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/features.zig), [src/render/shaders/quad.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl), [src/render/sw/sw.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/sw/sw.zig).

**Primary references:** [R058](references.md#r058).

<a id="visual-radial-gradient"></a>
### Radial gradient geometry

**ID:** `visual.radial_gradient` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** paint

**Options:** circle; ellipse; center; x/y radii; closest/farthest bounds modes.

**Current source:** features.radial supports two colors, normalized center and one circular radius.

**Recommendation:** Keep the current circular representation as a fast case and add explicit elliptical geometry.

**Requirements:** richer radial brush data; bounds resolution; software sampling.

**Completion criterion:** Off-center elliptical gradients and zero-radius edge cases follow the documented result across backends.

**Source paths:** [src/draw/features.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/features.zig), [src/render/shaders/quad.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl), [src/render/sw/sw.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/sw/sw.zig).

**Primary references:** [R058](references.md#r058).

<a id="visual-conic-gradient"></a>
### Conic or sweep gradients

**ID:** `visual.conic_gradient` · **Baseline:** `not_found` · **Action:** `add` · **Phase:** P2 · **Primary cost:** paint

**Options:** center; start angle; angular stops; seam policy; repetition.

**Current source:** The stock feature enum exposes linear and radial gradients but no conic feature.

**Recommendation:** Add conic geometry through the shared brush interface instead of a widget-specific effect.

**Requirements:** angular brush sampler; stop interpolation; software/GPU parity.

**Completion criterion:** The zero/full-turn seam, hard angular stops and rotated center produce consistent output without cracks.

**Source paths:** [src/draw/features.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/features.zig), [src/render/shaders/quad.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl), [src/render/sw/sw.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/sw/sw.zig).

**Primary references:** [R059](references.md#r059), [R025](references.md#r025).

<a id="visual-gradient-stops"></a>
### Arbitrary stops and transition hints

**ID:** `visual.gradient_stops` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** paint

**Options:** ordered stop positions; multiple colors; coincident hard stops; transition hints; out-of-range stops; explicit interpolation space.

**Current source:** Existing gradient params hold only a start/end color and cannot encode a stop list.

**Recommendation:** Take raw stop spans with explicit lifetime; optional cached lookup tables should remain an optimization layer.

**Requirements:** caller-owned immutable stop spans; validation; optional precomputed sampling tables.

**Completion criterion:** Hard stops stay sharp, invalid ordering is handled predictably, and many-stop gradients respect a declared capacity.

**Source paths:** [src/draw/features.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/features.zig), [src/render/shaders/quad.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl), [src/render/sw/sw.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/sw/sw.zig).

**Primary references:** [R059](references.md#r059).

<a id="visual-gradient-spread"></a>
### Gradient repetition and spread modes

**ID:** `visual.gradient_spread` · **Baseline:** `not_found` · **Action:** `add` · **Phase:** P2 · **Primary cost:** paint

**Options:** pad; repeat; reflect; repeating linear; repeating radial; repeating conic.

**Current source:** No shared gradient spread/tile mode was found in the current two-color feature helpers.

**Recommendation:** Keep spread behavior independent of gradient geometry and document degenerate periods.

**Requirements:** brush coordinate mapping; zero-period policy; sampler parity.

**Completion criterion:** Repeated gradients align at period boundaries under negative coordinates, fractional scaling and zero-length periods.

**Source paths:** [src/draw/features.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/features.zig), [src/render/shaders/quad.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl), [src/render/sw/sw.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/sw/sw.zig).

**Primary references:** [R059](references.md#r059).


## Borders, corners and outlines

<a id="visual-border-edges"></a>
### Independent border edges

**ID:** `visual.border_edges` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** paint

**Options:** per-edge width; per-edge color or brush; per-edge style; unequal corner joins; logical edge resolution.

**Current source:** Style has a single border width and color, plus existing circular radius data.

**Recommendation:** Keep uniform borders compact; represent asymmetric edges as optional plain data that can lower to several primitives.

**Requirements:** edge border description; join geometry; brush reuse.

**Completion criterion:** Unequal widths and colors join without gaps at rounded corners and respect a documented logical-edge mapping.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/core/tree.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/tree.zig), [src/draw/paint.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paint.zig), [src/render/shaders/quad.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl).

**Primary references:** [R049](references.md#r049), [R050](references.md#r050).

<a id="visual-border-patterns"></a>
### Border patterns and continuous dash phase

**ID:** `visual.border_patterns` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** paint

**Options:** solid; dashed; dotted; double; custom dash phase; optional groove/ridge/inset/outset.

**Current source:** features.dashed and dotted exist; phase restarts by side and their selector excludes gradient/nine-slice features on the same quad.

**Recommendation:** Preserve the existing simple patterns and add continuous perimeter semantics before adding ornamental styles.

**Requirements:** composed decoration lowering; rounded perimeter evaluation; pattern joins.

**Completion criterion:** Dashes traverse rounded corners with a stable phase while the same control retains a gradient fill.

**Source paths:** [src/draw/features.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/features.zig), [src/render/shaders/quad.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl), [src/render/sw/sw.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/sw/sw.zig).

**Primary references:** [R049](references.md#r049), [R050](references.md#r050).

<a id="visual-border-alignment"></a>
### Inside, centered and outside borders

**ID:** `visual.border_alignment` · **Baseline:** `not_found` · **Action:** `add` · **Phase:** P2 · **Primary cost:** paint

**Options:** inside; center; outside; layout contribution; paint overflow.

**Current source:** No explicit public border alignment contract was found in the uniform border fields.

**Recommendation:** Keep border placement distinct from stroke width and make content-padding consequences explicit.

**Requirements:** geometry expansion/inset functions; bounds integration; documented layout semantics.

**Completion criterion:** Changing alignment moves the stroke as specified, updates paint bounds, and changes layout only according to the documented policy.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/draw/paint.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paint.zig), [src/draw/damage.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/damage.zig).

**Primary references:** [R002](references.md#r002).

<a id="visual-corner-radii"></a>
### Independent circular and elliptical corner radii

**ID:** `visual.corner_radii` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** paint

**Options:** uniform radius; four circular radii; x/y radius pairs; percentage radii; capsule helper; overlap normalization.

**Current source:** Uniform radius and four independent scalar corner radii exist; elliptical radii and CSS-compatible normalization are not a complete contract.

**Recommendation:** Retain circular fast paths and add one reusable radius-resolution function for richer geometry.

**Requirements:** shared shape calculation; normalization; border/clip/shadow reuse.

**Completion criterion:** Oversized asymmetric radii normalize without self-overlap and produce matching border, background, clip and shadow geometry.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/core/tree.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/tree.zig), [src/draw/inherit.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/inherit.zig), [src/render/shaders/quad.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl).

**Primary references:** [R049](references.md#r049).

<a id="visual-corner-shapes"></a>
### Specialist corner shapes

**ID:** `visual.corner_shapes` · **Baseline:** `not_found` · **Action:** `optional` · **Phase:** P5 · **Primary cost:** paint

**Options:** round; square; bevel; scoop; notch; squircle/superellipse.

**Current source:** The current radius machinery represents circular rounded corners rather than a general corner-shape family.

**Recommendation:** Use the extensible shape path first; the CSS corner-shape catalog is draft guidance rather than a compatibility commitment.

**Requirements:** path/shape extension; consistent inner-border geometry; optional cached geometry.

**Completion criterion:** A shaped corner gives matching fill, border and clip contours, including thick borders and concave variants.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/draw/paths.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paths.zig), [src/render/shaders/quad.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl).

**Primary references:** [R050](references.md#r050).

<a id="visual-outlines"></a>
### Independent outline and focus-ring paint

**ID:** `visual.outlines` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** paint

**Options:** width; color or brush; pattern; offset; shape following; outside paint bounds.

**Current source:** Focus.ring exposes a rectangle and applications/widgets can create extra nodes; theme focus commonly changes border fields.

**Recommendation:** Expose a plain outline decoration that leaves layout unchanged; focus policy remains separate from drawing the ring.

**Requirements:** outline geometry helper; shared shape/bounds; focus-visible input from caller.

**Completion criterion:** Showing a keyboard-focus ring causes no reflow and does not clip the ring or confuse focus with pointer hover.

**Source paths:** [src/interact/focus.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/interact/focus.zig), [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/draw/paint.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paint.zig).

**Primary references:** [R074](references.md#r074).


## Images

<a id="visual-image-fit-position"></a>
### Image fit and placement within a stable box

**ID:** `visual.image_fit_position` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** paint

**Options:** stretch/fill; contain; cover; none; scale-down; x/y position; independent content box.

**Current source:** widgets_image supports stretch/contain/cover; cover is centered and contain changes the actual node size.

**Recommendation:** Provide independent destination geometry while retaining the current fitting helper for compatible callers.

**Requirements:** pure fit-rectangle helper; separate box/image geometry; intrinsic size.

**Completion criterion:** A fixed-size image box retains its layout dimensions across all fit modes and supports off-center cover cropping.

**Source paths:** [src/widgets/image.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/image.zig), [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/draw/paint.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paint.zig).

**Primary references:** [R058](references.md#r058), [R004](references.md#r004).

<a id="visual-image-crop"></a>
### Source cropping and texture coordinates

**ID:** `visual.image_crop` · **Baseline:** `integrated` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** paint

**Options:** normalized UV rectangle; source-pixel crop; atlas subregion; source orientation; explicit mirroring.

**Current source:** Style.uv and atlas-backed image rendering already provide texture subregion cropping.

**Recommendation:** Retain direct UV access and add pure convenience conversions for pixel crops and orientation.

**Requirements:** typed source/destination units; atlas-safe coordinate calculation.

**Completion criterion:** A crop selects the intended texels without adjacent-atlas bleeding and retains its meaning under DPI scaling.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/widgets/image.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/image.zig), [src/assets/image_atlas.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/assets/image_atlas.zig).

**Primary references:** [R004](references.md#r004).

<a id="visual-image-tint"></a>
### Independent image tint and alpha

**ID:** `visual.image_tint` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** paint

**Options:** RGBA tint; explicit image opacity; no tint; literal transparent tint; optional color filter.

**Current source:** Textures multiply by node fill, with transparent fill used as a white-tint sentinel; inherited primitive opacity is also applied.

**Recommendation:** Separate the image appearance inputs while keeping the old fill-multiplication path available for existing code.

**Requirements:** presence-aware tint data; separation from background fill; alpha contract.

**Completion criterion:** Image tint, background fill and image opacity can be changed independently without sentinel collisions.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/draw/paint.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paint.zig), [src/render/shaders/quad.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl), [src/render/sw/sw.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/sw/sw.zig).

**Primary references:** [R004](references.md#r004).

<a id="visual-image-repeat"></a>
### Image tiling and texture address modes

**ID:** `visual.image_repeat` · **Baseline:** `not_found` · **Action:** `add` · **Phase:** P2 · **Primary cost:** paint

**Options:** repeat-x; repeat-y; repeat-both; no-repeat; mirror; space; round.

**Current source:** No portable style-level repeat contract was found; software sampling clamps coordinates and host GPU sampler configuration is lower level.

**Recommendation:** Provide explicit pattern behavior with a software equivalent; do not assume a host sampler supplies consistent semantics.

**Requirements:** pattern coordinate calculation; sampler/backend mapping; tile bounds.

**Completion criterion:** The same repeated image fills fractional-size regions consistently on software and accelerated backends, including negative offsets.

**Source paths:** [src/widgets/image.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/image.zig), [src/render/shaders/quad.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl), [src/render/sw/sw.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/sw/sw.zig), [src/render/wgpu/wgpu.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/wgpu/wgpu.zig).

**Primary references:** [R049](references.md#r049), [R004](references.md#r004).

<a id="visual-nine-slice"></a>
### Nine-slice image skins

**ID:** `visual.nine_slice` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** paint

**Options:** independent source/destination cuts; stretch; repeat; round; space; optional center; subpixel/large cuts.

**Current source:** features.nineSlice exists with stretched edges/center and destination cuts packed into 8-bit whole pixels.

**Recommendation:** Preserve the compact stretched representation; richer cuts and tiling should use optional data rather than widening every quad.

**Requirements:** typed cuts; border-image layout; composed decoration support.

**Completion criterion:** Corners retain intended dimensions under extreme aspect ratios, and large/subpixel cuts are not silently truncated.

**Source paths:** [src/draw/features.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/features.zig), [src/render/shaders/quad.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl), [src/render/sw/sw.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/sw/sw.zig).

**Primary references:** [R014](references.md#r014).

<a id="visual-image-sampling"></a>
### Explicit texture sampling quality

**ID:** `visual.image_sampling` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** paint

**Options:** nearest; linear; mipmap selection; address mode; pixel-art policy; filter-quality tier.

**Current source:** Stock shaders use nearest-texel conventions and software uses nearest/clamped sampling; mipmap generation alone does not establish sampled output.

**Recommendation:** Expose sampler behavior explicitly and preserve nearest for pixel-oriented callers.

**Requirements:** sampler descriptor or explicit draw option; software implementations; atlas padding rules.

**Completion criterion:** Upscaling and minification use the selected filter on each backend without atlas seams or implicit fallback changes.

**Source paths:** [src/render/shaders/quad.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl), [src/render/sw/sw.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/sw/sw.zig), [src/render/wgpu/wgpu.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/wgpu/wgpu.zig), [src/assets/image_mipmaps.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/assets/image_mipmaps.zig), [src/assets/image_atlas.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/assets/image_atlas.zig).

**Primary references:** [R004](references.md#r004).

<a id="visual-image-resolution"></a>
### Image resolution and device-scale selection

**ID:** `visual.image_resolution` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** resolve

**Options:** logical pixels per image pixel; device-scale asset variants; mipmap chain; decode-size hint; source-size metadata.

**Current source:** Image atlas and mipmap generation modules exist; no shared declarative image-density/variant contract was established by the audit.

**Recommendation:** Keep loading owned by the application and offer optional resolution helpers that do not start hidden IO.

**Requirements:** pure asset selection helpers; intrinsic size metadata; caller-controlled loading.

**Completion criterion:** Switching display scale selects an appropriate resource while preserving logical size and the caller-controlled loading lifecycle.

**Source paths:** [src/widgets/image.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/image.zig), [src/assets/image_atlas.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/assets/image_atlas.zig), [src/assets/image_mipmaps.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/assets/image_mipmaps.zig).

**Primary references:** [R059](references.md#r059), [R004](references.md#r004).


## Shadows

<a id="visual-box-shadows"></a>
### Composable outer box shadows

**ID:** `visual.box_shadows` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** paint

**Options:** offset x/y; sigma or blur convention; spread; color/alpha; multiple ordered shadows; shape-aware corners.

**Current source:** features.shadow is an analytic rounded-box Gaussian primitive, grown by three sigma; offset/spread are currently authored through a separate node.

**Recommendation:** Provide an optional shadow helper/list that emits existing optimized primitives with explicit ordering.

**Requirements:** plain shadow list; shared shape and paint bounds; preserved analytic fast path.

**Completion criterion:** Changing spread, offset or blur repaints the full old/new extent and multiple shadows retain their declared order.

**Source paths:** [src/draw/features.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/features.zig), [src/render/shaders/quad.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl), [src/render/sw/sw.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/sw/sw.zig), [src/draw/damage.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/damage.zig).

**Primary references:** [R049](references.md#r049).

<a id="visual-inset-shadows"></a>
### Inset box shadows

**ID:** `visual.inset_shadows` · **Baseline:** `not_found` · **Action:** `add` · **Phase:** P2 · **Primary cost:** paint

**Options:** inner offset; blur; positive/negative spread; color/alpha; multiple inset shadows.

**Current source:** The existing analytic shadow helper documents an outer blurred box; no built-in inset shadow contract was found.

**Recommendation:** Implement inset shadows as an optional decoration using the shared shape machinery, with clear spread direction.

**Requirements:** inner shape geometry; clip-aware paint; software/GPU lowering.

**Completion criterion:** Inset shadow coverage stays inside the chosen shape and handles negative spread and thick borders without seams.

**Source paths:** [src/draw/features.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/features.zig), [src/render/shaders/quad.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl), [src/render/sw/sw.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/sw/sw.zig).

**Primary references:** [R049](references.md#r049).

<a id="visual-content-shadows"></a>
### Drop shadows from rendered content alpha

**ID:** `visual.content_shadows` · **Baseline:** `not_found` · **Action:** `optional` · **Phase:** P4 · **Primary cost:** surface

**Options:** arbitrary image silhouette; text/icon silhouette; offset; blur; color; subtree source.

**Current source:** Box shadows exist, but no generic retained content-alpha filter/layer command was found.

**Recommendation:** Keep content shadows distinct from box shadows and request offscreen resources explicitly when needed.

**Requirements:** content source capture or equivalent fast path; surface budget; filter bounds.

**Completion criterion:** A transparent icon casts its silhouette rather than its rectangular bounds, and source changes invalidate the shadow.

**Source paths:** [src/draw/draw_list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig), [src/render/iface.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/iface.zig), [src/draw/features.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/features.zig).

**Primary references:** [R077](references.md#r077).


## Vector drawing

<a id="visual-path-geometry"></a>
### Reusable path geometry

**ID:** `visual.path_geometry` · **Baseline:** `low_level` · **Action:** `integrate` · **Phase:** P3 · **Primary cost:** paint

**Options:** move; line; quadratic; cubic; close; elliptical arcs; compound paths.

**Current source:** paths.Path provides move/line/quad/cubic/close, flattening and atlas emission; TinyVG decoding can supply arcs.

**Recommendation:** Expose ergonomic plain-data paths and arc helpers without requiring callers to adopt a scene or resource manager.

**Requirements:** existing path builder; caller-owned geometry; optional flatten/cache adapters.

**Completion criterion:** The same geometry can be filled, stroked and reused at multiple scales with a documented accuracy/capacity policy.

**Source paths:** [src/draw/paths.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paths.zig), [src/draw/tinyvg.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/tinyvg.zig).

**Primary references:** [R043](references.md#r043).

<a id="visual-vector-fills"></a>
### Path fill rules and brushes

**ID:** `visual.vector_fills` · **Baseline:** `low_level` · **Action:** `extend` · **Phase:** P3 · **Primary cost:** paint

**Options:** nonzero; even-odd; solid paint; gradient paint; image pattern; fill alpha.

**Current source:** Path fill rules and coverage-atlas emission exist; rich brush integration is not a general normal-style path.

**Recommendation:** Reuse path coverage with independent brushes so a color change need not rebuild geometry.

**Requirements:** coverage geometry; shared brush evaluation; paint/cache-key separation.

**Completion criterion:** Compound paths obey both fill rules, and changing paint preserves geometry while updating the correct pixels.

**Source paths:** [src/draw/paths.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paths.zig), [src/draw/features.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/features.zig), [src/assets/image_atlas.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/assets/image_atlas.zig).

**Primary references:** [R042](references.md#r042).

<a id="visual-vector-strokes"></a>
### Stroke width, joins and caps

**ID:** `visual.vector_strokes` · **Baseline:** `low_level` · **Action:** `integrate` · **Phase:** P3 · **Primary cost:** paint

**Options:** width; butt/round/square cap; miter/bevel/round join; miter limit; stroke brush; stroke alpha.

**Current source:** paths strokes already support width, join and cap families; the normal styling interface does not expose a unified stroke brush.

**Recommendation:** Retain the existing stroke engine and expose composable stroke values.

**Requirements:** existing stroke expansion; shared brush contract; correct stroke bounds.

**Completion criterion:** Acute joins, zero-length segments and open caps produce bounded, correctly clipped output with the selected brush.

**Source paths:** [src/draw/paths.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paths.zig).

**Primary references:** [R042](references.md#r042).

<a id="visual-vector-dashes"></a>
### Dashed paths and dash phase

**ID:** `visual.vector_dashes` · **Baseline:** `not_found` · **Action:** `add` · **Phase:** P3 · **Primary cost:** paint

**Options:** dash array; dash offset; continuous phase; closed path seam; round/square dash caps.

**Current source:** Dashed/dotted rectangular border features exist, but general path dash arrays/offsets were not found in the path API.

**Recommendation:** Extend the existing path engine; keep path dashing distinct from the current side-based border pattern.

**Requirements:** path distance calculation; stroke segmentation; defined degenerate-pattern policy.

**Completion criterion:** A dashed curved path maintains its phase through segment joins and closed seams, including zero entries under the documented policy.

**Source paths:** [src/draw/paths.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paths.zig), [src/draw/features.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/features.zig).

**Primary references:** [R042](references.md#r042).

<a id="visual-vector-markers"></a>
### Path markers and arrowheads

**ID:** `visual.vector_markers` · **Baseline:** `application_authored` · **Action:** `add` · **Phase:** P3 · **Primary cost:** paint

**Options:** start marker; midpoint marker; end marker; automatic tangent orientation; stroke-relative size.

**Current source:** Applications can draw custom path geometry, but no built-in marker/arrowhead attachment contract was found.

**Recommendation:** Offer pure marker placement helpers useful for technical diagrams, with caller-provided geometry.

**Requirements:** path tangent/direction helpers; reusable marker geometry; paint ordering.

**Completion criterion:** Markers orient consistently at reversed/degenerate segments and scale according to their chosen units.

**Source paths:** [src/draw/paths.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paths.zig), [docs/guide/custom.md](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/docs/guide/custom.md).

**Primary references:** [R042](references.md#r042).

<a id="visual-non-scaling-strokes"></a>
### Non-scaling strokes and pixel-sized markers

**ID:** `visual.non_scaling_strokes` · **Baseline:** `not_found` · **Action:** `add` · **Phase:** P3 · **Primary cost:** paint

**Options:** scale with geometry; fixed device-space width; logical-space width; marker scaling policy.

**Current source:** No general non-scaling stroke contract was found in existing path rasterization and paint transforms.

**Recommendation:** Add an explicit stroke-space choice for zoomable engineering canvases.

**Requirements:** stroke-space selection; transform-aware tessellation/rasterization; cache invalidation.

**Completion criterion:** Zooming a drawing changes geometry size while the selected fixed-width strokes and markers retain the specified screen width.

**Source paths:** [src/draw/paths.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paths.zig), [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/draw/inherit.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/inherit.zig).

**Primary references:** [R042](references.md#r042).

<a id="visual-vector-import"></a>
### Vector asset import and fidelity

**ID:** `visual.vector_import` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P3 · **Primary cost:** tooling

**Options:** existing TinyVG; explicit supported SVG subset; path assets; gradients; variable-width strokes; text handling policy.

**Current source:** TinyVG is implemented but flattens gradients to their first color, ignores within-path variable width and skips text hints; full SVG import is absent.

**Recommendation:** Extend the existing decoder and document an SVG subset separately; importers should feed plain drawing data.

**Requirements:** optional import module; capability/fidelity diagnostics; reusable parsed geometry.

**Completion criterion:** Unsupported asset features are reported rather than silently represented as full fidelity, and supported features match reference fixtures.

**Source paths:** [src/draw/tinyvg.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/tinyvg.zig), [src/draw/paths.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paths.zig).

**Primary references:** [R043](references.md#r043), [R042](references.md#r042).


## Custom rendering

<a id="visual-custom-materials"></a>
### Existing custom shader materials

**ID:** `visual.custom_materials` · **Baseline:** `low_level` · **Action:** `extend` · **Phase:** P1 · **Primary cost:** paint

**Options:** Style.material; Style.params; host-registered WGSL; explicit backend restriction; software equivalent or fallback.

**Current source:** Custom material handles and WGSL registration exist; ordinary Style carries them, but arbitrary GPU code has no automatic software equivalent and ES2 ignores materials.

**Recommendation:** Preserve this real escape hatch and caller-controlled registration; improve diagnostics and portable fallback declarations.

**Requirements:** existing host registration; capability reporting; caller-supplied software equivalent when needed.

**Completion criterion:** A custom material retains its render-loop ownership and receives a clear supported/fallback result on every selected backend.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/render/shaders/material.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/material.wgsl), [src/render/wgpu/wgpu.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/wgpu/wgpu.zig), [docs/guide/custom.md](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/docs/guide/custom.md), [src/render/gles/es2.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/gles/es2.zig).

**Primary references:** [R016](references.md#r016).

<a id="visual-custom-draw"></a>
### Existing inline custom drawing and host interleaving

**ID:** `visual.custom_draw` · **Baseline:** `low_level` · **Action:** `extend` · **Phase:** P0 · **Primary cost:** paint

**Options:** underlay; overlay; inline custom command; host command loop; caller data; explicit bounds/clip/transform contract.

**Current source:** Custom commands and drawUntilCustom let the application interleave drawing; current payloads expose rect/clip without shared opacity or transform.

**Recommendation:** Keep the imperative command loop and raw drawing access; pass missing geometry information as data rather than introducing callbacks.

**Requirements:** preserved host loop; explicit per-command geometry metadata; safe state restoration.

**Completion criterion:** Custom drawing interleaves in the same order as before and can honor transforms, clips and opacity using explicit data without hidden pass ownership.

**Source paths:** [src/core/customs.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/customs.zig), [src/draw/draw_list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig), [src/render/iface.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/iface.zig), [docs/guide/custom.md](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/docs/guide/custom.md).

**Primary references:** [R019](references.md#r019).

<a id="visual-render-target-interop"></a>
### Existing texture-in and render-to-texture routes

**ID:** `visual.render_target_interop` · **Baseline:** `low_level` · **Action:** `retain` · **Phase:** P1 · **Primary cost:** surface

**Options:** host texture input; UI rendered to host target; UV subregion; host sampler; explicit pass boundaries.

**Current source:** The custom-rendering guide documents texture input/output with host-owned device, queue, pass and targets; textured quads can be transformed.

**Recommendation:** Retain these raw interop operations and build optional effects from them without replacing the host render loop.

**Requirements:** preserved texture handles; explicit resource lifetime; shared format/alpha metadata.

**Completion criterion:** A host-produced texture and a UI-produced texture compose with ordinary draws under explicit lifetime, alpha and pass-order contracts.

**Source paths:** [docs/guide/custom.md](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/docs/guide/custom.md), [src/render/wgpu/wgpu.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/wgpu/wgpu.zig), [src/render/iface.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/iface.zig), [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig).

**Primary references:** [R017](references.md#r017).


## Clipping and masks

<a id="visual-rectangular-clip"></a>
### Rectangular clip fast path

**ID:** `visual.rectangular_clip` · **Baseline:** `integrated` · **Action:** `retain` · **Phase:** P0 · **Primary cost:** paint

**Options:** nested intersection; empty clip; fractional bounds; scroll clipping; shared text/custom behavior.

**Current source:** Axis-aligned inherited rectangular clipping is present in layout and draw payloads.

**Recommendation:** Preserve the direct rectangular fast path within the broader clip model.

**Requirements:** shared intersection semantics; backend scissor mapping.

**Completion criterion:** Nested, empty and fractional rectangular clips remain correct across background, text and custom draw commands.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/layout/layout.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/layout.zig), [src/draw/paint.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paint.zig), [src/draw/draw_list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig).

**Primary references:** [R062](references.md#r062).

<a id="visual-rounded-clip"></a>
### Exact nested rounded clipping

**ID:** `visual.rounded_clip` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** paint

**Options:** independent corner radii; multiple rounded ancestors; text clipping; image clipping; anti-aliased edges.

**Current source:** Quad carries one rounded clip tuple; nested clips collapse to one rect/radii pair and text/custom output lacks rounded geometry.

**Recommendation:** Fix composition and propagation while retaining a single-rounded-clip specialization.

**Requirements:** shared clip records; exact intersection lowering; shape reuse.

**Completion criterion:** Two offset rounded ancestors clip all descendant draw kinds to their true intersection without corner leaks.

**Source paths:** [src/draw/inherit.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/inherit.zig), [src/draw/draw_list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig), [src/draw/paint.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paint.zig), [src/render/shaders/quad.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl).

**Primary references:** [R062](references.md#r062), [R003](references.md#r003).

<a id="visual-path-clip"></a>
### Clipping to arbitrary geometry

**ID:** `visual.path_clip` · **Baseline:** `not_found` · **Action:** `add` · **Phase:** P3 · **Primary cost:** paint

**Options:** ellipse; polygon; path; fill rule; nested intersection; defined hit-test relationship.

**Current source:** Path drawing exists, but the general clip pipeline is rectangular plus limited rounded data rather than a path clip contract.

**Recommendation:** Reuse existing path geometry; expose clipping independently from painting and from optional hit shapes.

**Requirements:** existing path coverage; clip record references; backend stencil/mask lowering or software equivalent.

**Completion criterion:** A clipped-out region does not paint and follows the documented pointer policy, including nested path/rect clips.

**Source paths:** [src/draw/paths.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paths.zig), [src/draw/draw_list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig), [src/draw/inherit.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/inherit.zig).

**Primary references:** [R062](references.md#r062).

<a id="visual-image-masks"></a>
### Alpha and luminance masks

**ID:** `visual.image_masks` · **Baseline:** `not_found` · **Action:** `optional` · **Phase:** P4 · **Primary cost:** surface

**Options:** image mask; gradient mask; path-derived coverage; alpha mode; luminance mode; inversion.

**Current source:** No generic mask/layer command is present in the audited quads/text/custom command kinds.

**Recommendation:** Add masks as an optional compositing operation with caller-controlled inputs and temporary storage.

**Requirements:** explicit source and mask inputs; surface/composite support; mask bounds and resource lifetime.

**Completion criterion:** Alpha and luminance modes produce intentionally different results for colored masks and apply once to the intended group.

**Source paths:** [src/draw/draw_list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig), [src/render/iface.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/iface.zig), [src/draw/paths.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paths.zig).

**Primary references:** [R062](references.md#r062).

<a id="visual-mask-layers"></a>
### Mask placement and combination

**ID:** `visual.mask_layers` · **Baseline:** `not_found` · **Action:** `optional` · **Phase:** P4 · **Primary cost:** surface

**Options:** mask position/size; repeat; multiple layers; add/subtract/intersect/exclude; optional nine-slice mask border.

**Current source:** No built-in mask stack or mask-border contract was found.

**Recommendation:** Use plain mask-layer spans and explicit operators; keep unused mask features outside small-target builds.

**Requirements:** basic mask support; ordered mask operators; bounded temporary surfaces.

**Completion criterion:** Layer combinations obey order and coordinate spaces and fail predictably when the supplied capacity is exceeded.

**Source paths:** [src/draw/draw_list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig), [src/render/iface.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/iface.zig).

**Primary references:** [R062](references.md#r062).


## Transforms

<a id="visual-affine-transform"></a>
### Complete 2D affine transform styling

**ID:** `visual.affine_transform` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P2 · **Primary cost:** paint

**Options:** translation; rotation; scale; skew; matrix; transform origin; reference box.

**Current source:** Style.transform provides inherited center-based affine quad transforms, but text, clips, hit testing and pure comptime painting are limited.

**Recommendation:** Retain plain affine matrices and add origin/reference-box helpers plus coherent subtree behavior.

**Requirements:** P0 coordinate-space contract; origin resolution; runtime/comptime integration.

**Completion criterion:** Rotated/scaled/skewed controls keep label, decoration, clip and input geometry aligned without silently changing surrounding layout.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/draw/inherit.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/inherit.zig), [src/draw/paint.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paint.zig), [src/comptime/paint.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/comptime/paint.zig).

**Primary references:** [R071](references.md#r071).

<a id="visual-perspective-3d"></a>
### Optional perspective and 3D composition

**ID:** `visual.perspective_3d` · **Baseline:** `not_found` · **Action:** `optional` · **Phase:** P5 · **Primary cost:** surface

**Options:** 4x4 matrix; axis rotation; perspective; perspective origin; backface policy; flatten/preserve-3D.

**Current source:** The built-in transform is affine 2D; custom host rendering can supply independent 3D content but is not a built-in subtree transform.

**Recommendation:** Add a separate optional capability only after 2D semantics are sound; preserve host-rendered 3D as an existing route.

**Requirements:** 3D compositor profile; depth/order semantics; projective clipping and inverse input mapping.

**Completion criterion:** Perspective descendants have defined occlusion, clipping, backface and input behavior without corrupting surrounding 2D ordering.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/draw/draw_list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig), [docs/guide/custom.md](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/docs/guide/custom.md).

**Primary references:** [R072](references.md#r072).


## Opacity and compositing

<a id="visual-primitive-opacity"></a>
### Existing inherited per-primitive opacity

**ID:** `visual.primitive_opacity` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P0 · **Primary cost:** paint

**Options:** local alpha multiplier; ancestor alpha multiplication; quad alpha; text alpha; explicit custom-content data.

**Current source:** Style.opacity multiplies ancestor values onto each quad and text run; custom commands do not carry that opacity.

**Recommendation:** Keep the existing cheap behavior named and documented; do not silently redefine it as group opacity.

**Requirements:** preserved cheap alpha semantics; custom-content propagation; explicit distinction from group opacity.

**Completion criterion:** Existing alpha composition stays stable, while custom content receives enough information to honor the same intended primitive alpha.

**Source paths:** [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig), [src/draw/inherit.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/inherit.zig), [src/draw/paint.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paint.zig), [src/draw/draw_list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig).

**Primary references:** [R044](references.md#r044), [R017](references.md#r017).

<a id="visual-group-opacity"></a>
### Exact opacity of a completed subtree

**ID:** `visual.group_opacity` · **Baseline:** `not_found` · **Action:** `optional` · **Phase:** P4 · **Primary cost:** surface

**Options:** flatten then fade; nested groups; nonoverlap fast path; all participating draw kinds.

**Current source:** Inherited primitive alpha exists, but DrawList has no retained offscreen group/layer command.

**Recommendation:** Add group opacity separately, with explicit resource costs and optimization only when pixel-equivalent.

**Requirements:** explicit group boundaries; caller-provided/approved temporary surfaces; equivalence-checked fast paths.

**Completion criterion:** Two overlapping opaque children faded as one group match flatten-then-fade output, including nested opacity and text.

**Source paths:** [src/draw/draw_list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig), [src/render/iface.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/iface.zig), [src/draw/inherit.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/inherit.zig).

**Primary references:** [R017](references.md#r017), [R044](references.md#r044).

<a id="visual-surface-layers"></a>
### Explicit offscreen layer operations

**ID:** `visual.surface_layers` · **Baseline:** `application_authored` · **Action:** `add` · **Phase:** P4 · **Primary cost:** surface

**Options:** begin/end group; surface bounds; format; reuse policy; temporary storage budget; surface lifetime.

**Current source:** Applications already own passes and can render UI into a texture; there is no generic retained layer/filter command in the built-in list.

**Recommendation:** Expose operations and requirements to the host; an optional pool may be provided without taking over pass ownership.

**Requirements:** explicit command/graph extension; host-controlled surface acquisition; bounded lifetime/accounting.

**Completion criterion:** A layer reports its required bounds/format/storage and can execute using caller-managed resources, with deterministic capacity failure.

**Source paths:** [src/render/iface.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/iface.zig), [src/draw/draw_list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig), [src/render/wgpu/wgpu.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/wgpu/wgpu.zig), [docs/guide/custom.md](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/docs/guide/custom.md).

**Primary references:** [R021](references.md#r021), [R017](references.md#r017).

<a id="visual-stacking-isolation"></a>
### Local stacking and isolated groups

**ID:** `visual.stacking_isolation` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P4 · **Primary cost:** paint

**Options:** existing global layers; sibling paint order; nested local stacking; isolation boundary; consistent hit order.

**Current source:** overlay.Layers uses 256 global numeric levels inheriting parent maximum; layered paint/hit helpers exist but do not implement isolated nested stacking contexts.

**Recommendation:** Retain global layers and add local isolation only where requested; avoid a mandatory DOM-like stacking model.

**Requirements:** ordered group representation; layer/hit integration; explicit isolation.

**Completion criterion:** A nested isolated group cannot accidentally interleave its children with outside content, and the visible top target wins hit testing.

**Source paths:** [src/layout/overlay.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/overlay.zig), [src/draw/paint.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paint.zig), [src/interact/hit.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/interact/hit.zig), [src/draw/order.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/order.zig).

**Primary references:** [R044](references.md#r044), [R019](references.md#r019).

<a id="visual-blend-modes"></a>
### Artistic blend modes

**ID:** `visual.blend_modes` · **Baseline:** `not_found` · **Action:** `optional` · **Phase:** P4 · **Primary cost:** surface

**Options:** multiply/screen/overlay; darken/lighten; dodge/burn; hard/soft light; difference/exclusion; hue/saturation/color/luminosity.

**Current source:** Stock source-over blending exists; no general built-in artistic blend-mode field/group contract was found.

**Recommendation:** Separate artistic blending from alpha compositing and expose background-layer versus group scope.

**Requirements:** blend implementation; source/backdrop bounds; isolation semantics; software equivalents or explicit restriction.

**Completion criterion:** Reference source/backdrop colors match each mode, including transparent inputs and isolation boundaries.

**Source paths:** [src/draw/draw_list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig), [src/render/iface.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/iface.zig), [src/render/shaders/quad.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl), [src/render/sw/sw.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/sw/sw.zig).

**Primary references:** [R044](references.md#r044).

<a id="visual-compositing-operators"></a>
### Porter-Duff and related compositing operators

**ID:** `visual.compositing_operators` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P4 · **Primary cost:** surface

**Options:** source-over; clear; source/destination; in/out/atop; xor; additive.

**Current source:** Normal stock rendering provides over blending; other general compositing operators are not exposed as portable draw operations.

**Recommendation:** Keep source-over as the ordinary fast path and add explicit advanced operators for canvas/effect use.

**Requirements:** operator lowering; alpha format contract; bounded destination access.

**Completion criterion:** Operator fixtures agree with defined premultiplied-alpha equations and do not modify pixels outside the intended bounds.

**Source paths:** [src/render/iface.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/iface.zig), [src/draw/draw_list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig), [src/render/shaders/quad.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl), [src/render/sw/sw.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/sw/sw.zig).

**Primary references:** [R044](references.md#r044).


## Filters

<a id="visual-color-filters"></a>
### Foreground color filters

**ID:** `visual.color_filters` · **Baseline:** `application_authored` · **Action:** `add` · **Phase:** P4 · **Primary cost:** paint

**Options:** brightness; contrast; saturation/grayscale; hue rotation; invert/sepia; color matrix; ordered chain.

**Current source:** Custom GPU materials can implement color operations, but no portable built-in filter-chain contract is present.

**Recommendation:** Offer pure color-operation descriptions and fuse compatible operations without promising arbitrary chains fit one pass.

**Requirements:** plain filter operations; compatible-operation fusion; software path; defined working color space.

**Completion criterion:** Operation order is preserved, neutral filters leave output unchanged, and fused output matches the unfused reference.

**Source paths:** [src/render/shaders/material.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/material.wgsl), [src/draw/draw_list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig), [src/render/shaders/quad.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl), [src/render/sw/sw.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/sw/sw.zig).

**Primary references:** [R077](references.md#r077), [R016](references.md#r016).

<a id="visual-foreground-blur"></a>
### General foreground blur

**ID:** `visual.foreground_blur` · **Baseline:** `not_found` · **Action:** `optional` · **Phase:** P4 · **Primary cost:** surface

**Options:** Gaussian sigma x/y; filter bounds; edge mode; quality/resolution; source image or subtree.

**Current source:** An analytic blurred box-shadow primitive exists; it is not a general image/subtree blur operation.

**Recommendation:** Add general blur separately from the optimized box shadow, with explicit area and resource cost.

**Requirements:** explicit source surface; separable filter or equivalent; temporary memory budget; expanded damage.

**Completion criterion:** Blurred content has correct edge behavior and extent; changing sigma or source pixels invalidates all affected output.

**Source paths:** [src/draw/features.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/features.zig), [src/draw/draw_list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig), [src/render/iface.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/iface.zig).

**Primary references:** [R077](references.md#r077), [R016](references.md#r016).

<a id="visual-backdrop-filters"></a>
### Bounded backdrop filtering

**ID:** `visual.backdrop_filters` · **Baseline:** `not_found` · **Action:** `optional` · **Phase:** P4 · **Primary cost:** surface

**Options:** backdrop source boundary; blur; tint/saturation; rounded destination clip; sampling extent; explicit fallback.

**Current source:** No retained backdrop-read/filter command or backdrop dependency tracking was found.

**Recommendation:** Document chosen native semantics because backdrop-root standardization remains unsettled; never infer freshness from the panel style alone.

**Requirements:** surface/layer support; source dependency tracking; isolation semantics; backend capability.

**Completion criterion:** Moving content behind an unchanged panel refreshes the correct blur, including nesting, clipping and explicit unsupported-backend fallback.

**Source paths:** [src/draw/draw_list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig), [src/render/iface.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/iface.zig), [src/draw/damage.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/damage.zig), [src/draw/order.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/order.zig).

**Primary references:** [R026](references.md#r026), [R006](references.md#r006), [R023](references.md#r023).

<a id="visual-specialist-filters"></a>
### Optional filter graph extensions

**ID:** `visual.specialist_filters` · **Baseline:** `application_authored` · **Action:** `optional` · **Phase:** P5 · **Primary cost:** surface

**Options:** convolution; morphology; displacement; turbulence/noise; lighting; channel transfer; multiple graph inputs.

**Current source:** Custom materials and host rendering are existing escape hatches; no portable built-in graph of these filter operations was found.

**Recommendation:** Use optional extensions or host-authored operations; do not add a core widget field for every specialist effect.

**Requirements:** optional graph representation; declared inputs/bounds; explicit execution and resource control.

**Completion criterion:** Each operation declares inputs, bounds and backend requirements, and unsupported nodes fail or use a caller-selected fallback predictably.

**Source paths:** [src/render/shaders/material.wgsl](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/material.wgsl), [docs/guide/custom.md](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/docs/guide/custom.md), [src/render/iface.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/iface.zig), [src/draw/draw_list.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig).

**Primary references:** [R077](references.md#r077).


## Motion and animation

<a id="visual-property-tweens"></a>
### Existing property tweening with semantic invalidation

**ID:** `visual.property_tweens` · **Baseline:** `integrated` · **Action:** `extend` · **Phase:** P3 · **Primary cost:** resolve

**Options:** duration; target value; current-value retargeting; property selection; paint/layout/text invalidation class.

**Current source:** SIMD Tweens and Frame.transition exist; retargeting starts from the current value and reusing the same target preserves the current leg.

**Recommendation:** Keep raw scalar tween functions usable; optional property adapters may classify invalidation without hiding frame control.

**Requirements:** existing dense tween storage; optional property metadata; explicit changed-value outputs.

**Completion criterion:** Retargeting is continuous, and animating only a paint color does not force layout or text shaping.

**Source paths:** [src/anim/tweens.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/anim/tweens.zig), [src/runtime/frame.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/runtime/frame.zig).

**Primary references:** [R073](references.md#r073).

<a id="visual-easing"></a>
### Extended easing functions

**ID:** `visual.easing` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P3 · **Primary cost:** resolve

**Options:** existing six curves; cubic Bézier; steps; piecewise linear; custom sampled curve.

**Current source:** Tweens has six coefficient-table easing curves; general cubic-bezier/step/piecewise curves are not exposed.

**Recommendation:** Preserve the existing SIMD coefficient path and add opt-in curve kinds or compiled tables for richer easing.

**Requirements:** pure easing sampler; validation; optional coefficient/table compilation.

**Completion criterion:** Endpoint, step-boundary and out-of-range behavior is defined, and supplied curves do not change existing curve results.

**Source paths:** [src/anim/tweens.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/anim/tweens.zig), [src/anim/keyframes.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/anim/keyframes.zig).

**Primary references:** [R055](references.md#r055).

<a id="visual-springs"></a>
### Existing spring motion and control

**ID:** `visual.springs` · **Baseline:** `integrated` · **Action:** `extend` · **Phase:** P3 · **Primary cost:** resolve

**Options:** stiffness; damping; initial/current velocity; retargeting; rest threshold; reduced-motion landing.

**Current source:** Anims stores spring position, velocity, target, stiffness and damping in columns; Frame integrates reduced-motion landing.

**Recommendation:** Expose useful existing controls and document time-step/rest behavior without replacing the spring engine.

**Requirements:** preserved spring integrator; documented parameter/time units; explicit completion state.

**Completion criterion:** Springs settle deterministically under the documented time-step policy, retarget without unintended jumps, and stop requesting frames when at rest.

**Source paths:** [src/anim/anims.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/anim/anims.zig), [src/runtime/frame.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/runtime/frame.zig).

**Primary references:** [R027](references.md#r027).

<a id="visual-keyframes"></a>
### Extended keyframe playback

**ID:** `visual.keyframes` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P3 · **Primary cost:** resolve

**Options:** timed stops; per-segment easing; repeat count; direction; delay; fill mode; pause/seek.

**Current source:** Scalar keyframe sampling and Frame.sequence already exist; general playback direction/repetition/fill controls are not a complete contract.

**Recommendation:** Keep sampling a pure function of caller time and add optional playback helpers around it.

**Requirements:** existing pure sampler; explicit playback clock/state; defined boundaries.

**Completion criterion:** Repeat boundaries, reverse/alternate direction, zero-duration segments and pause/resume produce deterministic sampled values.

**Source paths:** [src/anim/keyframes.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/anim/keyframes.zig), [src/runtime/frame.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/runtime/frame.zig), [src/anim/tweens.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/anim/tweens.zig).

**Primary references:** [R048](references.md#r048).

<a id="visual-color-motion"></a>
### Color transitions with explicit interpolation

**ID:** `visual.color_motion` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P3 · **Primary cost:** resolve

**Options:** legacy channel interpolation; perceptual interpolation; linear-light interpolation; alpha-aware blending; hue route.

**Current source:** Runtime color transitions are implemented, but selectable perceptual and premultiplied interpolation are not a shared public contract.

**Recommendation:** Extend the existing helper with an explicit interpolation choice and preserve legacy defaults.

**Requirements:** shared color interpolation functions; existing scalar animation helpers.

**Completion criterion:** Animated transparent colors avoid fringes and selected midpoint colors match the corresponding static gradient interpolation.

**Source paths:** [src/runtime/frame.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/runtime/frame.zig), [src/anim/tweens.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/anim/tweens.zig), [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig).

**Primary references:** [R052](references.md#r052), [R073](references.md#r073).

<a id="visual-layout-motion"></a>
### Layout transition and FLIP expansion

**ID:** `visual.layout_motion` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P3 · **Primary cost:** layout

**Options:** existing position springs; optional size transition; stable identity; interrupted layout motion; nested transitions.

**Current source:** FLIP moves registered subtree positions before finalize so clips/hits follow displayed positions; size changes are explicitly not animated.

**Recommendation:** Keep position FLIP and its explicit pass; add size behavior only after deciding whether content relayouts or is visually scaled.

**Requirements:** existing FLIP pass; size-versus-scale policy; shared geometry/hit semantics.

**Completion criterion:** Nested interrupted transitions retain correct displayed positions, and any size animation has documented text/layout and hit-target behavior.

**Source paths:** [src/anim/flip.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/anim/flip.zig), [src/runtime/frame.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/runtime/frame.zig), [src/layout/layout.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/layout.zig).

**Primary references:** [R071](references.md#r071), [R073](references.md#r073).

<a id="visual-motion-paths"></a>
### Motion along a path

**ID:** `visual.motion_paths` · **Baseline:** `not_found` · **Action:** `optional` · **Phase:** P3 · **Primary cost:** resolve

**Options:** path reference; distance; anchor; tangent orientation; rotation offset.

**Current source:** Path geometry and scalar animation exist, but no built-in path-following placement helper was found.

**Recommendation:** Provide a pure path-position sampler that callers can compose with existing animation and drawing.

**Requirements:** path-length/tangent helper; existing scalar samplers; transform composition.

**Completion criterion:** Distance-based motion and tangent rotation remain stable across segment joins and documented zero-length path cases.

**Source paths:** [src/draw/paths.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paths.zig), [src/anim/tweens.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/anim/tweens.zig), [src/core/types.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig).

**Primary references:** [R079](references.md#r079).

<a id="visual-geometry-morph"></a>
### Compatible path and shape morphing

**ID:** `visual.geometry_morph` · **Baseline:** `not_found` · **Action:** `optional` · **Phase:** P3 · **Primary cost:** paint

**Options:** matching path command interpolation; corner/radius interpolation; discrete fallback; explicit crossfade alternative.

**Current source:** Paths and scalar keyframes exist, but no general topology-aware path morph contract was found.

**Recommendation:** Start with matching topology and an explicit fallback; avoid silently inventing correspondence between unrelated shapes.

**Requirements:** compatible geometry validation; pure geometry interpolation; cache invalidation.

**Completion criterion:** Compatible paths interpolate without topology changes, while incompatible paths follow the documented discrete/crossfade choice.

**Source paths:** [src/draw/paths.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paths.zig), [src/anim/keyframes.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/anim/keyframes.zig).

**Primary references:** [R043](references.md#r043).

<a id="visual-reduced-motion"></a>
### Existing reduced-motion and idle behavior

**ID:** `visual.reduced_motion` · **Baseline:** `integrated` · **Action:** `retain` · **Phase:** P1 · **Primary cost:** resolve

**Options:** reduced-motion landing; no-motion end state; idle/wake integration.

**Current source:** Settings and runtime spring/tween/sequence/FLIP helpers already integrate reduced motion and frame wake behavior.

**Recommendation:** Retain existing accessibility behavior in every new motion helper and preserve caller control of the event loop.

**Requirements:** existing settings propagation; preserved explicit scheduling outputs.

**Completion criterion:** Enabling reduced motion during active motion lands at a valid end state and leaves no unnecessary continuous frame scheduling.

**Source paths:** [src/a11y/settings_data.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/a11y/settings_data.zig), [src/runtime/frame.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/runtime/frame.zig), [src/anim/anims.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/anim/anims.zig), [src/anim/tweens.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/anim/tweens.zig), [src/anim/flip.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/anim/flip.zig).

**Primary references:** [R028](references.md#r028).

<a id="visual-animation-lifecycle"></a>
### Explicit playback lifecycle and completion

**ID:** `visual.animation_lifecycle` · **Baseline:** `partial` · **Action:** `extend` · **Phase:** P3 · **Primary cost:** resolve

**Options:** delay; cancel; finish; pause/seek; interruption/reversal; completion state; hidden-subtree policy; capacity exhaustion.

**Current source:** Tweens retarget continuously and sweep unseen entries; current bounded slot behavior can reuse the last row when capacity is exceeded.

**Recommendation:** Expose lifecycle state as data rather than requiring callbacks, and make capacity policy visible to callers.

**Requirements:** explicit return states; caller time and buffers; capacity diagnostics; optional lifecycle helper.

**Completion criterion:** Cancellation, hiding and capacity exhaustion do not silently animate an unrelated control, and completion can be consumed without hidden event dispatch.

**Source paths:** [src/anim/tweens.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/anim/tweens.zig), [src/anim/anims.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/anim/anims.zig), [src/runtime/frame.zig](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/runtime/frame.zig).

**Primary references:** [R073](references.md#r073), [R048](references.md#r048).
