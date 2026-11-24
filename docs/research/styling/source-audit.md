# LCGF styling source audit

Research date: **2026-11-23**. Audited source: `OmarSiwy/LCGF`, commit **`ed94db3da27882ef1c87d0dd15a382b4df39e2c2`**, verified as remote `main` for this research.

This report is based on **code inspection, not executed tests**. No production source was edited and no build or runtime test was run for this audit. Implementation statements describe the inspected contracts. Correctness-risk findings require focused reproductions before claiming a demonstrated failure, a fix, or a measured regression. An absence statement means the capability was not found in the inspected built-in path; custom host code may provide additional behavior.

## Executive finding

LCGF already has substantially more styling infrastructure than `Style` alone suggests. The broadest addition opportunity is **coherent feature composition and tested convenience paths**, followed by correctness for transformed/effect-bearing subtrees. The existing independently callable passes and caller-owned side tables already provide valuable granularity; their availability is a strength, not an intrinsic API defect. Do not rebuild its existing gradients, paths, shadows, flex extensions, RTL helpers, paragraph layout, token system, accessibility settings, or animations from zero.

Several research/planning documents are stale. In particular, `docs/plans/markup.md` says margins, gradients, shadows and z-index are absent; the current source contains corresponding features in `layout/flex.zig`, `draw/features.zig` and `layout/overlay.zig`. `draw/tinyvg.zig` still says the quad material has no gradients even though `draw/features.zig` and the stock shader implement them. Source is the evidence used here.

## Classification

- **Integrated:** present on the usual `Style`, `TextStyle`, widget, or runtime frame path.
- **Low level:** exported, usable API exists, but the caller must supply side tables or sequence special passes.
- **Partial:** real support exists with a material semantic, composition, front-end, or backend limit.
- **Add:** no general built-in styling contract found in inspected source. Custom host rendering can often achieve the effect, but does not count as a built-in option.

## 1. Inventory of current support and the actual missing work

