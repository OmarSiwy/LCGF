# C++ and Rust

C++ and Rust programs use LCGF without the Zig compiler and without a C++ or Rust binary
interface. What Zig does while compiling a comptime UI is split from what it does each frame:

- **Above the seam, `lcgf-gen`.** A prebuilt generator reads your UI spec. It runs the same
  `plan` (src/abi/plan.zig) that the Zig compiler runs at comptime, and it writes tables plus
  inline code in your language: the state struct, the widget enum and the setters.
- **Below the seam, `liblcgf`.** A prebuilt static library reads those tables. A frame is one
  call through a small `extern "C"` boundary (src/abi/lcgf.h).

The tables are words with a header: a format version and a layout hash, checked once at
init. They are the bytes Zig would make, word for word. A UI drawn from C++ or Rust draws what
the same UI draws in Zig, byte for byte (see How it is checked).

## Install

```sh
zig build abi -Doptimize=ReleaseFast --prefix /opt/lcgf
```

The prefix then has:

- `lib/liblcgf_l4.a`, `liblcgf_l8.a` and `liblcgf_l16.a`, one per SIMD lane count, and on
  x86-64 Linux `liblcgf_auto.a`, which chooses at run time;
- `include/lcgf.h`, `include/lcgf/lcgf.hpp` and `include/lcgf/gpu.hpp`, plus Vulkan's headers;
- `bin/lcgf-gen`;
- the CMake package `lib/cmake/lcgf`.

Your build picks one archive. The frame's symbol names the lane count it was built for (`lcgf_frame_u32_f32_l8`). The headers and the Rust crate pick it from the target flags: 8 lanes with AVX, otherwise 4. `LCGF_LANES` overrides that. Nothing is dispatched at run time.

A program shipped to machines it does not know can link `liblcgf_auto.a` instead: CMake's
`-DLCGF_LANES=auto`, or the crate's `lanes-auto` feature. It holds the three widths, each
built for the CPU level it suits (4 lanes for plain x86-64, 8 for x86-64-v3, 16 for
x86-64-v4), and a dispatcher (src/abi/auto.zig) that exports lcgf.h's names. The first call of
any function reads CPUID and points every name at one copy; after that, each call is one
indirect jump. It picks 8 lanes wherever AVX2 is present, AVX-512 included, because 16 lanes
measured slower than 8 on an AVX-512 machine. `LCGF_FORCE_LANES=4|8|16` forces a width the
CPU can run, and `lcgf_auto_lanes()` says which one ran. The rows C++ and Rust push inline need
no dispatch: they go to the columns the chosen copy reports.

The C++ runtime harness on that 2-core AVX-512 VM, median of 9 runs, µs per frame:

| Scene | liblcgf_l8.a | auto, 8 lanes | auto, 16 lanes | auto, 4 lanes |
|---|---|---|---|---|
| springs | 56.9 | 58.1 | 66.1 | 65.8 |
| list | 10.6 | 11.3 | 12.4 | 12.1 |
| resize | 18.8 | 19.4 | 20.6 | 20.7 |

The archive is about 1.6 times the size of one fixed archive (4.5 MB against 2.8 MB), since
the code that does not depend on the width is in each copy.

## The spec

A spec is a `.zon` file. It holds the state's fields with their defaults, and a tree of
`row`, `col`, `label`, `button`, `checkbox` and `slider`. Each widget is expanded exactly as
Zig's `ct.*` builders expand it. src/abi/zon.zig documents the format, and
src/abi/testdata/toolbar.zon is a complete example:

```zon
.{
    .name = "mixer",
    .state = .{ .{ .name = "title", .str = "Mixer" }, .{ .name = "muted", .bool = false }, .{ .name = "volume", .f32 = 0.5 } },
    .ui = .{ .col = .{
        .style = .{ .pad = .{ 8, 8, 8, 8 }, .gap = 4, .fill = .{ .theme = .panel } },
        .children = .{
            .{ .label = "title" },
            .{ .checkbox = .{ .id = "mute", .bind = "muted", .text = "title" } },
            .{ .slider = .{ .id = "volume", .bind = "volume" } },
        },
    } },
}
```

