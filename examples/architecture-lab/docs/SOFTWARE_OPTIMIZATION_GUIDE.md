# Software optimization and clean feature boundaries

The application has three useful opportunities to avoid work: skip an unnecessary frame, reuse an unchanged subtree, and retain software-rendered pixels. They have different owners and invalidation rules. Keep those rules explicit, then use contiguous data and SIMD for the work that remains.

This guide describes the implemented APIs and their limits. It makes no timing or speedup claims. Use the recorded measurements in the delivered performance report to judge the resulting tradeoffs on a particular workload.

## 1. Put each optimization at the right boundary

| Boundary | Owner | What it can avoid | What still happens when it is used |
|---|---|---|---|
| `Context.needsFrame` and scheduler wake deadlines | Application host | An entire unnecessary application frame | The host still receives input and schedules timer/animation deadlines. |
| Projection cache | Feature presenter or ViewModel | Refiltering unchanged domain records | Views borrow the current index projection. |
| Virtualized table | Workspace view | Constructing and formatting rows outside the visible window | The domain store and filtered index map remain complete. |
| `Frame.reuse` | A feature's frame-building code | Rebuilding unchanged node/text/custom rows; some layout work for fixed-size roots | Rows are copied, required layout passes run, and a complete current draw list is emitted. |
| `host.Incremental` | Software host | Re-expanding unchanged text and repainting unchanged pixels | Concrete draw inputs are compared and snapshotted; a changed region is rendered in paint order. |
| `Window.presentPixelsRegions` | X11 adapter | Uploading unchanged framebuffer regions | Changed pixels are transferred to the server-owned backing pixmap and shown. |

These are independent decisions. In particular, an unchanged incremental framebuffer result is not evidence that frame construction was skipped. The current application already uses projection caching and virtualization; the desktop host opts into retained software output. `Frame.reuse` is available for features whose dependencies are declared explicitly. See [the composition root](../src/app.zig), [the workspace projection](../src/modules/workspace/presenter.zig), [the virtual table](../src/ui/virtual_table.zig), and [the desktop loop](../src/platform/x11.zig).

## 2. Set up caller-owned incremental rendering

The public software-host API is in [`src/example/host.zig`](../../../src/example/host.zig). `host.draw(...)` always draws a complete frame. `host.Incremental.draw(...)` retains concrete draw inputs and returns a `host.Update` describing the physical pixels changed by the call.

The retained host requires persistent storage for four things:

1. The framebuffer pixels.
2. Expanded glyph quads and per-run glyph spans.
3. Snapshot columns and string bytes sized by `Incremental.requiredBytes(limits)`.
4. The `Incremental` value that refers to those snapshots.

Keep the owners alive at stable addresses. Initialize them once after placing the containing application/host state in its final storage. An initialized owner containing slices into its own inline arrays must not be returned by value from a temporary initialization function. The lab uses module-level buffers; a heap-allocated host object initialized in place is also a valid ownership choice.

### Minimal storage and initialization

The following pattern uses the same named modules as the supplied desktop adapter. The framebuffer is managed separately by the window host.

```zig
const lcgf = @import("lcgf");
const host = @import("host");
const application = @import("app");
const limits = application.limits;

var retained_bytes:
    [host.Incremental.requiredBytes(limits)]u8
    align(lcgf.mem.column_align) = undefined;
var retained: host.Incremental = undefined;

var glyph_quads: [limits.strings + 1]lcgf.draw_list.Quad = undefined;
var glyph_first: [limits.texts]u32 = undefined;
var glyph_count: [limits.texts]u32 = undefined;

fn initRendering() void {
    var carver: lcgf.mem.Carver = .{ .buf = &retained_bytes };
    retained = host.Incremental.init(&carver, limits);
}

fn glyphBuffers() host.Glyphs {
    return .{
        .quads = &glyph_quads,
        .first = &glyph_first,
        .count = &glyph_count,
    };
}
```

This glyph-quad budget covers the byte-based `Mono` host's per-byte expansion. A different text renderer must budget its own glyph count. The `first` and `count` arrays must cover every text run. Compute context and retained-snapshot storage with their `requiredBytes` functions; do not substitute an old documented byte total. `mem.Carver` sizes and carves the same column layout and aligns columns to cache lines. Sources: [host storage](../../../src/example/host.zig), [the text protocol](../../../src/text/protocol.zig), and [the memory carver](../../../src/core/mem.zig).