| Area | Existing implementation | Classification and additions needed |
|---|---|---|
| Colors | `types.Color`: packed RGBA8, `rgb`, `rgba`, `hex`, transparent/white/black. | Integrated. Add typed color-space-aware authoring/conversion where useful; explicitly define interpolation and blending spaces. A general HDR/wide-gamut paint contract was not found in the inspected built-in path. |
| Basic layout | `Style.dir`, `size` with fit/px/grow/pct, min/max, physical four-side padding, one gap, start/center/end main and cross alignment, shrink flag. | Integrated. Add convenience and semantics for separate row/column gaps, logical dimensions, responsive values, broader distribution modes. Do not call percentage or min/max sizing missing. |
| Floating and scrolling | `Style.float`, `offset`, `scroll`, `clip`; float is out of flow at parent content origin. | Integrated. General anchored/fixed/sticky positioning is not all represented by this one flag. |
| Advanced flex | `flex.Flex.Style`: aspect, weighted shrink, bounded two-pass regrow, self cross alignment, margins, wrapping rows, line alignment, baseline. | Low level and partial. Margins are non-collapsing; wrap only applies to rows; baseline only non-wrapping rows; regrow is bounded, not the full CSS freeze algorithm. No named `flex-basis` field. Offer tested optional build/finish conveniences while retaining the independently callable side-table and pass APIs. |
| Grid | `grid.Track.px`, `.fit`, `.fr`; row/column tracks and gaps; explicit cells, spans, sparse row-order auto-placement; per-axis stretch/start/center/end. | Low level and intentionally bounded. One sizing round; no implicit growth; overflow falls into the last cell and flags overflow. Add minmax/auto-fit/auto-fill, named lines/areas, dense flow, subgrid only behind an explicit richer layout profile. Do not claim CSS Grid conformance. |
| RTL layout | `rtl.Rtl`, inherited LTR/RTL sign, `startEnd` logical inline padding, `mirror`. | Low level. Broaden logical properties to margin/border/position/size/alignment and account for writing modes. Existing bidi text and x-axis mirroring are not a complete writing-mode system. |
| Stacks and layers | `overlay.zstack`; anchors/pivots, offsets, viewport flipping; `Layers` and stable counting-sort order; `paint.emitLayered`, `hit.atLayered`. | Low level. Layers are 256 global numeric levels inheriting parent maximum, not isolated nested CSS stacking contexts. Integrate paint and hit ordering consistently. |
| Fill and image | `Style.fill`, `texture`, `uv`, material handle and params; texture is multiplied by fill, with transparent fill converted to white tint for a nonwhite texture. | Integrated. Add clear separate background/image/tint semantics and layered paint stack; current transparent tint sentinel cannot express all intended choices without ambiguity. |
| Gradients | `features.linear(to, angle)` and `radial(to, centre, radius)`; first color is node fill, second is packed into params. | Partial. Two colors, one feature per quad. Add arbitrary stops, stop positions/hints, repeating, elliptical radial, conic, spread/tile modes, interpolation space. A gradient and patterned border cannot share the current feature selector. |
| Borders | One width, one color, uniform radius or four independent circular corner radii. `features.dashed` and `.dotted` exist. | Partial. Add per-side widths/colors/styles, proper continuous rounded path dash phase, double/groove/ridge/inset/outset if desired, explicit border painting position, elliptical corners and CSS-compatible radius normalization. |
| Outlines/focus rings | Theme state look uses border; `Focus.ring` exposes a rect; widgets/devtools can build an extra outline node. | Partial. Add explicit outline width/color/style/offset and shape following. Keep keyboard focus visibility separate from mere focus; avoid layout-changing focus borders. |
| Shadows | `features.shadow(sigma)` analytic rounded-box shadow, expanded by 3 sigma at rendering. Offset/spread are authored using a separate node's position and size; place before the visible box. | Partial. Add a true shadow list, offsets/spread, inset shadows, paint order and effect bounds. Existing single shadow primitive is real, but does not provide CSS box-shadow composition. |
| Nine-slice images | `features.nineSlice(dst,src)`: stretched edges and center; destination cuts packed in 8-bit whole pixels. | Partial. Add repeat/round/space modes, center enable, independently typed source pixels/normalized cuts, larger/subpixel cuts, and combination with other decoration. |
| Image fit | `widgets_image.Options.box`, `.fit` stretch/contain/cover, atlas images and UV cropping. | Integrated partial. Cover is centered; contain changes the node's actual size to the fitted image (`place` output becomes the node's pixel size). Add object-position/alignment, none/scale-down, independent content box and image bounds. |
| Image sampling | Stock shader uses nearest-texel conventions; software samples nearest with clamped coordinates. Image atlas padding and mipmap generation modules exist. | Partial. Add sampler/filter/address mode as an explicit style/resource contract; do not assume bilinear/mipmapped output from mere existence of mipmap generation. |
| Clipping | Axis-aligned inherited rect clip; quad also carries four rounded clip radii. | Partial. Multiple nested clips collapse to a rect plus one radii set; exact intersection of arbitrary rounded shapes is not preserved. Text/custom draw commands carry rect clips, without the quad's rounded clip data. Add clip stacks, geometry/path clip, masks and shared clip handles. |
| Opacity | `Style.opacity` multiplies ancestor values; quads get inherited opacity and text color alpha is faded. | Partial. This is per-primitive inherited alpha, not offscreen group opacity. Overlapping children therefore differ from a flattened group at opacity 0.5. Inline custom draws do not receive opacity in their command payload; a host can resolve it separately using the node index. Custom content rendered into a texture and displayed as an ordinary quad does receive quad opacity. |
| 2D transforms | `Style.transform` is affine a,b,c,d,tx,ty around node center, inherited through `Extra.world`, applied by quad renderer. | Partial. Explicitly paint-only; layout, clipping and hit testing do not see it. `TextRun` and inline `CustomDraw` have no transform field; the host may apply custom transforms itself or render custom content to a textured quad. Pure comptime `Paint` rejects nonidentity transforms. Add transform origin, shared visual/hit/clip semantics, text propagation and robust singular-matrix policy. |
| Paths | `paths.Path` move/line/quad/cubic/close; flatten; nonzero/even-odd fill; stroke width with miter/bevel/round joins and butt/square/round caps; coverage atlas emission. | Low level. Paths are rasterized/cached to atlas images. Add author-friendly vector assets, dashes/offsets and paint integration; don't build paths anew. Cache invalidation must include geometry, scale, stroke and paint. |
| TinyVG | Bounded decoder produces paths, with arcs and basic strokes. | Partial. Gradients are flattened to their first color; variable width inside a path is ignored, text hints skipped. Full SVG import was not found in the inspected built-in path; path support alone does not establish it. |
| Text face basics | `TextStyle` has px/color/font handle/wrap; OpenType loader supports TrueType outlines and TTC face selection; `opentype.Style` selects bold/italic bits. | Integrated basics plus low-level loader. Add family/fallback/style matching as a higher-level resource interface, named weights/stretch, variable axes and richer font formats as optional modules. Do not claim arbitrary OpenType fonts: `OTTO`/CFF is explicitly rejected by the current parser. |
| Shaping | Built-in shaper supports liga, kern, mark/mkmk; `shape.Features` toggles these. Optional HarfBuzz adapter fills the same run columns for complex scripts. | Low level. `TextStyle` does not expose feature tags/ranges/axes/script/language. HarfBuzz adapter guesses one run's properties and calls default features; bidi and script itemization must be composed correctly. Add a clear advanced text profile. |
| Paragraph layout | `text_lines`: Unicode line breaking, cluster-safe emergency wrapping, start/center/end factor, justify, max-line ellipsize, metrics and bidi reorder. | Low level. `text_stack.Stack.layoutAt` currently creates start-aligned layout; normal `Frame.end` uses `Mono`. Offer an optional paragraph-oriented convenience path over the existing algorithms, alongside the direct text protocol. |
| Rich text | `text_spans.Spans`: byte ranges with per-span font/size/color; per-span shaping and metrics. | Low level partial. Every authored span is shaped separately. If a caller splits a span only to change color, kerning/ligatures still cannot cross that boundary. Improve segmentation into shaping runs vs paint runs; add backgrounds, decorations, baseline shifts, inline objects, links and selectable styled runs. |
| Text fallback and Unicode | Unicode grapheme/word/line/script/bidi modules; font fallback Chain/Runs, OS discovery adapters. | Low level. Preserve grapheme/cluster integrity, shaping context and locale in styling. Built-in fallback resolves per character, which deserves care for joined emoji/variation selectors/complex sequences. |
| Typography extras | Paragraph metrics can be manually altered; widgets have textfields/textarea, caret, selection and IME plumbing. | Add a unified style contract for line-height, letter/word spacing, tabs, whitespace, line-break/word-break policies, hyphenation, decoration color/style/thickness/offset, text shadows, selection/caret/placeholder/IME part styling. |
| Themes/tokens | Six semantic color roles; five-step space/radius/text-size scales; light/dark; density; platform dark/accent helper; compile-time folded themes; per-widget override. | Integrated. Extend existing token system: on-colors, surfaces, status/success/error/warning/info, disabled/muted, border/focus/link, elevation, motion, typography, component parts. |
| Runtime theme switching | Runtime passes new Theme per build. `theme.recolor` remaps raw colors in an already-painted list for the compile-time path. | Partial. Recolor requires distinct source palette colors; it cannot preserve role identity if roles share a value, and intentionally equal literal colors are also remapped. Add typed token references/style IDs and generations rather than a growing raw-value remap. |
| Inheritance | `theme.Inherited` caller-owned color/px columns; zero means inherited; `endInherited` resolves before measurement. | Low level partial. Explicit zero/transparent cannot be distinguished from unset through this interface. Add presence bits/tagged values, inherit/default/unset semantics and chosen inheritable typography properties. |
| States and variants | `theme.States` has 8 combinations of hover/held/focused, each altering fill/border color/width; base widgets have 4-state face colors and on/off marks. Widgets have own variants and options. | Partial. Add consistent part/variant/state recipes including disabled, selected, checked, indeterminate, expanded, active, read-only, invalid, busy and focus-visible. Accessibility state fields already include several of these; connect styling without treating disabled color as disabled behavior. |
| Accessibility preferences | `Settings`: high contrast, text scale, reduced motion, always-show-focus. `a11y.settings` adjusts tokens; runtime springs/tweens/sequences/FLIP respect reduced motion. Contrast checks exist. | Integrated/low-level mix. Add high-contrast light palette/system colors, reduced transparency, forced-color-style policies, hit-target metrics and per-component preference overrides. Preserve existing reduced-motion behavior. |
| Motion | Springs; SIMD tweens; six easing curves; scalar keyframes; color transitions; layout-position FLIP; idle/wake integration. | Integrated for runtime helpers. Add delays, cubic-bezier/steps, playback direction/repetition/fill policy, property metadata, matrix decomposition, perceptual/premultiplied color interpolation and compositor-only updates. FLIP currently moves positions, not sizes. |
| Scrollbars | Scroll widget has vertical track/thumb and keyboard controls; width is a fixed `bar_px = 8`. Lower-level scroll helpers exist. | Partial. Add part styles, horizontal/both-axis bars, placement, overlay/reserved gutter, autohide, width/min-thumb, corner and state styles, overscroll/snap policy where required. |
| Responsive styling | Application can inspect viewport/platform/input and choose typed styles directly. | Add explicit shared breakpoint/container/environment conditions, dependency tracking and invalidation if declarative responsiveness is desired. Do not require CSS syntax for this. |
| Custom rendering | Material handles, custom commands, underlay/overlay, inline draws, render-to-texture route. | Real extension escape hatches. They are not a substitute for built-in portable semantics, capability reports or software fallbacks. |
| Filters/compositing | Stock over blending; no generic retained offscreen layer/filter command in `DrawList.Kind` (only quads/text/custom). | Add layer allocation/surface pooling first, then group opacity, blend modes, color matrix/filter chains, alpha masks, blur/backdrop blur, drop-shadow and isolation as optional render capabilities. |
| CSS-like stylesheet system | Docs contain markup/parser research and a future plan; main core is typed Zig data. | Add only as optional authoring/compiler layer. No need to impose selectors/cascade/string parsing on each frame or claim browser compatibility. |