## C++ (C++20, CMake)

```cmake
find_package(lcgf REQUIRED)            # CMAKE_PREFIX_PATH=/opt/lcgf
add_executable(app main.cpp)
lcgf_add_ui(app mixer.zon)             # runs lcgf-gen: mixer.lcgf.hpp; links liblcgf
```

`lcgf_add_ui(app page.html)` takes an HTML page instead (docs/guide/markup.md, "C++ and Rust").

```cpp
#include "mixer.lcgf.hpp"

lcgf::Buffer<mixer::bytes> buffer;     // the exact size: a constant, aligned
mixer::Ui ui(buffer.span());           // checks the tables once: ui.status()
ui.set_volume(0.8f);                   // one store
const lcgf::DrawList& draw = ui.frame(input);
for (const lcgf::Quad& q : draw.quads()) { /* a span over the column */ }
if (ui.events().clicked(mixer::Widget::mute)) { /* already toggled in ui.state */ }
```

The generated header has `static_assert`s that the `State` struct is laid out as the tables
say. You can read and write `ui.state` directly between frames.

## Rust (2024 edition, cargo)

Depend on `bindings/rust/lcgf` and set `LCGF_PREFIX=/opt/lcgf` for the build. The `ui!` macro
takes the spec as Rust tokens; `include_ui!("mixer.zon")` takes the file, and
`include_ui!("page.html")` an HTML page (docs/guide/markup.md, "C++ and Rust"). All run `lcgf-gen`
while the crate compiles:

```rust
lcgf::ui! {
    state Mixer { title: &'static str = "Mixer", muted: bool = false, volume: f32 = 0.5 }
    col(pad: 8, gap: 4, fill: theme(panel)) {
        label(title)
        checkbox(id: mute, bind: muted, text: title)
        slider(id: volume, bind: volume)
    }
}

let mut buf = Box::new(lcgf::Buffer::<{ mixer::BYTES }>::new());
let mut ui = mixer::Ui::new(&mut buf)?;
ui.set_volume(0.8);
let frame = ui.frame(&input);
for q in frame.draw.quads() { /* &[Quad] */ }
if frame.events.clicked(mixer::Widget::Mute) { /* ... */ }
```

The draw list borrows the UI, so it cannot outlive the next frame. String fields are
`&'static str`, so a frame cannot show freed bytes.

## Runtime UIs

A UI built in code each frame, as a Zig program does with `ctx.begin` and `f.open`, uses
`lcgf/runtime.hpp` or `lcgf::runtime`. It costs what the same UI costs in Zig:

- **The row is made where the style is.** A style turns into the row the tree stores
  (`lcgf::Row`, `runtime::Row::from`, ports of Zig's `Template.from`). Both are inlined, so a
  style known at the call site folds to the row at compile time, as it does in Zig. A
  `constexpr lcgf::Row` or a `const` `Row` makes it once for good; `Open`, `Leaf` and `Custom`
  take a style or a row (Rust: `open_row`, `leaf_row`, `custom_row`).
- **The row is pushed inline.** `Begin` asks liblcgf where this frame's tree columns are
  (`lcgf_frame_view`), and `Open` and `Leaf` store the row into them as Zig's inlined `open` does:
  no call. The stores, one per column, are generated from Zig's types (`lcgf/rows.hpp`,
  `rows.rs`, `zig build abi-gen`); only pushRow's few decisions are written by hand. Text, widgets, `Close`, `Custom` and `Animate` are one direct call each.
- **The C API is generated.** `lcgf.h` comes from src/abi/api.zig (`zig build abi-gen`): each
  call is a Zig function under its mechanical name (`Frame.open` is `lcgf_frame_open`,
  `base.button` is `lcgf_button`), and each type crosses as itself (an extern struct) or as
  its words in declaration order (`lcgf_style`, `lcgf_theme`).
