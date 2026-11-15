# Targets

The 30 properties this framework is designed to have, and how 15 existing frameworks rate on them. A commit's `targets` field names the ids it advances.

## The targets

| ID | Category | Target | What Yes means | Why it matters | Serves |
|---|---|---|---|---|---|
| A1 | Update model | Fine-grained reactivity | A state change updates only the nodes that depend on it (signals or property bindings); no tree rebuild or diff. | Update cost scales with what changed, not with the size of the UI. | Performant, Responsive |
| A2 | Update model | Compiled UI wiring | The UI description is compiled to direct update code; no runtime template interpreter or virtual tree. N/A for immediate-mode APIs. | Removes runtime machinery from the binary and from the hot path. | Lightweight, Performant |
| A3 | Update model | Batched updates | Many state changes in one tick produce one update, one layout and one paint. | Prevents redundant work and visible intermediate states. | Performant, Responsive |
| B1 | State and memory | Minimal retained state | No widget-object tree that mirrors app state: immediate mode, or a small ID-keyed cache. | Less memory, and no bugs from keeping two copies of state in sync. | Lightweight |
| B2 | State and memory | Flat data layout | Nodes live in contiguous arrays or arenas and are referenced by index; no heap object and virtual call per widget. | Fewer allocations and cache misses; cheap to traverse. | Lightweight, Performant |
| B3 | State and memory | Allocation-free steady state | A frame in which nothing structural changes performs no heap allocation. | Predictable frame times; no allocator churn. | Performant, Responsive |
| B4 | State and memory | No GC or managed runtime | No garbage collector, VM or script engine in the process. | No pauses, a smaller footprint and a faster start. | Lightweight, Responsive |
| C1 | Layout | Bounded-pass layout | Layout finishes in one pass or a fixed number of passes; no general constraint solver or repeated measure loops. | Layout cost is linear and predictable. | Performant |
| C2 | Layout | Incremental layout | Only dirty subtrees are laid out again. | Small changes stay cheap in large UIs. | Performant |
| D1 | Rendering | Small render and text stack | No bundled browser engine or large 2D library: a small renderer plus a modest or OS-provided text stack. | Usually the largest share of binary size and memory. | Lightweight |
| D2 | Rendering | Batched GPU renderer | Few pipelines, instanced or batched draws, glyph atlas. | Low CPU and GPU cost per frame. | Performant |
| D3 | Rendering | Software renderer | Can render without a GPU. | Avoids graphics-driver memory overhead; needed on small devices and in VMs. | Lightweight |
| D4 | Rendering | Damage tracking | Only dirty regions are repainted. | Cuts fill cost and power for small changes. | Performant |
| D5 | Rendering | Zero work when idle | Event-driven: no layout, paint or wake-ups while nothing changes. | Battery life and background CPU. | Lightweight, Responsive |
| E1 | Scale and footprint | Built-in list virtualization | Only visible rows are built and laid out. | Cost scales with the screen, not with the data. | Performant |
| E2 | Scale and footprint | Small binary, fast startup | A minimal app is a few MB or less and starts without booting a runtime. | Download size and time to first frame. | Lightweight, Responsive |
| E3 | Scale and footprint | Runs on microcontrollers | Documented to run in well under 1 MB of RAM. | Evidence that the core really is small. | Lightweight |
| F1 | Responsiveness | Async and background work | A built-in way to run work off the UI thread and deliver results back. | The UI thread never blocks on I/O or computation. | Responsive |
| F2 | Responsiveness | Frame-clock animation | Built-in animations driven by the frame clock, redrawing only what animates. | Smooth motion without continuous full redraw. | Responsive |
| F3 | Responsiveness | Decoupled render thread | Rendering can proceed on a thread separate from UI logic. | Slow app code does not stall scrolling or animation. | Responsive |
| G1 | Control | First-class custom widgets | User widgets implement their own layout, paint and input through the same API the built-ins use. | No ceiling on what can be built. | Customizable |
| G2 | Control | Unstyled, fully themable | No fixed look: every visual of every widget can be replaced. | Product-specific design. | Customizable |
| G3 | Control | Custom shaders on elements | User shaders or materials can be attached to UI elements. | Visual effects without leaving the UI system. | Customizable |
| G4 | Control | Raw GPU access inline | User code gets the device and queue and issues its own draw calls inside the framework's render pass, at the right z-order. | Full control: 3D views, custom pipelines, zero-copy integration. | Customizable, Performant |
| G5 | Control | Texture interop | Externally rendered GPU textures can be shown as UI images, or the UI can be rendered into a user-supplied texture. | Embedding engines, video and offscreen content. | Customizable |
| G6 | Control | Pluggable renderer | The renderer sits behind an interface that users can replace or choose among. | Portability and future-proofing. | Customizable, Lightweight |
| G7 | Control | Embeddable | The host owns the event loop and the frame; the framework is a library the host calls. | Integrates into engines and existing apps. | Customizable |
| H1 | Completeness | Text: shaping, bidi, IME | Complex-script shaping, bidirectional text and input-method editing all work. | Required for international users. | Complete |
| H2 | Completeness | Accessibility tree | Exposes a screen-reader tree to the OS. | Required for many products. | Complete |
| H3 | Completeness | Stable 1.0+ API | Has shipped a stable major version. | Upgrade cost and long-term risk. | Complete |