### Frame loop

After `Context.begin`, application construction and `Frame.end`, apply platform requests and draw the complete output:

```zig
var frame = ctx.begin(&events.in);
app.build(&frame, &events);
const output = frame.end(.{});
if (!output.status.ok()) return error.FrameCapacityExceeded;

window.apply(&output.platform);
const update = retained.draw(
    &app,
    &window.gfx.gfx,
    &window.fb,
    glyphBuffers(),
    &output,
    window.scale,
    window.background,
);
try window.presentPixelsRegions(update.boxes[0..update.len]);
```

Place this inside the existing `ctx.needsFrame(&events.in)` condition, and use the scheduler's wake/pace values when waiting. The framebuffer must already have the appropriate physical dimensions and format. For dynamic sizes, allocate or resize pixel storage at the host boundary, then reinitialize the `Framebuffer` view with `Framebuffer.init`. Its stride includes SIMD padding, so allocate using `Framebuffer.len(width, height)`, not merely `width * height`. The complete integration is in [`src/platform/x11.zig`](../src/platform/x11.zig); framebuffer layout is defined in [`src/render/sw/sw.zig`](../../../src/render/sw/sw.zig).

`Update.boxes` contains at most one conservative union rectangle. Coordinates are physical pixels in `(x0, y0, x1, y1)` form, with exclusive upper bounds for upload. Do not scale them again. `len == 0` means the software target needed no pixel writes. `full` records whether a full-target rendering path was required, and `glyphs_rebuilt` records whether this call expanded the text. These fields are useful diagnostics; `boxes[0..len]` is the upload instruction.

The host compares the old and new commands as virtual ordered streams: one primitive per quad in a batch, and one per text command. Forward and reverse cursors find a common semantic prefix and a nonoverlapping common suffix without allocating an expanded command array. Quad equality includes its complete input row and batch key. Text equality includes geometry, style, byte count, and the referenced string bytes; the run index and byte offset only locate storage. This permits batch splits/merges, moved rows, insertions, removals, and reordered content while preserving painter order. A command-list change whose semantic stream is unchanged can require no pixel writes when the other cache guards hold.

The old and new bounds of the unmatched middle form one conservative damage region. The host clears that region and replays the complete current command stream through its scissor, including unchanged overlapping content. Painting only the changed object's new geometry would leave old pixels behind and produce incorrect translucent overlap. Text damage accounts for the actual `Mono` glyph extent, which can exceed a node's nominal text rectangle. These behaviors are implemented and differentially exercised in [the host implementation and tests](../../../src/example/host.zig).

### Invalidation contract

| Change | Handling |
|---|---|
| First retained draw | Full rendering initializes the target. |
| Framebuffer pointer, width, height, stride or format changes | Detected automatically; full rendering. |
| Scale or background color changes | Detected automatically; full rendering. |
| Glyph buffer pointer or capacity changes | Detected automatically; full rendering and text expansion when needed. |
| Quad batch boundaries or storage indices change, but the ordered semantic primitives remain equal | No pixel writes when the other cache guards hold. A changed text-run mapping can invalidate glyph storage for the next paint. |
| Supported primitives are inserted, removed, reordered, or changed | Compare the ordered primitive streams; damage includes the old/new bounds of the middle outside their common prefix and suffix. |
| Text inputs or ordered text-run references change while either frame may fill the shared glyph-quad buffer | Full rendering, because expansion of earlier distinct runs can consume or release capacity used by later labels. |
| An outside operation writes framebuffer or glyph storage | Call `retained.invalidate()` before the next retained draw. |
| External visual state changes without a corresponding draw-input change | Call `invalidate()`, or keep that content on the full-rendering path. |
| Snapshot capacity is insufficient, or frame status reports overflow | The host uses the full path and does not accept the frame as a valid retained snapshot. The application still owns error handling. |

Changing bytes at the same address is not a new-buffer event. Pointer comparison cannot detect an external writer clearing pixels, replacing glyph contents, or recycling the same storage. Invalidate after those operations. Also invalidate before returning to retained drawing after another renderer has used its buffers. `invalidate()` clears both pixel and glyph validity; it does not free, reallocate or change ownership. The implementation compares exact concrete inputs rather than relying on a hash collision assumption. Source: [`host.Incremental`](../../../src/example/host.zig).