## 2. Semantics and correctness risks to address

### A. Paint transform does not currently mean transform the entire widget

`Style.transform` documentation explicitly excludes layout, clipping and hit testing. The quad receives `Extra.world`, while text/custom output is written with untransformed layout rects. This means rotating a button's background does not automatically rotate its label and input geometry. A consistent contract should specify layout space, local paint space, world space, clip space and pointer inverse transforms. A separate paint-only transform mode may remain useful, but should be named and documented accordingly.

The pure comptime path rejects transforms because its paint templates are constant and a center-based transform depends on runtime geometry. A shared dynamic transform pass can preserve read-only style tables while updating the small geometry-dependent rows.

### B. Opacity needs two explicit meanings

Inherited alpha is cheap and appropriate for many effects. Group opacity requires first composing overlapping children, then applying alpha once. Keep both in the API with an explicit layer request, rather than silently replacing the fast behavior or pretending the results are equivalent. Group effects must also include text and custom content or state a supported boundary. The present inline custom-command payload has no alpha field, although its node index lets a host look up extra data. The render-to-texture route becomes an ordinary quad and therefore follows quad opacity.

### C. Paint bounds need one shared, conservative definition

`layout.finalize` computes visibility from untransformed rectangles. `Damage.frame` unions old/new `Tree.vis`. `damage.cull` and `order.mergeAcrossText` use `quad.rect ∩ clip`. None of those inspected bounding calculations account for transformed quad corners or the 3-sigma shadow expansion. Hashing includes transform/alpha, but noticing a changed value does not expand the region to its actual pixels.