## How existing frameworks rate

Y = yes, P = partial, N = no, - = does not apply, ? = could not be confirmed. Score counts Y as 1 and P as 0.5; it is a sorting aid, not a ranking.
Ratings are an assessment from public documentation, checked 15 Nov 2026. No framework can score 30: A1 needs a retained dependency graph while B1 asks for minimal retained state. The comptime front end is this project's answer to that conflict.

| Framework | Score | Model | A1 | A2 | A3 | B1 | B2 | B3 | B4 | C1 | C2 | D1 | D2 | D3 | D4 | D5 | E1 | E2 | E3 | F1 | F2 | F3 | G1 | G2 | G3 | G4 | G5 | G6 | G7 | H1 | H2 | H3 |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| Slint | 24 | Retained, property bindings | Y | Y | Y | N | P | ? | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | Y | N | P | Y | ? | P | Y | P | Y | Y | Y | Y |
| Qt Quick (QML) | 21 | Retained, property bindings | Y | P | Y | N | N | ? | P | P | Y | N | Y | Y | P | Y | Y | N | N | Y | Y | Y | Y | Y | Y | Y | Y | P | P | Y | Y | Y |
| LVGL | 19 | Retained, imperative | P | - | Y | N | N | ? | Y | Y | Y | Y | P | Y | Y | Y | N | Y | Y | P | Y | ? | Y | Y | N | P | P | Y | Y | P | N | Y |
| Dear ImGui | 18 | Immediate | N | - | Y | Y | Y | Y | Y | Y | N | Y | Y | N | N | P | Y | Y | N | N | N | N | Y | P | P | Y | Y | Y | Y | P | N | Y |
| Flutter | 18 | Widget rebuild + diff | N | N | Y | N | N | N | N | Y | Y | N | Y | P | P | Y | Y | N | N | Y | Y | Y | Y | Y | Y | P | Y | N | P | Y | Y | Y |
| egui | 17.5 | Immediate | N | - | Y | Y | P | ? | Y | Y | N | Y | Y | N | N | Y | P | Y | N | P | P | N | Y | P | P | Y | Y | Y | Y | P | Y | N |
| Floem | 16 | Retained, signals | Y | P | Y | N | P | ? | Y | P | Y | P | Y | Y | ? | Y | Y | P | N | Y | Y | N | Y | Y | ? | ? | ? | Y | N | P | ? | N |
| Iced | 16 | Elm (view rebuild + state tree) | N | N | Y | P | N | ? | Y | Y | N | P | Y | Y | P | Y | ? | P | N | Y | Y | N | Y | Y | P | Y | P | Y | P | P | N | N |
| Xilem / Masonry | 16 | View diff over retained widgets | P | P | Y | N | P | ? | Y | Y | Y | P | Y | P | ? | Y | Y | P | N | Y | P | N | Y | P | ? | ? | ? | ? | Y | Y | Y | N |
| Clay | 15 | Immediate (layout only) | N | - | Y | Y | Y | Y | Y | Y | N | - | - | - | - | P | P | Y | ? | - | ? | - | Y | Y | Y | Y | Y | Y | Y | N | N | N |
| GPUI | 15 | Hybrid immediate/retained | P | P | Y | P | P | ? | Y | P | ? | P | Y | N | N | Y | Y | P | N | Y | Y | N | Y | Y | N | N | P | N | N | Y | Y | N |
| Makepad | 14.5 | Hybrid immediate/retained | P | N | Y | P | ? | ? | Y | Y | ? | Y | Y | N | ? | Y | Y | Y | N | ? | Y | ? | Y | Y | Y | P | ? | N | N | ? | ? | Y |
| SolidJS (browser) | 14 | Retained DOM, signals | Y | Y | Y | N | N | N | N | - | - | N | - | - | - | Y | N | P | N | Y | P | P | Y | Y | P | P | P | Y | N | Y | Y | Y |
| Dioxus Native (Blitz) | 13.5 | VDOM + signals | P | P | Y | N | ? | ? | Y | P | P | N | Y | P | ? | Y | ? | P | N | Y | ? | ? | P | Y | ? | P | Y | P | P | P | Y | N |
| Svelte 5 (browser) | 13.5 | Retained DOM, signals | Y | Y | Y | N | N | N | N | - | - | N | - | - | - | Y | N | P | N | Y | Y | P | Y | Y | P | P | P | ? | N | Y | Y | Y |