Keep window presentation separate from CPU pixel validity. A window exposure may require displaying retained pixels again even if `Update.len` is zero. The supplied X11 backend maintains a server pixmap, restores it on exposure, and uploads the whole framebuffer when a new/resized pixmap needs initialization. Other platform adapters need an equivalent rule. Sources: [the desktop adapter](../src/platform/x11.zig) and [`Window.presentPixelsRegions`](../../../src/shell/x11/x11.zig).

### Supported partial updates and deliberate full rendering

The current retained host accepts identity-transform solid quads and its immutable built-in `Mono` atlas. Eligible quads may still have supported borders, corner radii, clipping and opacity; rendering inside the damage scissor uses the normal renderer semantics. The eligibility check also requires finite geometry and valid text sizes.

Applications declaring `under`, `drawCustom` or `images`, draw lists containing custom commands, arbitrary image bindings, nonidentity transforms, and non-solid feature kinds such as shadows use full rendering. Those inputs can have mutable content or effects extending outside the bounds known to this cache. A frame that returns to supported content establishes a valid snapshot with a full rendering pass. See [`supportsIncremental` and `renderPrepared`](../../../src/example/host.zig).

The single union rectangle is intentionally simple. Two distant changes may repaint the area between them, and unchanged primitives between the first and last difference also contribute conservative bounds. A large unmatched middle can still cover the whole framebuffer. Comparisons and snapshots traverse live draw data; the cursor pass uses only scalar indices and visits each primitive a bounded number of times. Those costs belong in measurements. An unchanged result does not imply constant-time rendering preparation.

Glyph capacity is shared across submitted runs. If an early label grows enough to use the remaining buffer, a later label can disappear even when its own text and geometry are unchanged. Changing repeated references to one run into references to separate equal runs can also consume additional glyph rows. The `limited_text` guard therefore chooses full rendering before semantic stream comparison when changed text inputs or run references and possible prior/current truncation make local bounds insufficient. This preserves the full renderer's bounded-output behavior; complete glyph output still requires an adequate glyph budget. Source: [`limited_text` and `submittedGlyphsMayFill`](../../../src/example/host.zig).

## 3. SIMD and data layout: reduce the work, then process it densely

The runtime owns structure-of-arrays tables for tree geometry, text metrics, interaction data and resource metadata. Integer row links express relationships; callers provide the buffers. Shared layout scratch avoids duplicating transient columns across the two tree generations. Keep large scans in these columns instead of introducing a heap object, callback and allocation for each UI element. Sources: [tree columns](../../../src/core/tree.zig), [SIMD helpers](../../../src/core/simd.zig), and [context storage](../../../src/runtime/context.zig).

| Implemented mechanism | Data processed | Boundary that makes it valid |
|---|---|---|
| Narrow wrapping-flag scan | Text wrapping flags | With no wrapping run, the metric rewrite is unnecessary. |
| Fused owner-range ranks | Text, custom-draw and paint-extras owner columns | Each column's lower and upper rank share one load and live mask; six scans become three. |
| Contiguous subtree string copy | One byte range plus vectorized run offsets/counts | Adjacent spans must actually be contiguous; other spans use the per-run fallback. |
| SIMD node-link and owner rebasing | Copied tree links, text/custom links, animation/timer owners | Indices move by the subtree's source-to-destination row delta. |
| Explicit custom/extras SIMD rebasing | Appended owner-node ranges | The tables' existing spare vector rows allow one vector loop without a scalar remainder. |
| Exact snapshot row comparison | Padding-free `Quad` and `TextRun` words | Struct layout is checked at compile time; no uninitialized padding participates. |
| Specialized texture sampling | One selected image encoding per batch | RGBA8 and Alpha8 have different storage contracts, chosen before pixel loops. |
| Proven solid interiors | Opaque panels, including borderless and subthreshold-border panels | The shader's own floating-point coverage must saturate exactly throughout the candidate interior. |

Sources: [text passes](../../../src/text/protocol.zig), [subtree copying](../../../src/runtime/reuse.zig), [host comparisons](../../../src/example/host.zig), and [software shading](../../../src/render/sw/sw.zig).

SIMD padding is allocated storage, not permission to access beyond a buffer. The core's `simd.rows`/`simd.padded` conventions provide spare rows for vector operations; live-lane masks prevent padding from becoming visible content. Use those helpers for framework columns. Keep small feature preferences as ordinary structs: a sidebar containing two booleans does not need its own vectorized database.