- **The layouts are checked.** Every type the header names is hashed into `LCGF_LAYOUT`; making a context fails with
  `Status::layout_hash` / `Status::LayoutHash` if the library was built with another layout.

```cpp
std::byte* mem = /* lcgf::Context::Bytes(limits) bytes, aligned to lcgf::column_align */;
lcgf::Context ctx({mem, bytes}, limits);
if (ctx.NeedsFrame(input)) {
    lcgf::Frame f = ctx.Begin(input);
    f.Open(lcgf::Id::From("toolbar"), {.dir = lcgf::Dir::x, .gap = 8, .fill = ctx.theme().panel});
    if (lcgf::Button(f, lcgf::Id::From("reset"), "Reset").clicked()) ++resets;
    lcgf::Slider(f, lcgf::Id::From("exposure"), exposure, 0, 1);
    f.Close();
    const lcgf::DrawList& draw = ctx.End();
}
```

```rust
let mut ctx = runtime::Context::new(&mut buf, &limits)?;
if ctx.needs_frame(&input) {
    let mut f = ctx.begin(&input);
    f.open(Id::from("toolbar"), &Style { dir: Dir::X, gap: 8.0, fill: th.panel, ..Style::DEFAULT });
    if runtime::button(&mut f, Id::from("reset"), "Reset").clicked() { resets += 1; }
    runtime::slider(&mut f, Id::from("exposure"), &mut exposure, 0.0, 1.0);
    f.close();
    let (draw, wake) = f.end();
}
```