## Notes per framework

- **Slint** (Rust, C++, JS, Python; Desktop, mobile, embedded Linux, MCU, web (wasm)). Compiled .slint DSL with lazy property bindings; software, FemtoVG and Skia renderers. Raw wgpu through the rendering notifier (underlay/overlay) and texture import, behind unstable-wgpu-NN features. Custom paint in user code is limited to composing built-in elements. Tiered licence (GPL, royalty-free, commercial).
- **Qt Quick (QML)** (QML + C++; Desktop, mobile, embedded Linux, web (wasm)). Binding-based reactivity with a batching scene graph on a render thread. Three documented ways to inject custom GPU rendering through QRhi: underlay/overlay, texture item, inline render node. Large runtime; MCU support is a separate product.
- **LVGL** (C; MCUs, embedded Linux, desktop simulators). Retained C object tree that invalidates only changed areas. Software renderer first, optional GPU draw units. Documented minimum of 64 kB flash and tens of kB of RAM. No accessibility; shaping limited to built-in bidi and Arabic support.
- **Dear ImGui** (C++ (many bindings); Desktop, mobile, web, consoles). Emits vertex buffers for your backend; draw callbacks let you change GPU state mid-list. No idle mode built in (the app skips frames itself). No official software backend. No complex shaping, no accessibility.
- **Flutter** (Dart; Mobile, desktop, web, embedded Linux). Rebuild-and-diff on a garbage-collected runtime, but single-pass layout and a mature engine. Fragment shaders on widgets, external textures; the low-level Flutter GPU API is experimental. Not re-checked today.
- **egui** (Rust; Desktop, web, Android). Paint callbacks draw inside egui's own wgpu render pass, with device and queue available in a prepare step. Repaints only on input or request. AccessKit built in. Complex shaping and bidi were historically missing: verify.
- **Floem** (Rust; Windows, macOS, Linux (web experimental)). Signals over a view tree that is built once. Renderers: vello or vger on wgpu, Skia, and a tiny-skia CPU fallback. Taffy flexbox and grid. README documents no raw-GPU hook, IME or accessibility. Pre-1.0.
- **Iced** (Rust; Windows, macOS, Linux, web). View is rebuilt per message. 0.14 added reactive rendering (redraw only when needed), an animation API and IME. The Shader widget gives a custom wgpu pipeline per widget. wgpu and tiny-skia renderers. No accessibility yet.
- **Xilem / Masonry** (Rust; Desktop, Android (experimental), web via DOM backend). Xilem diffs a statically typed view tree onto Masonry's retained widgets. Masonry is usable headless as a base for other frameworks. Vello on wgpu, Parley text, AccessKit. Still labelled experimental.
- **Clay** (C (bindings for Odin and others); Anything with a C99 compiler, incl. wasm). Layout library only: you supply the renderer, text measurement, input and widgets. Control is total because Clay draws nothing itself. Static arena, no malloc, single header.
- **GPUI** (Rust; macOS, Windows, Linux). Entities are retained; the element tree is rebuilt for each dirty view. Metal on macOS, DirectX on Windows, wgpu on Linux since Feb 2026. No public custom-shader or raw-GPU API upstream. Zed is reported to be deferring GPUI work unrelated to the editor; community forks exist.
- **Makepad** (Rust; Windows, macOS, Linux, Android, iOS, web). Own renderer and shader language; every widget is styled by shaders. The UI DSL is evaluated at runtime for live editing. 1.0 released May 2025.
- **SolidJS (browser)** (JS / TS; Web; desktop and mobile via webview shells). Signals with JSX compiled to direct DOM updates and a tiny runtime, but the browser engine is the layout, render and text stack. GPU access is a separate canvas surface composited by the browser. Not re-checked today.
- **Dioxus Native (Blitz)** (Rust; Desktop, mobile (experimental)). An HTML/CSS engine (Stylo, Taffy, Parley) painted with Vello on wgpu: flexible but not small. Signals at component granularity over compiled templates. wgpu textures can be shown inside the UI. Alpha quality.
- **Svelte 5 (browser)** (JS / TS; Web; desktop and mobile via webview shells). Runes (signals) compiled to direct DOM updates, with built-in transitions. Same browser dependency as Solid. Not re-checked today.