The fused `rangeRanks` loop reads each owner column once to compute both subtree boundaries. Explicit `rebaseNodes` loops use the custom/extras tables' already allocated spare vectors; future pushes overwrite the unused tail. These changes remove redundant scans and compiler-generated scalar remainder work while keeping all loops inline in the production branch probe. They retain the original branch-census ceilings; frame-time effects belong to the separate benchmark results. Source: [range discovery and side-list rebasing](../../../src/runtime/reuse.zig).

The fractional-scale panel optimization, `opaqueInterior`, accepts fully opaque solid panels with the white texture, an identity transform and an unrounded clip. Border widths may be any eligible nonnegative value, including zero and values below the previous interior gate's `0.001` minimum; the reference shader's border-enable threshold is unchanged. Its existing bounds remain: scale from `0.125` through `16`, scaled rectangle coordinates with absolute value at most `2^16`, nonnegative scaled radii and border widths at most `2^16`, and scaled clip coordinates with absolute value at most `2^22`. These checks reject nonfinite inputs; positive rectangle dimensions and a nonempty candidate interior are also required.

An inset proposes an interior; it does not authorize filling it. `interiorCovered` evaluates the extrema of the candidate pixel centers and every possible capped corner radius using the reference shader's own `f32` expressions. Both outer and inner coverage must saturate exactly to one at every included pixel center. The proven center uses a solid fill, while four disjoint surrounding bands retain the original quad and shader, including border color, fractional coverage and clipping. Tight clips, tiny panels or failed proofs use the normal shader. There is no floating-point tolerance or approximate integer snapping in this decision. Ordinary textured rectangles separately retain sampling, antialiasing and blending while omitting inactive transform/border work. Read the gates with the specialized loop; the general shader remains the reference. Source: [`opaqueInterior`, `interiorCovered` and `shadeTexturedRect`](../../../src/render/sw/sw.zig).

## 4. Text: submitted runs, retained glyphs and Alpha8

There are three separate text changes.

**Expand submitted text.** `Mono.quadsForCommands` walks text commands and expands the referenced runs. It retains run indices and paint order, shares an expansion for repeated submitted runs, and gives unsubmitted runs an empty span. A draw list may retain a text side-list row even when its node contributes no text command; such a row does not need glyph geometry. Source: [the text protocol](../../../src/text/protocol.zig).

**Retain unchanged glyph output.** `host.Incremental` compares text runs, string bytes, the ordered text-command run indices, and glyph storage identity/capacity. It skips non-text commands in this comparison, so a quad-color change or quad batch insertion/split can reuse text expansion. Text-run data, string bytes, or the ordered text-run references invalidate the glyph cache; if the semantic pixels remain equal, expansion can wait until a later frame actually paints. This distinction lets moved text storage preserve pixels while ensuring the next draw receives correct `first`/`count` spans for its current run indices. The cache is owned by the host, with the same explicit invalidation rule as its glyph buffers. Source: [the retained host](../../../src/example/host.zig).

**Store monochrome coverage directly.** `sw.Image` now accepts one coverage byte per texel with implicit white RGB:

```zig
const image: lcgf.render_sw.Image = .{
    .alpha8 = coverage_bytes,
    .width = atlas_width,
    .height = atlas_height,
};
```

Width and height must be positive. The selected slice must contain at least `width * height` elements and remain alive during drawing. A nonempty `alpha8` slice takes precedence over `pixels`. Use RGBA8 `pixels` for images that carry their own color. Alpha8 is tinted by the quad's fill color and follows the renderer's coverage/blending semantics. Sources: [`sw.Image` and sampling](../../../src/render/sw/sw.zig) and [the example atlas](../../../src/example/font.zig).