This is a source-level correctness risk in existing transform/shadow combinations, not merely future filter work. Add shared conservative paint bounds and use them for initial visibility, dirty regions, effect invalidation, overlap-aware reordering and occlusion. Disable unsafe optimization for unknown custom/effect bounds until the host supplies bounds. Reproduce with an offscreen layout rect translated onscreen, a changed shadow sigma, and a transformed quad overlapping text whose layout rect does not overlap.

### D. Rounded clip semantics are incomplete across primitives and nesting

Quad clip data contains one rectangle and one corner-radius tuple. Inheritance substitutes the current clipping node's radii, while layout intersects axis-aligned rectangles. The exact intersection of arbitrary nested rounded shapes cannot generally be represented by the resulting rectangle plus only the innermost radii. This is a representational inference from the inspected code; the affected visual combinations still need screenshot reproductions. Text/custom commands lack even that tuple. Introduce clip records/stack references, and separate cheap rectangular/single-rounded fast paths from general intersection/mask paths.

### E. One feature enum prevents natural combinations

Stock features use a single `params.x` selector. A node cannot simultaneously select its gradient, nine-slice mapping and dashed border. Adding ever larger enum variants for every combination creates a combinatorial maintenance problem. Prefer separate semantic paint/background/border/effect records lowered to one or several bounded draw primitives. Preserve the old single-quad fast path for the common case.

### F. Add tested conveniences without hiding pass control

