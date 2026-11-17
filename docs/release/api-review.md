# Public API review

The package exposes the namespaces declared in `src/lcgf.zig` and the separately selected `lcgf_render` module. Run `zig build docs` for the declaration index in `zig-out/docs/API.md`. Its entries include storage fields, methods and constants. Generic namespaces also expose declarations chosen by their type arguments. The source and compiler determine those declarations for a particular instantiation.

The [published declaration index](../api/API.md) covers 171 exported files. The generator indexed 2,558 functions and constants at publication. The renderer selector additionally exposes `Kind`, `kind`, `backend`, `Renderer`, `Pass`, `Queue` and the backend-specific `Setup`.

The review uses the five characteristics in the [design guide](../DESIGN.md). Each row covers the public declarations in the named source directories, including nested member types and constants.

| Source family | Granularity and common shortcuts | Coupling and retained state | Who controls execution |
|---|---|---|---|
| `core` | `Carver.slice` and `Carver.columns` support the typed `Tree`, `Texts`, `Strings` and `Customs` constructors. A caller can manipulate the resulting columns directly. | Buffers, generations, index sentinels, capacities and vector padding are caller-visible. A text span borrows the corresponding string store. | The caller reserves, pushes, seals and resets rows. Inputs and replay buffers are ordinary data. |
| `layout`, `interact` | Fit, resolve, place, finalize, hit testing, focus and gesture processing can run individually. The standard frame sequences them. | Per-pass inputs expose their tree, levels or pointer state. Interaction keeps the previous button state and active target to recognize an edge. | Passes run when invoked. A host can supply its own hit result or input stream. |
| `runtime`, `comptime` | `Frame.end` sequences measure, layout and paint. `Frame.finish` follows custom layout. Comptime specs also expose flattened tables, storage classes and individual passes. | `Context.requiredBytes` sizes the caller's storage. Previous trees, scheduler state, memo tables and typed signals have owners. Mixed-front-end composition uses caller-provided output and string storage. | Applications build frames, poll wake state and choose when to present. A comptime widget that defines a step participates only in the application-selected spec. |
| `draw`, `anim` | The command and quad arrays can be consumed directly. Batching, damage, paint, tween and spring passes can be used separately. | A draw list borrows the frame's strings. Damage retains two generations in caller-carved columns. Spring and tween tables have explicit capacity. | The host supplies frame time, advances motion, chooses damage and consumes commands in paint order. |
| `text`, `i18n` | Face parsing, scalar-to-glyph lookup, segmentation, shaping, measurement, wrapping, rasterization, querying and editing expose intermediate data. The text stack and locale bundles sequence common work. | Faces borrow file bytes. Glyph atlases, caches, edit history and fallback runs expose their backing stores or capacity. Locale selection is explicit. | The caller supplies runs, text, font, language and scratch, and chooses when to invalidate cached data. |
| `widgets`, `theme`, `a11y` | Controls compose frame calls. Their style, value and interaction helpers can be used on their own. Theme tokens resolve to ordinary styles. Accessibility exposes flatten, state and change passes. | App values, theme tokens, focus and exported semantic rows have named owners. Platform bridge resources belong to their adapters. | A widget returns a response or updates the supplied value. The host applies platform effects and consumes accessibility actions. |
| `assets` | PNG info, decode, atlas packing, mipmaps and job execution are separate. `image_jobs.start` schedules the same work performed by `run`. | A job borrows bytes, scratch and pixels until its future is joined. The host supplies `std.Io` and completion events. PNG test helpers take explicit allocators. | The host may decode synchronously, or start and wait for a worker on its own I/O implementation. |
| `render`, `lcgf_render` | The render interface exposes prepare, batch, text and custom-command boundaries. `render` draws a whole list. The selector exports the concrete backend, renderer, queue and pass. | Software borrows pixels and images. Native backends retain device-specific pipelines, buffers and textures with their renderer or setup. GPU pass and queue types depend on the selected backend. | The host chooses the backend at build time, begins its pass, inserts custom drawing and submits it. |
| `shell`, `embedded` | The host may call poll, apply, present, wait and wake separately or use `shell_iface.run`. Board scanline flush, RGB565 and mono conversion, bitmap font selection and SPI writes are independent operations. | Shells retain device handles, clocks and buffers. The bare-metal board supplies the transport and owns display memory. Replay data and read buffers must outlive polling. | The host owns the loop. Interrupts, OS events and SPI writes enter through the selected platform adapter. |