The previous atlas expanded its embedded coverage into RGBA pixels in a **compile-time `const` block**. The current representation directly uses the 144 × 108 coverage atlas: **15,552 bytes instead of 62,208 bytes**, or 75% smaller texel storage. That is a constant-data representation change, not removal of a per-frame atlas-conversion loop. The separate runtime work described above is expansion of submitted text into **glyph quads**. Sources: [the previous compile-time atlas](https://github.com/OmarSiwy/LCGF/blob/ed94db3da27882ef1c87d0dd15a382b4df39e2c2/src/example/font.zig) and [the current Alpha8 atlas](../../../src/example/font.zig).

The direct Alpha8 texel-address shortcut is bounded to dimensions supported by its numeric proof; larger images retain reference sampling arithmetic. The bundled example font remains a byte-based printable-ASCII `Mono` atlas with a fallback cell. Alpha8 does not add shaping, Unicode layout, or proportional-font metrics. A production text stack should keep its font/shape ownership explicit and provide measurements through the existing text protocol.

## 5. Use `Frame.reuse` with complete feature dependencies

`reuse` is an opt-in frame-building contract:

```zig
const panel_id = lcgf.types.Id.from("feature.summary");
if (!frame.reuse(panel_id, &.{ data_signal, theme_signal })) {
    _ = frame.open(panel_id, .{
        .size = .{ .px(240), .px(120) },
        .pad = @splat(12),
    });
    defer frame.close();
    // Build this feature from the committed model and theme.
}
```

Create signals once for the associated context, store their handles with the appropriate state owner, and bump them when the inputs represented by those handles change. Include every application input that changes the feature: model data, theme, filter, selected item, formatting policy and any viewport-derived style values calculated by the feature. A dependency list is a correctness declaration. It is not inferred from values the view happens to read. The copied root must carry the same ID passed to `reuse`. Sources: [runtime signals](../../../src/runtime/signals.zig) and [reuse](../../../src/runtime/reuse.zig).

Reusing a subtree copies its node and side-list rows. It is not a pointer to a permanent widget tree. Current node indices can move, and text is copied into the current frame's string storage. Never use a node row as a durable domain identity. Use `Id` for UI identity and a typed stable item ID for domain actions.

### Automatic behavioral invalidation

| Situation | Current behavior |
|---|---|
| Pointer hovers or holds a node inside the subtree | Rebuild so interaction and visuals update. |
| Keyboard/text events, held keys, contacts or scrolling are present | Conservatively rebuild memos so application handlers can run. |
| Focus identity or focus-visible state changes | Rebuild affected memo calls' visuals even with the pointer elsewhere. |
| A spring/tween owned by the subtree is moving | Rebuild while it advances. |
| A timer owned by the subtree is pending | Copying keeps its owner/deadline alive. |
| An owned timer is due | Rebuild so `Frame.timer` can fire and application state can change. |
| A focused text field requested text input | Rebuild its containing subtree to publish current IME/caret/selection data. |
| Source rows are stale, capacity does not fit, or the previous source overflowed | Rebuild rather than accepting an invalid copy. |

Input/animation/deadline-driven rebuilding can require a further settling frame so the final visual state is not frozen. Unrelated timers and animations do not automatically invalidate every subtree. Sources: [reuse guards and keep-alive logic](../../../src/runtime/reuse.zig) and [timer/scheduler behavior](../../../src/runtime/scheduler.zig).

Declare focus scopes normally with `Frame.focusScope`. Their declaration bytes now follow both tree generations and are copied with moved subtrees. Derived group/lead/Tab-stop data is recomputed for focus processing. This preserves grouped Tab behavior, modal focus trapping, and restoration when a modal closes. The swap happens after focus consumes the previous generation. Sources: [context generation handling](../../../src/runtime/context.zig), [scope declarations](../../../src/runtime/frame.zig), and [focus processing](../../../src/interact/focus.zig).

Request a timer after opening its owning subtree. The runtime records the current open node, so copying can rebase ownership and keep pending deadlines alive. A due repeating timer rebuilds its subtree; a fired one-shot is still removed. Active text input is deliberately different from a static button: platform requests are per-frame output and can contain borrowed strings. The runtime resolves the active input owner once per frame and rebuilds its containing memo; it does not retain borrowed platform strings. Other memos can continue copying.

### When layout finalization can be skipped

A copied root can keep its interior layout when it is a boundary on both axes, as with fixed pixel sizes. Finalized descendant rects, visibility and clips are reused only when its unsnapped root position/size and resulting child clip equal the previous source root. Changed ancestor clipping or fractional placement triggers normal interior finalization. FLIP frames use full finalization because animation can change positions after placement. Paint inheritance still propagates current ancestor transforms, opacity and rounded clips. Sources: [`incremental.keepable` and `finalizeKept`](../../../src/layout/incremental.zig) and [`Frame.end`](../../../src/runtime/frame.zig).

The existing sidebar uses a fixed width and a filling height; the top bar uses filling width and fitted height. Such components can still reuse construction when their dependencies are correct, but they do not automatically qualify for the fixed-size interior shortcut. Choose sizes from the product's layout requirements. The host's pixel retention works independently of that choice.

The additional retained metadata costs one scope-kind byte per node, four owner bytes per timer, and twelve bytes per memo, before column alignment. The current context test records a node-capacity slope of 925 bytes. Use `Context.requiredBytes` for the actual budget, since text, string and other capacities are separate. Sources: [context sizing tests](../../../src/runtime/context.zig), [timer columns](../../../src/runtime/scheduler.zig), and [memo columns](../../../src/runtime/reuse.zig).

## 6. Add sidebar and top-bar features without per-frame allocations

Keep feature boundaries around owned state and behavior. A sidebar, top bar, workspace or inspector is a useful module boundary. A label, spacer or stateless button is a view function. The existing files provide the pattern:

| Responsibility | Sidebar/top-bar example |
|---|---|
| Persistent state and typed intent | `entity.zig` |
| Local state transitions and invariants | `interactor.zig` |
| Small read-only model | `presenter.zig` |
| LCGF calls and action collection | `view.zig` |
| Application/navigation request translation | `router.zig` |
| Public feature surface | `root.zig` |

See [sidebar files](../src/modules/sidebar/root.zig), [top-bar files](../src/modules/topbar/root.zig), and [the application composition root](../src/app.zig). The same passive feature views are shared by the alternative architectures; their state owners and command handlers differ as documented in [the architecture guide](ARCHITECTURES.md).

### A practical extension sequence

For a new top-bar preference, add its small value to the owning state, add a typed action such as `.set_dense: bool`, and expose the value in the presenter model. A reducer should return whether applying the action actually changed the value. The view draws from the committed model and appends the requested action to its fixed-capacity command buffer. If the preference affects workspace presentation, the composition root passes the resulting value to the workspace model; the top bar does not import the workspace's view.

For navigation, return a shared request carrying a page or stable item ID. The application coordinator decides which feature responds. In MVVM-C this is specifically the coordinator's responsibility; feature ViewModels return requests as data. Sources: [shared navigation](../src/core/navigation.zig), [top-bar routing](../src/modules/topbar/router.zig), and [MVVM-C coordinator](../src/architectures/mvvm_c/coordinator.zig).

Complete a feature change through these boundaries:

1. Add state and explicit intent to its feature API.
2. Implement the state transition and report changes/no-ops accurately.
3. Project only values and borrowed slices needed for the current draw.
4. Draw controls with stable namespaced IDs and append bounded actions.
5. Apply commands after all views consume the same committed projection.
6. Route cross-feature requests through the composition owner.
7. Invalidate dependent projections/signals and request a frame after actual changes.
8. Update the selected architecture's command handler; shared action additions may also require handling in the other variants' exhaustive switches.

The current commit order is sidebar, top bar, then workspace. Navigation discards a stale scroll intent from the old page while preserving stable-ID selection semantics. A full command buffer rejects the complete action batch through the existing failure path. Keep those rules consistent when extending a module. Sources: [VIPER commit](../src/app.zig), [bounded commands](../src/core/commands.zig), and [cross-architecture behavior tests](../src/architecture_tests.zig).

### Allocation and lifetime rules

Use inline state, fixed command arrays, caller-owned scratch and read-only projection slices. Stack formatting is valid when consumed immediately by `Frame.text`, which copies the bytes into the frame's string storage. The top bar already uses `std.fmt.bufPrint` into a local fixed array before emitting its summary. Returning a presenter model containing a slice into its own local formatting array would leave a dangling borrow. Source: [top-bar view](../src/modules/topbar/view.zig).

Commands should carry values, stable IDs or explicit resource handles. A slice in an action is still a borrow; either provide owner-backed storage with a documented lifetime or copy into a bounded value payload. A frame-local node index, draw-list pointer or temporary text slice is not durable application state.

Large record data stays in columns. The current projection cache stores filtered `u32` indices and refreshes on store revision or page changes. It belongs to one store; switching stores requires `invalidate()` even if revisions happen to match. The workspace emits only its visible window, whose budget is separate from the 100,000-record domain capacity. Sources: [record store](../src/modules/workspace/entity.zig), [projection cache](../src/modules/workspace/presenter.zig), [virtual table](../src/ui/virtual_table.zig), and [capacity configuration](../src/config.zig).

The ordinary frame and command paths take no allocator. Host startup, resource loading and framebuffer resize have separate ownership and allocation needs. Keep that boundary visible in the host rather than exposing allocators to every feature view.

### Schedule the committed result

The application commits actions after drawing the current projection. When a commit changes state, the lab calls `f.ctx.waker.post()` so another frame displays it. This is deliberate: `Frame.finish()` clears signal dirtiness. If a custom host commits commands outside `App.build`, it owns the corresponding scheduling action. An asynchronous producer also needs to wake the platform's event wait, not merely change a value. Sources: [composition and wake](../src/app.zig), [frame bookkeeping](../../../src/runtime/frame.zig), and [scheduler](../../../src/runtime/scheduler.zig).

## 7. Validate behavior before comparing timings

Use the project's exact Zig pin, `0.18.0-dev.1151+8dfb7a7cc`, and the same target/options for comparisons. This example consumes the single `lcgf` dependency declared in its manifest: the containing framework checkout when used in this repository. Select another checkout with `zig fetch --save=lcgf PATH` when comparing revisions; the architecture option is independent of that dependency. The desktop's `-Dincremental=true` option is enabled by default when the selected host exposes `Incremental`; `-Dincremental=false` keeps full software drawing. Sources: [build configuration](../build.zig) and [desktop selection](../src/platform/x11.zig).

Run relevant checks sequentially on a constrained development machine:

```sh
zig build test check -j2
zig build host-test -j2
zig build framework-test -j2
zig build x11-test -j2
```

From the containing framework root, inspect the core/RGBA and Alpha8 branch probes independently:

```sh
cd ../..
zig build census-src-obj -j2 -Drender=sw -Dcpu=x86_64_v3
python3 tools/census/census.py zig-out/census_src.o \
  --baseline tools/census/baseline-src.json
python3 tools/census/census.py zig-out/census_alpha8.o \
  --baseline tools/census/baseline-alpha8.json
```

The existing core/RGBA ceilings remain unchanged. The separate Alpha8 object and baseline cover the added encoding without allowing compiler merging to hide either probe's loop body. These checks inspect generated branches; they do not measure frame time. Source: [framework probe build configuration](../../../build.zig) and [the census checker](../../../tools/census/census.py).

For a new feature, test its meaningful state transition and real UI activation. For memoized components, include keyboard activation with the pointer elsewhere, focus-group/modal transitions, a pending timer crossing its deadline, and focus acquisition/loss for text input. For pixel retention, compare against full rendering after movement, deletion, text changes, clip/opacity changes, resize, scale changes and explicit invalidation. Existing tests live with [reuse](../../../src/runtime/reuse.zig), [the host](../../../src/example/host.zig), and [the software renderer](../../../src/render/sw/sw.zig).

Return to the example directory for the following commands. Build benchmark executables before timing them, then stop other builds and benchmark processes. The commands below describe reproducible workloads, not checks already run on the reader's machine:

```sh
zig build incremental_bench-build -j2 -Doptimize=ReleaseFast -Dcpu=x86_64
zig build reuse_bench-build -j2 -Doptimize=ReleaseFast -Dcpu=x86_64

./zig-out/bin/incremental_bench 101 800 600 1
./zig-out/bin/incremental_bench 101 1000 750 1.25
./zig-out/bin/reuse_bench
```

[`tools/incremental_bench.zig`](../tools/incremental_bench.zig) checks each measured retained framebuffer against full drawing outside the timed interval and records damaged pixels, full frames and glyph rebuilds. Its pixel payload counts do not include X11 request headers, server work or display latency. [`tools/reuse_bench.zig`](../tools/reuse_bench.zig) compares public frame construction/reuse on approximately 1,000 and 4,000 nodes, with unchanged, ancestor-change and mixed-input cases. Require `same_output_and_updates` before interpreting retained/full timing differences; skipped keyboard or timer work is a correctness failure, not an optimization result.

Keep the metric boundaries distinct: application projection, frame construction/layout, software drawing, upload, and display latency answer different questions. Tail timings, output equality, damage size and memory footprint should accompany any eventual speed claim. The useful next optimization is the one justified by those measurements and a clear validity condition.