Margins, grid, RTL and paragraph alignment exist but are not fields in the ordinary `Style`/`TextStyle` nor selected by `Frame.end`. The caller can own extra buffers, sequence the relevant passes and call `Frame.finish`. That escape path is deliberate, useful granularity and should remain first-class. The opportunity is tested, documented convenience paths for common combinations so users need not rediscover valid pass ordering. These helpers should expand to a few explicit data operations, with direct access retained at every stage. Avoid both an obligatory all-features context and a proliferation of incompatible `endFoo` wrappers.

## 3. Backend and ABI concerns

- The fixed `Quad` ABI is 136 bytes and tested for offsets. Changes affect WGSL attributes, generated Vulkan/Metal/D3D/GL shader artifacts, software rasterization, WebGPU, draw serializers/conformance tools and any host that consumes the draw list. Do not grow every quad for every new style option.
- `Look` is a 32-byte cold row, while optional `Extra` rows already hold off-default border/UV/radii/opacity/transform data. This is a good precedent for sparse optional style/effect data.
- `features.Usage` and `comptime/features.zig` already derive feature usage; software can compile only selected kinds and draws omitted kinds in magenta. Extend this mechanism to declared capability requirements and explicit unsupported/fallback diagnostics.
- GL ES2 explicitly omits params-based stock effects and ignores material handles; it also needs more attributes/varyings than the minimum ES2 guarantee. A common interface is not proof of visual feature parity. Rich styling must declare a backend profile.
- Software is the architectural floor and is required for embedded use. Color filters/simple gradients can have software implementations; expensive blur/compositing should be opt-in with bounded temporary buffers and a clear unsupported policy on tiny targets.
- Custom materials are source code for GPU pipelines; software cannot generally execute arbitrary WGSL. A custom effect needs a software function/data equivalent, a pre-rendered asset, a disabled diagnostic, or a documented backend restriction.
- A new command kind for layer boundaries/effects requires all render loops and host interleaving routes to be updated. Keep host ownership of device, queue, render pass and memory, as the design mandates.

## 4. Performance and data-oriented design implications

The source conventions require caller-owned memory, integer indices, columns grouped by pass, padded SIMD, no OS/allocator/GPU dependencies in Tier 0, and read-only compile-time tables where possible. A styling system can fit these rules while preserving the repository's API-design principles: granularity, redundant one-call shortcuts for common work, no hidden coupling, no retention at the lowest tier, and caller-owned flow control. Registries, interning and style caches are optional higher-level conveniences; none should become a prerequisite for supplying raw values or calling a Tier-0 pass:

1. **Keep raw data direct; optionally resolve richer styles.** Typed declarations can be larger than hot runtime representation. A caller may supply resolved rows directly, use a pure resolver over caller-owned data, or opt into a cache keyed by token/style/state/environment generations. Static declarations can resolve at compile/setup time. Neither registration nor persistent cache state is required by the low-level path; paint loops should consume compact resolved data rather than traverse selectors or string maps.
2. **Store optional features separately.** Layered backgrounds, stop lists, shadow lists, decorations, clip chains and filter chains use pooled immutable spans/indices. Simple widgets retain compact rows and a direct renderer path.
3. **Separate invalidation categories.** Paint color change should not reshape text; transform-only change should not relayout; font/size/letter spacing does require shaping/layout; a token change should touch its dependents. Rich text paint spans should not unnecessarily break shaping runs.
4. **Avoid giant state tables.** Eight rows work for hover/held/focused. Twenty independent states imply a million combinations; compile reachable combinations or resolve ordered overrides into cached style IDs, rather than allocating every theoretical combination.
5. **Preserve token identity when using tokens.** Compile-time palette recoloring currently compares color values. An explicit literal-versus-token value or role reference resolves ambiguity; optional dependency tracking can then target invalidation. Plain literal colors remain valid without entering a token registry.
6. **Batch without violating paint dependencies.** Separate backgrounds/effects can add draws, but batching must use true paint bounds and compositing boundaries. Transparent reorder, masks and backdrop reads are semantic constraints.
7. **Bound memory by chosen profile.** A caller should see capacities for stops, paint layers, clip records and offscreen surfaces. Do not hide temporary full-window textures behind a border or shadow option.
8. **Measure normal entry points.** Tests/benchmarks should include build+resolve+layout+text+paint, plus software/GPU draw, and no-style/idle cases. Microbenchmarks of a style lookup alone cannot establish framework performance.