In Rust the frame ends itself (`f.end()`), and the draw list it returns keeps the context, and
any canvas batch and options the frame drew (`Frame::canvas`), borrowed while it is used.
`Frame::Custom` / `Frame::custom` make a node the host draws itself (its rect comes back in the
draw list's customs), and `Animate` / `animate` give a value that eases toward a target on a
spring. `bench/vs/lcgf-cpp` and `bench/vs/lcgf-rust` run bench/scenes' scenes this way.

Each language's own idioms carry what Zig's runtime front end has besides:

- **Options by name.** C++ takes them as designated initializers, `lcgf::Slider(f, id, gain,
  {.min = 0, .max = 4})`, `lcgf::Button(f, id, {.label = "Save"})`; Rust as structs with
  defaults on a kit over the frame, `let mut ui = f.kit(); ui.slider(id, &mut gain,
  SliderOptions { max: 4.0, ..Default::default() })`. The positional functions stay.
- **Formatted text, in place.** `lcgf::LabelF(f, "Gain {:.1f}", gain)` and `f.TextF(ts, ...)`
  (`std::format`), `lcgf::label!(f, "Gain {:.1}", gain)` and `lcgf::text!(f, &ts, ...)`
  (`format_args!`): the text is formatted straight into the frame's strings
  (`lcgf_frame_room`, then `lcgf_frame_text_written`), with no buffer of
  yours, as Zig's `f.textf` does. Each uses its language's own formatting.
- **Animating any value.** `Animate` / `animate` and `Tween` / `tween` (with `Ease`) move a
  float, a `Color`, an array, a Rust tuple, or a type of yours: specialize
  `lcgf::Components<T>` in C++ (`n`, `get`, `make`) or implement `lcgf::runtime::Animatable` in
  Rust (`N`, `put`, `take`). Each number moves on its own spring, keyed as Zig keys them
  (`id.With(k)`), so a value moves the same in every language.

## Formatted labels

A `.zon` label can write fields into a format instead of showing a string field:

```zon
.{ .text = .{ .format = "{}: {.1} dB", .args = .{ "name", "level" } } }
```

and the Rust `ui!` DSL writes it `text("{}: {.1} dB", name, level)`. The format is
src/core/fmt.zig's, which every engine writes byte for byte alike: `{}` for a string, a bool, a
u32 or a u8, `{.N}` for an f32 with N decimals (0 to 6), `{{` and `}}` for braces. The f32 rule
is exact in every language: the value widened to f64, times 10^N, rounded half away from zero.
lcgf-gen checks the format against the state and refuses one that does not fit. In a static UI
it writes each format out as straight-line calls on a sink in the generated `texts`, so nothing
is parsed at run time; through liblcgf the tables carry the format's segments. A change of any
argument moves the label, so `relayout<Field::level>()` covers it.

## Static UIs

A UI whose rows are all known from its spec (rows, columns, labels, checkboxes and sliders,
and the regions `when`, `list`, `choice` and `virtual_list`, whose rows are reserved; no
buttons or custom draws) can use Zig's comptime pipeline instead of the widgets' tables:
`ct_layout` folds every subtree whose layout does not depend on the viewport, `ct_paint`
paints from one quad template per node, and `ct_events` hit-tests the widgets.

`lcgf-gen --static` makes those tables (src/abi/ct.zig, `make`) with the same functions
`ct_layout.Layout` and `ct_paint.Paint` call while compiling (src/comptime/tables.zig).
liblcgf's static frame is the comptime pipeline's own frame over them (src/abi/ct.zig, `Ui`),
and so are its relayout, patches, hit test, pointer and focus.

Each UI gets that frame specialized to its tables, as Zig's compiler specializes a comptime
UI. In C++, `lcgf_add_ui(... STATIC)` runs `lcgf-gen --static --lang zig`, the UI's words and
constant columns as Zig constants, and builds it with `zig build-obj` against the lcgf sources
`zig build abi` installs in `share/lcgf/zig`. A Zig compiler is optional: CMake uses
`LCGF_ZIG`, else `zig` on `PATH`. Without one it builds `lcgf-gen --static --lang c`
instead. Clang specializes that file, the engine made C by Zig's C backend
(`share/lcgf/lcgf_ct_l*.c`), to the UI's words, somewhat slower than Zig does; any other C
compiler compiles a call into liblcgf's frame, which reads the tables as data. CMake says
which at configure time. In Rust the crate's build script builds it the same way with
`lcgf_build::static_ui("controls.zon")` (the `lcgf-build` crate, a build-dependency), and
`include_ui!("controls.zon", static)` writes the types and tables (`lcgf::StaticUi`).

```cmake
lcgf_add_ui(app controls.zon STATIC)   # controls.lcgf.hpp and its frame, in lcgf_gen_static/
```

```cpp
#include "controls.lcgf.hpp"

controls::Ui ui;                       // lcgf::StaticUi<controls::State, controls::Widget, ...>
ui.set_title("Volume");
const lcgf::DrawList& draw = ui.frame(width, height);
if (auto e = ui.pointer(input)) {      // lcgf::Event<controls::Widget>
    if (e->clicked(controls::Widget::mute)) ui.state.muted = !ui.state.muted;
    if (auto v = e->slid(controls::Widget::volume)) ui.state.volume = *v;
}
ui.focus_keys(input);                  // Tab and Shift+Tab; ui.focus()
```

```rust
lcgf::include_ui!("controls.zon", static);

let mut buffer = Box::new(lcgf::Buffer::<{ controls::BYTES }>::new());
let mut ui = controls::Ui::new(buffer.bytes(), controls::State::default())?;
let draw = ui.frame(width, height);
match ui.pointer(&input) {
    Some(controls::Event::Mute) => ui.state.muted = !ui.state.muted,
    Some(controls::Event::Volume(v)) => ui.state.volume = v,
    _ => {}
}
ui.focus_keys(&input, lcgf::Input::TAB);
```

As in Zig, `Widget` is an enum valued by the widget's row, and an event carries what its
widget's kind carries: Rust's `Event` has one variant per widget, as Zig's tagged union does.
`at(x, y)` gives the topmost widget under a point, and `shortcut` looks up a key chord in a
list of `Shortcut`s. A frame reads the labels' text and the regions' selectors (a list's count,
a condition, a choice, a windowed list's scroll offset) from the state. A checkbox or slider
is one row, as in Zig's comptime UIs, sized by its `style`. A spec with a fixed screen
(`.viewport = .{ 320, 240 }`) keeps its rects in the smallest integer type that holds it.

### Partial relayout and colour patches

As in Zig (`Layout.relayout(field)`, `Paint.Patches`), a change to one field need not cost a
frame. `relayout` lays out again only the rows the field's labels can move: the subtree under
the nearest row whose size cannot change with its children, found by `lcgf-gen` (the
`dirtySpan` table), then finalizes and repaints. A field no label shows does nothing, and a
folded UI, or a field shown above every such row, lays out the whole tree. The viewport and
the regions' selection stay as the last frame left them, so a change to a list's count or a
scroll offset still needs `frame`.

A `.color` field bound to a node's fill or border (`.fill_bind`, `.border_bind` in its `style`)
is written into that node's quad by `patch`: its rgb, the alpha the style gave kept, with no
layout and no paint. `dirty()` lists the quads patched since `clear_dirty()`, for a renderer
that uploads only those; after a frame or a relayout every quad is dirty. A frame applies every
binding, so it never shows a stale colour. Colours are `0xAABBGGRR` (`lcgf.types.Color`).

```zon
// palette.zon
.state = .{ .{ .name = "title", .str = "Palette" }, .{ .name = "accent", .color = .{ .rgb = .{ 200, 40, 40 } } } },
// ...
.{ .col = .{ .style = .{ .size = .{ .{ .px = 20 }, .{ .px = 20 } }, .fill_bind = "accent" } } },
```

```cpp
ui.state.title = "Palette 2";
ui.relayout<palette::Field::title>();   // the title's row only
ui.state.accent = 0xff2828c8;
ui.patch<palette::Field::accent>();     // one quad's fill, nothing laid out
for (std::uint32_t k = 0; k < ui.dirty().size(); ++k) if (ui.dirty()[k]) upload(k);
ui.clear_dirty();
```

```rust
ui.state.title = "Palette 2";
ui.relayout(palette::Field::Title);
ui.state.accent = 0xff2828c8;
ui.patch(palette::Field::Accent);
```

These are calls into liblcgf (`lcgf_ct_relayout`, `lcgf_ct_patch`), which read the span and the
bindings from the UI's tables. A frame applies every binding too.

### Arithmetic and cost

Every frame is Zig's own code, so it keeps Zig's arithmetic exactly. A UI's frame built from C
is compiled with `-ffp-contract=off` (CMake, `lcgf_build`), since an FMA would change results.

What a frame costs, instructions and cycles per frame (layout, finalize, paint, the label text
and selectors from the state each frame): a Ryzen 7 8700F pinned to one core, everything built
for it (8 lanes, `-march=znver4`), Zig 0.18-dev (LLVM 23), clang and GCC from the `vs` shell
(clang 21, GCC 16), rustc 1.99, medians of 5 interleaved rounds of 240 frames, the count at 100
repetitions less the count at 0:

| UI | Zig comptime | C++, `zig build-obj` | C++, clang (no Zig) | C++, GCC (no Zig) | Rust, Zig-built | Rust's former port of the passes |
|---|---|---|---|---|---|---|
| settings (32 nodes, fixed 320x240) | 8,489 / 4,760 | 8,711 / 4,784 | 9,052 / 4,078 | 13,578 / 5,545 | 8,727 / 4,754 | 8,707 / 3,977 |
| todo (39 nodes: a list, a `when`, a `choice`) | 10,991 / 6,362 | 10,955 / 6,211 | 12,414 / 5,455 | 16,929 / 7,305 | 10,964 / 6,181 | 10,632 / 5,322 |
| dash (13 nodes, three clipped tiles) | 3,487 / 2,056 | 3,596 / 1,975 | 3,898 / 1,876 | 5,544 / 2,381 | 3,591 / 1,995 | 3,479 / 1,730 |
| mixer (8 nodes) | 985 / 661 | 1,038 / 672 | 1,476 / 831 | 3,214 / 1,198 | 1,048 / 677 | 1,123 / 562 |

(The clang and GCC columns come from an earlier run of the same harness and conditions. Rust's
port of the passes, `lcgf::ct`, was deleted in favour of the Zig-built frame.)

Built by Zig, a C++ or Rust UI's frame runs within 0 to 6% of Zig's instructions and at Zig's
cycles: it is Zig's code. Without Zig, clang comes within 7 to 50%, and GCC, which runs
liblcgf's frame over the tables as data, takes 1.5 to 3.3 times. The former Rust port ran as
many instructions in 11 to 20% fewer cycles than Zig's: a gap in Zig's code generation for the
passes, which, closed in Zig, speeds up every language.
For comparison, the runtime tree's push and layout alone, without paint, take 390, 570 and 1,460
ns for the mixer, dash and settings (`zig build ct-layout-bench`).

## The GPU

`lcgf/gpu.hpp` follows Dawn's `webgpu_cpp.h`, and `lcgf::gpu` follows the `wgpu` crate. Both
project [lcgf_render.gpu](gpu.md)'s frame model onto one back end, chosen when you build, as
`-Drender` chooses it in Zig:

| Back end | C++ | Rust | A type is | A call is |
|---|---|---|---|---|
| Vulkan | default | default | the Vulkan handles | a `vkCmd*` through your function table |
| GL ES 3 | `LCGF_GPU_GLES` (`lcgf::gpu_gles`) | feature `gles` | the GL names | the `gl*` calls, through `GlFns` you load |
| wgpu-native | `LCGF_GPU_WGPU` (`lcgf::gpu_wgpu`) | feature `wgpu` | the `webgpu.h` handle | one `wgpu*` call |
| Metal | `LCGF_GPU_METAL` (`lcgf::gpu_metal`) | feature `metal` | the Metal `id`s | one `objc_msgSend` per message |
| Direct3D 12 | `LCGF_GPU_D3D12` (`lcgf::gpu_d3d12`) | feature `d3d12` | the D3D12 objects and descriptors | the COM method it stands for |

Metal is reached as the Zig back end reaches it: libobjc and Metal are opened at run time
(`lcgf::gpu::objc::Load()`, `lcgf::gpu::objc::load()`), and each message is `objc_msgSend` cast
to its C signature, with each selector registered once. Nothing is linked, so the header and the
crate build on any host, and an `id` converts to metal-cpp's `MTL::` types or the `objc2`
crates' by pointer.

Direct3D 12 builds on `d3d12.h`: the Windows SDK's or MinGW's on Windows, and Microsoft's
DirectX-Headers elsewhere (`zig build abi` installs them under `include/directx-headers`, which is
how bindings/check builds it on Linux). The Rust side's types and interfaces are generated by
windows-bindgen from Microsoft's metadata (`bindings/rust/d3d12-bindgen`, output committed as
`lcgf/src/gpu/d3d12_sys.rs`); objects are raw COM pointers in `Copy` structs, borrowed as the
interface types for each call, so nothing is reference-counted behind your back and a pointer
converts to the `windows` crate's types. Methods that return a struct (a heap's start, a
resource's description) are called in the Windows ABI's form, a result pointer after `this`, as
the Zig back end calls them.

The phases are types:

- C++ `Upload::Finish() &&` consumes the upload.
- Rust `Upload::finish(self)` consumes it too, so no write can follow it.
- A Rust pass ends when it is dropped, as in wgpu.

```cpp
lcgf::gpu::Upload up(device, cmd);
up.WriteBuffer(tint, 0, &opacity, sizeof opacity);
lcgf::gpu::RenderPassEncoder pass = std::move(up).Finish().BeginRenderPass(desc);
pass.SetPipeline(pipeline);
pass.SetBindGroup(0, group);   // textured::Group0, made from the WGSL
pass.Draw(3);
pass.End();
VkCommandBuffer raw = pass.Get();
```

```rust
let mut up = gpu::Upload::new(&device, cmd);
up.write_buffer(&tint, 0, &opacity.to_le_bytes());
let encoder = up.finish(); // `up` moved: no writes after this
let mut pass = encoder.begin_render_pass(&desc);
pass.set_pipeline(&pipeline);
pass.set_bind_group(0, &group, &[]);
pass.draw(0..3, 0..1);
let raw: vk::CommandBuffer = pass.as_raw();
```

### Shaders, pipelines and bind groups

A shader is WGSL. `lcgf-gen` reflects its bind groups with the reader `lcgf_render.gpu` uses at
comptime, and writes a `GroupN` struct per group, one member per binding, named as in the WGSL.
A pipeline is tied to its shader, so a bind group of another shader does not compile. The code
for each back end is embedded: the WGSL itself for wgpu, naga's SPIR-V for Vulkan, naga's GLSL
ES per entry point for GL ES, naga's MSL for Metal and naga's HLSL for D3D12, with LCGF's
binding table written in (for Metal every resource's slot, for D3D12 the samplers out of naga's
heap, at run time as `lcgf_render.gpu` does at comptime). D3D12's root signature is built from
the bind groups.

```cmake
set(LCGF_GPU GLES)                         # VULKAN (default), GLES, WGPU, METAL or D3D12
lcgf_add_shader(app shaders/textured.wgsl) # runs naga and lcgf-gen: #include "textured.lcgf.hpp"
target_link_libraries(app PRIVATE lcgf::gpu_gles)
```

```cpp
lcgf::gpu::RenderPipelineOf<textured::Shader> pipeline;
lcgf::gpu::CreateRenderPipeline(device, {.vertex = {"vs", buffers}, .fragment = &frag}, &pipeline);
lcgf::gpu::BindGroup<0> group;
lcgf::gpu::CreateBindGroup(device, arena, pipeline, textured::Group0{tint, texture.CreateView(), sampler}, &group);
```

In Rust, `lcgf::include_shader!("textured.wgsl")` does the same while the crate compiles and
embeds the code for every back end; a back end reads only its own, and the rest never reaches
the binary.

```rust
lcgf::include_shader!("textured.wgsl");
let pipeline = device.create_render_pipeline::<textured::Shader>(&desc)?;
let group = device.create_bind_group(&mut arena, &pipeline, &textured::Group0 { params: &tint, tex: &view, smp: &sampler })?;
```

`zig build abi -Dwgpu-native=v29` installs wgpu-native's headers and libraries beside liblcgf.
The Rust crate declares the part of `webgpu.h` it calls; the gate holds every struct's size and
field offsets to the C header's.

## What crosses the seam

- **Specs.** The reference widgets (`row`, `col`, `label`, `button`, `checkbox`, `slider`, with
  the default theme), dynamic regions (`when`, `list`, `choice`), custom draw nodes
  (`ct.custom`), springs on bool and f32 fields, and keyboard focus (Tab and Shift+Tab through
  checkboxes and sliders).
- **Runtime UIs.** `Frame.open`, `leaf`, `close`, `text`, `custom` and `animate`, and the
  reference widgets, through `lcgf/runtime.hpp` and `lcgf::runtime`.
- **Static UIs.** `row`, `col`, `label`, `checkbox`, `slider` and the regions `when`, `list`,
  `choice` and `virtual_list` through the comptime pipeline (`lcgf-gen --static`): folded
  layout, paint templates, hit testing, pointer events, focus and shortcuts, compiled in C++
  and Rust or through liblcgf, with partial relayout (`relayout(field)`) and colour patches
  (`Paint.Patches`) in the compiled UIs.
- **Not supported.** Custom widgets with Zig code of their own (`Spec.widget` with `push` and
  `step`) are compile errors in a spec that uses the seam. Windowed lists (`virtualList`) cross
  only as static UIs.

## How it is checked

`ci/run.sh bindings` installs `zig build abi -Dwgpu-native=v29` and builds the C++ checks with
CMake and the Rust crates with cargo, against that prefix only. bindings/check/run.sh then:

- replays 1,086 frames of pointer and Tab input over three UIs (a toolbar from `.zon`, a mixer
  from the `ui!` DSL, and a panel with regions, a custom draw node and a spring) through Zig's
  `ComptimeUi`, Zig through the seam, C++ and Rust. Draw lists and events must be
  byte-identical, and every widget must receive an event;
- links the UIs and three of the scenes against `liblcgf_auto.a` and runs them with each lane
  width forced; every width must make the same frames;
- makes rows from 4,096 styles (every size kind, ties, signed zeros, infinities, NaN) in Zig,
  through liblcgf's `lcgf_template_from`, with `lcgf::Row` and with `Row::from`. They must be
  equal word for word;
- draws the comptime examples (mixer, card, settings, badge, dash, todo and feed with their
  regions, and sized controls) through Zig's comptime pipeline, and their `.zon`
  (src/abi/testdata/static/) through `lcgf-gen --static` into C++ (each UI's frame by
  `zig build-obj`, and from C by clang and by gcc) and Rust (the same three ways): 240 frames of changing viewports, label
  text, list counts, conditions, choices and scroll offsets, with pointer and Tab input. The
  draw lists, events and focus must be byte-identical, at each lane width of `liblcgf_auto.a`
  too;
- builds bench/scenes' six scenes through the runtime front end in Zig, C++ and Rust, 120 frames
  each with hovers and presses, including whether each frame was needed, and two of them again
  with 40 nodes and a stack of 3, so the inline pushes overflow. They must be byte-identical;
- records one GPU frame through `lcgf_render.gpu`, `gpu.hpp` and `lcgf::gpu` as Vulkan calls with
  every argument and struct field. The three logs must be equal;
- makes buffers, a texture, a sampler, two pipelines (with their MSL), their bind groups and the
  same frame through the Zig Metal projection, `gpu.hpp` with `LCGF_GPU_METAL` and `lcgf::gpu`
  with `metal`, against a stand-in Objective-C runtime that logs every message with its
  arguments (bindings/check/objc_record.c, x86-64 Linux). The three logs must be equal, and the
  Metal checks must compile for aarch64-macos;
- does the same through the Zig D3D12 projection (translated for Linux against DirectX-Headers),
  `gpu.hpp` with `LCGF_GPU_D3D12` and `lcgf::gpu` with `d3d12`, on a recording device whose COM
  methods log every field of every struct they take, D3DCompile's input and the serialized root
  signatures included (bindings/check/d3d12_record.c). The three logs must be equal, and the C++
  check must compile against MinGW's `d3d12.h` for Windows;
- runs check.zig's GPU checks (render to a texture and sample it, a compute pass) in C++ and Rust
  on Vulkan (lavapipe), GL ES 3.1 (llvmpipe) and wgpu-native, and compares the Rust `webgpu.h`
  layouts with the C header's.

The Zig tests check the tables themselves. src/abi/zon.zig compares the tables `lcgf-gen` makes
from the `.zon` specs with the ones Zig makes at comptime, word for word, static UIs included.
src/abi/ct.zig compares the static engine's frames with `ct_layout` and `ct_paint` over 13
UIs (the examples, bench scenes that fold, sort batches and clip, and painted regions beside a
fold), and its templates and constant columns with theirs. src/abi/seam.zig
replays input through `ComptimeUi` and through the seam. src/abi/runtime.zig drives the runtime
front end through its C calls, and src/render/gpu/naga.zig holds lcgf-gen's GLSL binding patch
to the comptime one.

`ci/run.sh vs-lcgf-bindings` measures the C++ and Rust harnesses beside the Zig one, as
bench/vs/measure.py measures every framework: the difference is the seam. On the springs scene
(1,000 leaves and 1,000 springs a frame), median of 11 runs on a 2-core x86-64 VM with AVX-512:

| Front end | µs per frame |
|---|---|
| Zig | 55.4 |
| C++, rows pushed inline | 55.5 |
| Rust, rows pushed inline | 52.2 |
| C++, one call per builder call with the row made by liblcgf (before) | 83.3 |
| Rust, the same (before) | 67.1 |

The rows made by the caller and pushed inline closed it; the remaining difference is within the
run-to-run spread (Zig alone ranged 48.7 to 60 µs).