## Integration boundaries

- `lcgf_render.Setup` exists for backends that provide device and window setup. An application integrating into its own GPU pass uses `Renderer`, `Queue` and `Pass`. GPU resource lifetime extends through device submission.
- The OS controls native entry points. The iOS shell includes process-wide application and Objective-C class state. The Metal loader stores the resolved system-device entry point. These are platform implementation constraints. A second independent process or headless shell has separate state.
- Exported fixtures such as `fallback.testChain`, the `*_tests` namespaces and the conformance scenes serve examples, diagnostics and tests. Some retain sample data or accept allocators. The production fallback entry points use explicit faces, runs and buffers.
- SIMD storage has a caller-visible padding contract. A raw slice of exactly the logical length can be too short for a vector pass. Use `simd.rows(cap)` or the table's sizing constructor when supplying storage.
- `Context`, `Frame`, text spans, glyph images and draw commands have frame or backing-buffer lifetimes. Consumers retaining an output for later work must retain or copy its borrowed data.

The executable examples behind these findings include the runtime and comptime guides, the headless custom host loop, the byte-identical renderer-selection probes, the mixed-front-end example and the fixed-panel SPI replay. The docs and relevant build targets exercise their normal calling paths.

## Names and module boundaries

The public names distinguish data (`Tree.Columns`, `DrawList`, `Glyphs`), individual operations (`prepare`, `fit`, `resolve`, `place`, `finalize`) and orchestration (`Frame.end`, `shell_iface.run`). The frame's `finish` accepts completed layout through the frame's own columns. GPU calls use the underlying backend's type names for queues and passes. The short names `x`, `y`, `w`, `h` and `uv` denote axes, dimensions and texture coordinates in those domains. Widths on the wire and storage owners remain explicit in their types.

Tracing relative imports across the directories identified these boundaries:

| Source | Finding |
|---|---|
| `a11y/settings_data.zig`, `a11y/settings.zig` | The former holds tier-0 preferences used by runtime and animation. The latter is a tier-2 adapter that maps them into spec, widget and theme values. The directory contains multiple tiers. |
| `widgets/image.zig` | Its image descriptor accepts a texture, UV and size directly. Convenience constructors import the atlas and embedded-image data types. This is a source dependency on the assets family; callers can still supply their own pixels and handles. |
| `theme/theme.zig` | The sheen material imports the shader source composer. The theme supplies material data; the renderer owns pipeline and device resources. This is a dependency on shader representation. |
| `comptime/interop.zig` | The composition step reads public draw-list commands, regions and strings. Each front end can emit its list independently. The host owns the destination list. |
| `anim/anims.zig` | Imports from the widgets and comptime-spec families occur in spring integration tests. The spring stepping loop uses columns and has no widget dependency. |
| `shell/*`, `render/*`, `embedded/*` | Platform and device lifetimes sit here. The software renderer uses the embedded coordinate conversion when selected; both paths consume the same draw-list layout. |

The `render_sw` and `shell_baremetal_*` namespaces identify platform/backend APIs at the package root. `lcgf_render` selects a backend at compile time. The implementation can move behind these names while callers keep their imports. Public test fixtures and diagnostic names are identified separately in the compatibility policy.


The dynamic and paint APIs added at integration follow the same front-end ownership rules. `Regions(spec).Selection` comes from application state. `Slots(spec)` describes alternative geometry storage. `Paint(spec, options)` holds immutable templates and batch ordering at compile time and updates caller-owned draw lists and dirty state. Measured labels borrow the same spans as layout and refer to caller-owned string bytes in draw order. The host runs live layout, paint and mixed-region composition in its own frame order.