## 5. Implementation roadmap

The canonical sequencing, scope, dependencies and acceptance criteria are in [implementation-plan.md](implementation-plan.md). This audit supplies the current-state evidence and architectural constraints for that plan.

## 6. Test structure to retain and extend

- `types.zig`, `draw_list.zig`: exact packed/extern layouts and ABI offsets.
- `widgets/base.zig`: `Harness` runs runtime/comptime paths and `sameDraw` checks quad/text/command output; widget replay fixtures and golden tooling exist.
- `comptime/paint.zig`: runtime equivalence fixtures and static template assertions; transform compile error is explicit.
- `src/text/layout/*`: goldens for wrap/center/end/justify/clamp/carets/rich text; Unicode conformance, HarfBuzz reference output and font fallback tests.
- `src/draw/paths_golden.zig` and test fixtures: path curves/joins/strokes/fill rules/TinyVG.
- `src/render/conformance.zig`, `ci/jobs/sw-golden.sh`, native shader validation: backend pixel conformance.
- `docs/CHECKS.md`, census scripts, size/perf/compile-time budget lanes: do not broaden claims beyond measured workload.

New tests should focus on actual semantic risks: nested clipping, group alpha vs inherited alpha, transformed input/text, backdrop dependencies, style precedence and invalidation, capacity exhaustion and runtime/comptime parity. Avoid mirroring field setters with trivial tests.

## Evidence map: commit-permanent source links

### Exact locations for the highest-priority findings

Line numbers below refer to the pinned commit, not a future branch revision. These are source observations, not executed reproductions.

| Finding | Exact source evidence |
|---|---|
| Inherited alpha, not group compositing | `src/draw/inherit.zig:24–28` assigns `row.alpha = row.opacity * inherited.alpha`; `src/draw/paint.zig:107–118` puts it on each quad; `src/draw/paint.zig:46–58` calls `fade` per text run. `src/draw/draw_list.zig:62–69,98` has only quads/text/custom commands, no save-layer/end-layer command. |
| Transform expressly paint-only | `src/core/types.zig:357–360` documents center-based affine paint transform and explicitly excludes layout, clipping and hit testing. |
| Transform propagates to quad | `src/draw/inherit.zig:29–34` composes center-based world matrices; `src/draw/paint.zig:118` sets `Quad.xform`. |
| Text/custom do not carry corresponding transform | `src/draw/draw_list.zig:36–57` gives `TextRun`/`CustomDraw` no xform field; `src/draw/paint.zig:46–70` writes their layout-space rect and rect clip without applying the matrix. |
| Text/custom lack rounded clip tuple | `src/draw/draw_list.zig:32–33` has `Quad.clip_radii`; `src/draw/draw_list.zig:36–57` has none in text/custom. `src/draw/paint.zig:53,66` propagates only the parent clip rect for those outputs. |
| Rounded clip reduction | `src/draw/inherit.zig:36–38` chooses current node radii if clipping, otherwise inherited radii; `src/layout/layout.zig:374–391` intersects rectangles. `src/draw/inherit.zig:57–61` explicitly explains radii are applied to a possibly outer-clipped rect. |
| Pure comptime transform limitation | `src/comptime/paint.zig:41–56`, especially `51–52`, emits a compile error for nonidentity transforms. |
| Initial visibility ignores expanded/transformed paint | `src/layout/layout.zig:354–358` snaps layout rectangles; `374–391` computes clip intersection and visible flag from those rects. `src/draw/paint.zig:101,122` gates emission using that flag. |
| Shadow extends outside layout rect | `src/draw/features.zig:50–56` documents analytic shadow growth; `src/render/shaders/quad.wgsl:56–58` expands vertices by `3 * sigma`. |
| Damage hash knows world but region does not use world bounds | `src/draw/damage.zig:123–144` includes `world`/`alpha` in hashed quad inputs. `Damage.frame`, `226` copies `t.c.vis` and `232–239` unions only those old/new visible boxes. |
| Damage culling ignores transform/effect growth | `src/draw/damage.zig:261–268` tests only `quad.rect` intersected with `quad.clip`. |
| Overlap-aware reorder ignores transform/effect growth | `src/draw/order.zig:58–68` uses raw quad/text/custom rect and clip for overlap; `69–88` can reorder based on that result. |
| One visual feature per quad | `src/draw/features.zig:1–8,15` states one feature per quad and declares the exclusive enum; helpers encode the selector into the first params word. |
| Current normal finishing path | `src/runtime/frame.zig:254–280` takes `Mono`, sequences plain/incremental layout and calls `finish`; advanced callers can use `finish` after their own layout (`283–291`). |
| Limited ordinary TextStyle | `src/core/types.zig:368–373`: only px, color, font, wrap. |
| Rich text algorithms already exist | `src/text/layout/lines.zig:100–111` alignment/justify/direction; `221` ellipsize API; `src/text/layout/spans.zig:1–9` rich span model and shaping-boundary limitation. |
| Stack defaults to start alignment | `src/text/layout/stack.zig:48–61`: `.Align` gets width/direction only, so factor and justify stay default. |
| Theme identity and inheritance ambiguity | `src/theme/theme.zig:258–275` remaps literal packed color equality; `279–282` checks source palette distinctness. `287–324` uses color/px zero as inherit sentinel. |
| Existing accessibility preference support | `src/a11y/settings_data.zig:11–28`; `src/runtime/frame.zig:184,211,245,277–278` integrates reduced motion into animation helpers and FLIP. |
| ES2 restrictions | `src/render/gles/es2.zig:1–11`: omitted params features, ignored material, extra attribute/varying requirements. `src/render/gles/es2/quad.frag:1–7` independently documents absent gradient/shadow/nine-slice/dashed/dotted feature decoding. |
| Image contain changes layout size | `src/widgets/image.zig:82–88` computes the fitted size with the minimum scale; `108–111` writes it as the node's `.px` size. A 400×200 image in a 100×100 box consequently produces a 100×50 node. |
| Color-only span boundaries still split shaping | `src/text/layout/spans.zig:23–24` stores color as paint-only data; `58–65` nevertheless invokes `sh.shape` separately for every span, without checking whether font and size changed. |
| Custom opacity is a host integration boundary | `src/draw/paint.zig:62–70` writes rect/clip/data/id/node only; `src/render/iface.zig:27–29,40–50` distinguishes host-drawn inline commands from render-to-texture content shown as an ordinary quad. |
| ABI size | `src/draw/draw_list.zig:146–159` asserts 136-byte Quad and 52-byte TextRun layouts. |