## Sources for the ratings

| Framework | What the source supports | Source |
|---|---|---|
| Slint | Design goals, single memory region per component, renderers | https://github.com/slint-ui/slint |
| Slint | wgpu integration: rendering notifier and texture import | https://docs.slint.dev/latest/docs/rust/slint/wgpu_28 |
| Slint | Port to a microcontroller with 264K RAM | https://slint.dev/blog |
| Slint | Screen-reader support (AccessKit) | https://github.com/slint-ui/slint/issues/32 |
| Clay | Scope, arena memory, renderer-agnostic output | https://github.com/nicbarker/clay |
| Dear ImGui | Idle handling is left to the application | https://github.com/ocornut/imgui/wiki/Implementing-Power-Save%2C-aka-Idling-outside-of-ImGui |
| Dear ImGui / egui | Measured power use with and without idle optimization | https://www.forrestthewoods.com/blog/proving-immediate-mode-guis-are-performant/ |
| egui | Custom wgpu paint callbacks (prepare, finish_prepare, paint) | https://docs.rs/egui-wgpu/latest/egui_wgpu/trait.CallbackTrait.html |
| egui | Feature list incl. AccessKit | https://docs.rs/crate/egui/0.37.0 |
| Floem | Features, renderers, status | https://github.com/lapce/floem |
| GPUI | Hybrid model, entities, views, elements | https://github.com/zed-industries/zed/blob/main/crates/gpui/README.md |
| GPUI | Linux renderer moved from Blade to wgpu (Feb 2026) | https://git.secluded.site/zed/commit/af8ea0d6c26192c45f44f473c0d4a7d6f72ed018 |
| Iced | 0.14 release notes: reactive rendering, animation API, IME | https://github.com/iced-rs/iced/releases/tag/0.14.0 |
| Iced | Shader widget (custom wgpu pipeline) | https://docs.iced.rs/iced/widget/shader/index.html |
| Iced | FAQ on text and IME status | https://book.iced.rs/faq.html |
| Xilem / Masonry | Architecture and status | https://github.com/linebender/xilem |
| Xilem / Masonry | Virtual scrolling view | https://docs.rs/crate/xilem/latest/source/src/view/virtual_scroll.rs |
| Makepad | Overview: DSL, shaders, platforms | https://publish.obsidian.md/makepad-docs |
| Makepad | Live system evaluated at runtime; shader language | https://project-robius-china.github.io/makepad-book/guide/start/makepad-framework-architecture |
| Dioxus Native (Blitz) | Crate features incl. accessibility | https://docs.rs/crate/dioxus-native/0.7.7 |
| Qt Quick | Inline custom rendering with QSGRenderNode; the three integration approaches | https://doc.qt.io/qt-6/qtquick-scenegraph-customrendernode-example.html |
| Qt Quick | Scene graph renderer: batching, render thread | https://doc.qt.io/qtforpython-6/overviews/qtquick-visualcanvas-scenegraph-renderer.html |
| LVGL | Minimum flash and RAM requirements | https://docs.lvgl.io/9.5/introduction/requirements.html |
| Flutter, SolidJS, Svelte | Rated from general knowledge; not re-checked against documentation on 15 Nov 2026 | '- |