- [Core Style, TextStyle, Color](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/types.zig)
- [Optional Extra rows and 32-byte Look](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/core/tree.zig)
- [Built-in gradients, shadow, nine-slice and border patterns](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/features.zig)
- [Theme tokens, states, overrides, recolor and inheritance](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/theme/theme.zig)
- [Flex extensions and limitations](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/flex.zig)
- [Grid algorithm and limits](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/grid.zig)
- [RTL and logical padding](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/rtl.zig)
- [Anchors and stacking layers](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/overlay.zig)
- [Frame build/end/animation APIs](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/runtime/frame.zig)
- [Paint output and primitive differences](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paint.zig)
- [Opacity, transform and clipping inheritance](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/inherit.zig)
- [DrawList ABI and command types](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/draw_list.zig)
- [Pure comptime paint and transform restriction](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/comptime/paint.zig)
- [Visibility/snap/clipping](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/layout/layout.zig)
- [Dirty regions and culling](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/damage.zig)
- [Overlap-aware reorder and opaque passes](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/order.zig)
- [Hit geometry](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/interact/hit.zig)
- [Path building, strokes, coverage and emission](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/paths.zig)
- [TinyVG limitations](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/draw/tinyvg.zig)
- [Image fit](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/image.zig)
- [Paragraph layout](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/lines.zig)
- [Text stack integration](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/stack.zig)
- [Rich spans](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/layout/spans.zig)
- [Built-in shaping](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/shape/shape.zig)
- [Optional HarfBuzz adapter](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/shape/harfbuzz.zig)
- [Font parsing limits](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/font/opentype.zig)
- [Font fallback](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/text/fallback/fallback.zig)
- [Accessibility settings](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/a11y/settings.zig)
- [Software and feature stripping](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/sw/sw.zig)
- [GL ES2 limitations](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/gles/es2.zig)
- [Stock shader](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/render/shaders/quad.wgsl)
- [Widget theme and parity harness](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/widgets/base.zig)
- [Architecture constraints](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/docs/DESIGN.md)
