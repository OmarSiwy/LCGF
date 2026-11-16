# Render back-end selection: where wgpu's cost goes, and what a selector should be

Research for the proposed compile-time selector (`-Drender=auto|vk|metal|...`, one back end
compiled, no dispatch, a thin per-back-end `Setup`, optionally a runtime `Fallback(.{vk, gles})`).
It answers five questions with measurements on this machine and primary sources, and ends with a
recommendation the build agent can act on.

Every claim carries one tag:

- **[M]** measured here, with the command and load in "Method";
- **[S]** read in source, `file:line` at the pinned tag or commit given in "Sources";
- **[I]** inferred from the two above, with the reasoning given.

## Verdict on the hypothesis

The hypothesis was: most of wgpu's 6x CPU cost is validation and resource/state tracking, then
the wgpu-native FFI layer (handle to Arc, locks), and only a small part is back-end dispatch; the
+7 MB is mostly every back end plus naga compiled in.

- **Dispatch is small: confirmed.** The `wgpu-hal` dyn shims are 3.7% of the extra CPU [M], and
  a wgpu-native built with Vulkan only runs at the same CPU time per frame as the release build
  with every back end (30.6-33.5 us against 31.4-34.2 us) [M].
- **FFI and locking are second: refuted.** The wgpu-native C entry points are 2.3% of the extra
  CPU and lock calls 0.7% [M]. Recording the draws themselves through the C API
  (`wgpuRenderPassEncoder*`) is 3.4% of the frame [M].
- **Validation and tracking are the largest share: partly confirmed.** The symbols that name
  them (trackers, barrier inference, validation, registry lookups) are 17% of the extra CPU, and
  `wgpu-core`'s deferred pass encoding, submit and maintenance, where much of that work is inlined,
  are another 24% [M]. But the single largest block is **allocation and lifetime churn**: malloc
  and free, Arc and Vec drops, hash maps, the GPU memory sub-allocator and memcpy are 34% [M].
  Most of it is caused by wgpu's design (a staging buffer created and destroyed for every
  `write_buffer`, per-submission trackers and `Arc` lists dropped every frame) [S][M], so it is
  the cost of tracking lifetimes, not a separate layer. The extra driver work this causes is
  another 14% on lavapipe [M].
- **"+7 MB is every back end plus naga": refuted.** Back ends compiled in but unused cost little
  resident memory, because their pages are never touched [M]. What costs memory is back ends
  *initialised*: wgpu-native's default instance starts every compiled back end, and since the
  golden shell gained EGL (commit `51c3467`, after C0389) its GL back end loads Mesa's EGL driver:
  wgpu is now **+49 MB** over native Vulkan at start-up on lavapipe, and **+85 MB** on the NVIDIA
  driver, against +3.3 MB when the instance asks for Vulkan only [M]. With Vulkan only, the
  remaining +13 MB after drawing is the GPU memory sub-allocator's blocks (+7.1 MB) and the
  library's own pages (+5.5 MB) [M]; on a discrete GPU the blocks are VRAM and the gap disappears
  [M].

Two corrections to C0389. This machine has a GPU (NVIDIA RTX 4060 Laptop, driver 595.71.05, and
an Intel i9-14900HX), so hardware numbers are below [M]. And C0389's +7.1/+7.3/+13.9 MB no longer
reproduces in the golden shell; it is +49/+49/+56 MB until the instance is restricted to Vulkan [M].

## Method

Machine: Intel i9-14900HX (32 threads, hybrid P/E cores), NVIDIA RTX 4060 Laptop GPU, driver
595.71.05, Linux 7.0.10. Lavapipe: Mesa 26.3.0, LLVM 21.1.8. Zig 0.18.0-dev.1151+8dfb7a7cc. All
binaries ReleaseFast.

Load: `uptime` was 3.3-6.9 for every timing quoted here. One batch (resident memory of the five
variants) started at 8.9; its resident numbers are kept (they do not depend on load: identical to
0.1 MB across three runs) and its CPU numbers are replaced by a later batch at load 4.7-5.8.

Programs: `vk-probe` and `vk-probe-wgpu` from C0389 (`src/render/vk/probe.zig`,
`probe_wgpu.zig`), unchanged. Four builds of `vk-probe-wgpu`, made from a scratch copy of the tree
with two scratch-only edits (an option to link another `libwgpu_native.a`, and an option to pass
`WGPUInstanceExtras{ .backends = WGPUInstanceBackend_Vulkan }` to `wgpuCreateInstance` in
`src/render/wgpu/host.zig`):

| Build | wgpu-native | Instance back ends |
|---|---|---|
| `rel-all` | v29.0.1.1 release archive (build.zig.zon), what the tree uses | all (`wgpuCreateInstance(null)`, as host.zig does) |
| `rel-vkinst` | same archive | Vulkan only |
| `self-all` | built here from tag v29.0.1.1, `cargo build --release --locked` | all |
| `self-vk` | built here, `--no-default-features --features vulkan,wgsl` | all compiled in = Vulkan only |

Commands (golden shell; `nix develop .#golden -c ...`):

```
zig build vk-play -Doptimize=ReleaseFast                      # vk-probe
zig build vk-probe-wgpu -Dwgpu-native=v29 -Doptimize=ReleaseFast
python3 tools/bench/probe.py -- BIN device|empty|scenes        # resident memory (C0389's tool)
BIN scenes </dev/null                                         # CPU and frame time, 2000 frames
VK_ICD_FILENAMES=/run/opengl-driver/share/vulkan/icd.d/nvidia_icd.json ...   # NVIDIA instead of lavapipe
perf record -F 16000 --call-graph dwarf,16384 -o OUT BIN scenes </dev/null    # self time
perf record -F 16000 --call-graph lbr -o OUT BIN scenes </dev/null            # inclusive time
perf report -i OUT --tid MAIN --time START,END --no-children --sort dso,sym -g none \
    -F overhead,sample,dso,sym                                 # frame loop only, main thread
```

`perf` is the bench shell's (`perf-linux-7.3.4`), run inside the golden shell so the Vulkan loader
is found. The `--time` window starts after the last pipeline creation and ends at exit, so only the
2000-frame loop is counted; only the main thread is counted (lavapipe's rasteriser threads are the
GPU here). The memory breakdown sums `Rss:` per mapping from `/proc/PID/smaps` at the same moment
`probe.py` samples (after the `ready` line); the script is 15 lines and is reproduced at the end.

What could be attributed: `libwgpu_native.a` v29 release ships with symbols (1480 `wgpu_core`
symbols in the linked binary) [M], so self time resolves to Rust functions. DWARF unwinding stops
at Rust frames (inclusive time for Rust callers came out equal to self time), so inclusive time
comes from Intel LBR call stacks instead (32 branches deep, enough for every wgpu entry point).
malloc, free and memcpy are leaves whose Rust callers DWARF could not recover; LBR attributes them
to the phases in the second table below. Code that `rustc` inlined into `encode_render_pass`,
`Queue::submit` and `Device::maintain` cannot be split further without a debug build of
wgpu-native, which would no longer measure the release.

## 1. Where wgpu-native v29's per-frame CPU time goes

CPU per frame (prepare, record, submit; `cpu_us` from the probes), five runs each [M]:

| Driver | vk-probe | wgpu `rel-all` | `rel-vkinst` | `self-all` | `self-vk` | ratio |
|---|---|---|---|---|---|---|
| lavapipe (load 4.8-5.8) | 5.4-5.8 us | 31.4-34.2 | 31.0-33.3 | 32.3-35.0 | 30.6-33.5 | 5.8x |
| NVIDIA (load 5.3-5.5) | 5.5-5.9 (one 10.5) | 14.9-29.4 | 15.3-22.4 | 15.4-18.7 | | 2.8x (median 16.1 vs 5.8, `rel-vkinst`) |

Whole frame (until the GPU is done), NVIDIA: 36-37 us native against 53-64 us wgpu [M]. On lavapipe
both are ~540-600 us, dominated by rasterising [M].

**Self time by category**, main thread, frame loop only, lavapipe, DWARF run (`rel-vkinst` and
`vk-probe`, 16 kHz; perf's own overhead inflates absolute time, so read the shares) [M]:

| Category (self time) | wgpu samples | vk samples | share of the extra |
|---|---|---|---|
| wgpu-core: pass encoding, submit, maintain (not split further; validation and tracking inlined) | 488 | 0 | 23.9% |
| driver (lavapipe + Vulkan loader) | 529 | 249 | 13.7% |
| libc malloc/free | 278 | 42 | 11.6% |
| Rust drop / Arc / Vec glue | 183 | 0 | 9.0% |
| wgpu-core: state trackers and barrier inference (`track::*`, `transition_*`) | 181 | 0 | 8.9% |
| wgpu-hal: Vulkan command encoding | 148 | 0 | 7.3% |
| libc memcpy/memset | 144 | 23 | 5.9% |
| wgpu-core: validation and lazy init (`validation::*`, `Binder`, `memory_init`) | 95 | 0 | 4.7% |
| hashbrown and core iterators | 86 | 0 | 4.2% |
| wgpu-hal: dyn dispatch shims (`<C as DynCommandEncoder>::*`, `<D as DynDevice>::*`) | 75 | 0 | 3.7% |
| gpu-allocator (sub-allocation) | 73 | 0 | 3.6% |
| wgpu-core: registry lookups (`Registry::get`, `Storage::get`) | 72 | 0 | 3.5% |
| wgpu-native C FFI entry points | 47 | 0 | 2.3% |
| locks (libc mutex/futex, parking_lot) | 55 | 39 | 0.8% |
| LCGR's own code (probe loop, `drawUntilCustom`, vk back end) | 16 | 67 | -2.5% |
| **total** | **2504** | **464** | 2040 extra = 5.4x |

The five buckets the brief asked for, from that table [M], with the inlined block [I] assigned
where its callees say it belongs:

| Bucket | Share of the extra | Notes |
|---|---|---|
| Validation, tracking, barriers (named) | 17.1% | trackers 8.9 + validation 4.7 + registry 3.5 |
| ... plus the inlined wgpu-core block | +23.9% | `encode_render_pass` replays every recorded command with validation and usage-scope merging; `submit`/`maintain` walk trackers [S] |
| Allocation and lifetime churn | 34.3% | malloc/free, drops, Arc, Vec, hash maps, gpu-allocator, memcpy |
| Driver (extra calls wgpu makes) | 13.7% | per-write `vkCreateBuffer`/`vkDestroyBuffer`, command pool resets, pipeline barriers |
| wgpu-hal Vulkan encode | 7.3% | the equivalent of LCGR's own recording, which is 67 samples natively |
| FFI and locking | 3.1% | C entry 2.3 + locks 0.8 |
| Dispatch | 3.7% | hal dyn shims |

**Inclusive time by phase**, LBR run, `rel-vkinst`, lavapipe, % of the main thread's frame loop [M]:

| Phase | Inclusive | What is inside |
|---|---|---|
| `wgpuCommandEncoderFinish` | 38.9% | `CommandEncoder::finish` 37.8%, of which `encode_render_pass` 35.9% (5.5% self), hal `begin_render_pass` 8.5%, `insert_barriers_from_device_tracker` 4.2% |
| `wgpuQueueSubmit` | 24.2% | `Queue::submit` 22.9%; hal submit 9.1% |
| `Device::maintain` (from submit and poll) | 29.3% | drop `EncoderInFlight` 21.9%: command pool reset 10.8%, drop `TempResource` 6.8% (staging buffers destroyed), `Arc::drop_slow` 4.5% |
| `wgpuQueueWriteBuffer` (`prepare`) | 16.6% | `StagingBuffer::new` 7.0% (a `vkCreateBuffer` + gpu-allocator allocation per call), memcpy |
| `beginPass` / `endPass` / `CreateCommandEncoder` | 3.8 / 2.5 / 2.5% | |
| the draws (`drawUntilCustom` -> `wgpuRenderPassEncoderSetPipeline/SetBindGroup/SetVertexBuffer/Draw`) | 3.4% | recording is cheap: since v27 wgpu records the pass and encodes it at `finish` [S] |
| `wgpuDevicePoll` | 2.8% | |

What this says [I]: wgpu's per-frame cost is not on the draw calls LCGR issues but on the frame's
fixed overhead: a deferred re-encode of the pass, one staging buffer per `write_buffer`, and the
release of every per-submission tracker and temporary resource. That cost is per frame and per
upload, not per draw, so a UI frame with few draws pays it almost
whole. On the NVIDIA driver, where buffer creation and command pool resets are cheaper than
in lavapipe, the gap shrinks from 5.8x to 2.8x (about 10 us per frame) [M].

## 2. How wgpu-core v29 dispatches to wgpu-hal, and single-back-end builds

- Since v23 (2024-10-25) `wgpu-core` is no longer generic over `wgpu-hal` back ends; dispatch moved
  to dyn traits inside `wgpu-hal` [S CHANGELOG.md:2121-2129]. In v29 the device and queue hold
  `Box<dyn hal::DynDevice>` and `Box<dyn hal::DynQueue>` unconditionally, whatever back ends are
  compiled [S wgpu-core/src/device/resource.rs:209, device/queue.rs:50]. There is no generic path
  left to opt into.
- One call costs one indirect call plus a downcast (`as_any`) of each resource argument; measured,
  all shims together are 3.7% of the extra CPU, about 1.2 us of a 32 us frame on lavapipe [M].
- Since v27 command encoding happens at `CommandEncoder::finish`, not when each operation is
  recorded [S CHANGELOG.md:1057], which is why `finish` is 39% of the frame [M].
- Single back end: wgpu-native's Cargo features select them (`default = ["wgsl", "spirv", "glsl",
  "dx12", "metal", "vulkan", "gles"]`; `vulkan = ["wgc/vulkan"]`, ...) [S wgpu-native
  Cargo.toml `[features]`]. `cargo build --release --no-default-features --features vulkan,wgsl`
  builds and runs the conformance probe [M]. `wgpu-core`'s `Instance::new` then calls `try_add_hal`
  only for compiled back ends [S wgpu-core/src/instance.rs:118-127].

Size and memory of the single-back-end build [M] (`size`, text segment; resident from `probe.py`):

| | `libwgpu_native.so` text | probe binary text | resident device / empty / scenes (lavapipe) | CPU per frame |
|---|---|---|---|---|
| release, all back ends | 7.43 MB | 7.39 MB | 123.1 / 128.6 / 154.7 MB | 31.4-34.2 us |
| release, Vulkan-only instance | (same) | 7.39 MB | 77.4 / 86.0 / 112.1 MB | 31.0-33.3 us |
| self-built, all back ends | 7.24 MB | 7.03 MB | 123.1 / 128.7 / 154.7 MB | 32.3-35.0 us |
| self-built, `vulkan,wgsl` only | 5.05 MB | 5.07 MB | 80.2 / 85.3 / 111.4 MB | 30.6-33.5 us |
| self-built, `vulkan` only (SPIR-V in, no WGSL) | 4.40 MB | | | |
| (vk-probe, native) | | 0.51 MB | 74.1 / 79.4 / 98.9 MB | 5.4-5.8 us |

So compiling out the other back ends saves 2.3 MB of file size and no CPU [M], and saves resident
memory only because they are then not initialised; restricting the instance at run time gets the
same resident numbers from the stock archive [M]. LCGR's shaders are WGSL
(`src/render/wgpu/native.zig:125`), so `wgsl` must stay.

By crate, sized text symbols (`nm -S -C`, grouped by crate path) [M]:

| | release, all | `vulkan,wgsl` | `vulkan` |
|---|---|---|---|
| naga | 1.81 MB | 1.15 MB | 0.82 MB |
| wgpu_core | 0.76 | 0.78 | 0.75 |
| core + alloc + hashbrown (generic code instantiated by the above) | 1.31 | 0.97 | 0.85 |
| wgpu_hal | 0.31 | 0.19 | 0.19 |
| spirv, glow, pp_rs, ash, other | 1.12 | 0.61 | 0.59 |
| total sized | 5.31 | 3.70 | 3.20 |

naga is the largest single crate: a third of wgpu-native, still 1.15 MB with one back end, because
`wgpu-core` validates and translates every WGSL module at run time [M][S].

## 3. What wgpu's extra resident memory is

Per-mapping `Rss` at the `ready` line, lavapipe [M]:

| Mapping | vk scenes | wgpu all, scenes | wgpu Vulkan-only, scenes | wgpu all, device | wgpu Vulkan-only, device |
|---|---|---|---|---|---|
| libLLVM | 52.4 MB | 47.6* | 52.4 | 30.5* | 32.7 |
| anon + heap | 30.6 | 59.5 | 31.3 | 56.3 | 28.1 |
| libgallium (Mesa GL, via EGL) | 0 | 11.0 | 0 | 11.0 | 0 |
| libEGL_mesa, libGLdispatch, libX11 etc. | 0 | ~1.5 | 0 | ~1.5 | 0 |
| libvulkan_lvp | 8.5 | 8.4 | 8.5 | 7.4 | 6.4 |
| `memfd:allocation` (GPU memory blocks) | 0.1 | 7.1 | 7.1 | 0 | 0 |
| the binary itself | 0.4 | 6.0 | 5.9 | 5.5 | 3.4 |
| **total** | **98.9** | **148.5*** | **112.1** | **119.6*** | **77.4** |

\* the "wgpu all" columns come from an earlier batch of the same binary, in which libLLVM was
2-5 MB smaller; the later batch's totals for it are 154.7 and 123.1 MB. Totals within a batch
agree to 0.1 MB.

- **Initialised back ends: +46 MB at start-up.** `wgpuCreateInstance(null)` maps to
  `InstanceDescriptor::new_without_display_handle()`, every back end [S wgpu-native
  src/lib.rs:648-666], and `Instance::new` initialises each [S wgpu-core instance.rs:118-127]. The
  GL back end opens EGL and creates a context to enumerate adapters [S wgpu-hal
  src/gles/egl.rs:714, 957], loading Mesa's GL driver: +11 MB of libgallium and ~29 MB of anon and
  heap, though the Vulkan adapter is the one used (wgpu_hal::vulkan frames in every frame-loop
  sample) [M]. Outside the golden shell the system's glvnd picks NVIDIA's EGL instead
  (`libnvidia-gpucomp` 20 MB, `libnvidia-eglcore` 9 MB) [M]. On the NVIDIA Vulkan driver the
  default instance is +85 MB at start-up (159.9 MB against 74.4 MB) and +73 MB after drawing [M].
- **GPU memory blocks: +7.1 MB after drawing.** `wgpu-hal` sizes gpu-allocator blocks from
  `MemoryHints`; the default, `Performance`, asks for 128-256 MB device and 64-128 MB host blocks
  [S wgpu-hal src/lib.rs:434-451], and wgpu-native always passes the default, with a
  `TODO(wgpu.h)` [S wgpu-native src/conv.rs:494-495]. `MemoryUsage` would use 8-64 MB / 4-32 MB.
  Lavapipe backs device memory with memfd host pages, so the touched part is resident; on the
  NVIDIA driver it is VRAM, and wgpu Vulkan-only is **5.8 MB smaller** than native vk after
  drawing (83.6 against 89.5 MB) [M]. That difference is `nvidiactl` mappings: 22.7 MB for vk-probe
  against 9.7 MB for wgpu [M], i.e. LCGR's vk back end maps more host-visible memory at its default
  capacities (`max_quads = 16 * 1024` per frame slot, `src/render/vk/renderer.zig:73`) than wgpu
  does [I].
- **The library's own pages: +3.0 MB at start-up, +5.5 MB after drawing** (naga and wgpu-core
  code paged in by shader translation and the frame loop) [M]. Compiling out back ends lowers the
  file by 2.3 MB but resident pages only by what was touched: `self-vk` maps 4.4 MB of its binary
  after drawing, against 5.9 MB for the release [M].
- **Per-resource bookkeeping: under 1 MB.** Heap grows 0.8 MB more than native vk across 2000
  frames (10.8 against 10.0 MB) [M]; trackers and registries are reused, not leaked.
- Zed reports wgpu needing far more memory than this; Zed itself sets
  `MemoryHints::MemoryUsage` and restricts back ends to `VULKAN | GL` [S zed
  crates/gpui_wgpu/src/wgpu_context.rs:475, 494]. A C program using wgpu-native v29 can do the
  second (`WGPUInstanceExtras.backends`) but not the first [S].

## 4. How other engines select back ends

| Engine | When | Mechanism | What it pays |
|---|---|---|---|
| sokol_gfx | compile time, one per build | `#define SOKOL_GLCORE` / `GLES3` / `D3D11` / `METAL` / `WGPU` / `VULKAN` / `DUMMY_BACKEND` before the implementation; error if none [S sokol_gfx.h:17-26, 6433-6434]. Every call is an `#if` chain to `_sg_<backend>_draw` [S sokol_gfx.h:25102-25115] | Nothing per call. The app owns device and swapchain and passes them in `sg_environment` / `sg_swapchain`; `sokol_glue.h` fills them from `sokol_app.h` [S sokol_gfx.h:477-486, 124-131]. Shaders: one variant per back end, generated offline by sokol-shdc [S sokol_gfx.h:113, 898-905]. |
| bgfx | compile-time list, run-time choice with fallback | `BGFX_CONFIG_RENDERER_*` per platform decide what is compiled [S bgfx src/config.h:110-118]; `s_rendererCreator[]` lists them [S src/bgfx.cpp:3646-3663]; `rendererCreate` scores the supported ones per OS, tries them best first, marks a failed one unsupported and tries the next [S src/bgfx.cpp:3789-3868] | One virtual call per frame, not per draw: draws go into a `Frame` command buffer and the back end replays it in `RendererContextI::submit(Frame*)` [S src/bgfx_p.h:5799, 5861]. Runs the renderer on its own thread. Shaders: one binary per back end from shaderc. |
| Dawn | compile-time set (CMake), run-time adapter | `DAWN_ENABLE_D3D12/METAL/VULKAN/DESKTOP_GL/OPENGLES` [S dawn CMakeLists.txt:146-152]; adapters discovered at run time | Full WebGPU validation in the front end; a `skip_validation` toggle "Skip expensive validation of Dawn commands" exists [S src/dawn/native/Toggles.cpp:117-119]. Tint compiled in for the enabled back ends [S CMakeLists.txt:250-256]. |
| wgpu | compile-time set (Cargo features), run-time instance back ends and adapter | features as in section 2; `InstanceDescriptor.backends` at run time | dyn dispatch inside hal (small, section 2); validation, tracking, staging, deferred encoding (large, section 1); every enabled back end is initialised at instance creation (section 3). naga at run time. |
| Zed (GPUI) | compile time, per OS, by crate | macOS: native Metal renderer (`crates/gpui_apple/src/metal_renderer.rs`); Windows: native DirectX (`crates/gpui_windows/src/directx_renderer.rs`); Linux and web: wgpu (`crates/gpui_wgpu`) with `features = ["std", "metal", "gles", "vulkan", "wgsl", "webgpu"]` [S zed tree at 52b0e43, crates/gpui_wgpu/Cargo.toml:45] | On Linux, wgpu with its own run-time fallback (Vulkan, then GL) [S wgpu_context.rs:494]. |

Did they converge on "comptime selector plus optional run-time fallback"? [I] The engines that
target many platforms with one binary per platform did: bgfx compiles a per-platform set and
falls back at run time; Zed picks the API per OS at compile time and only Linux keeps a run-time
choice (Vulkan or GL), the one platform where no single API is guaranteed. sokol is the pure
compile-time case and leaves fallback to the app (build two binaries). None of them dispatches
per draw except wgpu and Dawn.

Pitfalls they hit, from the same sources:

- **Shader variants per back end.** sokol and bgfx compile shaders offline per back end; wgpu and
  Dawn carry a translator (naga, Tint) at run time, which is a third of wgpu-native's code [M].
  LCGR already translates offline with a pinned naga-cli (`flake.nix`), so a selector needs no
  run-time translator [I].
- **Surface and swapchain setup** is the platform-specific part every engine leaves outside the
  draw API or splits per OS: sokol in `sokol_app`/`sokol_glue`, bgfx in its per-back-end
  `rendererCreate(Init)` with the native window handle, Zed per OS crate [S].
- **Fallback that initialises too much.** wgpu's instance initialises every enabled back end
  before choosing one, and pays 46-85 MB here for a GL driver it never uses [M]. bgfx initialises
  one at a time and only tries the next if creation fails [S]. A LCGR `Fallback` must do the latter.
- **Feature levels.** bgfx's scoring and Zed's adapter ranking (prefer Vulkan/Metal/DX12 over GL,
  lower limits on GL) [S wgpu_context.rs:456, 612-622] exist because the fallback API has fewer
  features; LCGR's GLES path already has an ES2 variant for the same reason
  (`src/render/gles/es2.zig`).

## 5. For LCGR

**What a selector must own, per back end, for an app that brings no device** [S the files named;
I for the grouping]. The shells already contain this code, hard-wired: Wayland draws with `sw`
(`src/shell/wayland/wayland.zig:270`), Android builds a Vulkan `Gpu` struct (library, instance,
device, upload `Once`, sampler, white image, renderer, format; `src/shell/android/android.zig:341-388`),
iOS uses Metal. A `Setup` is that struct, extracted, once per back end:

| Back end | Needs from the shell | Setup creates | Present |
|---|---|---|---|
| vk | a native window (`wl_surface`, X11 window, `ANativeWindow`, HWND) to make a `VkSurfaceKHR` | `loader.Library`, `Instance` (+ surface extensions), `Device` picked to present to the surface, `host.Once`, sampler, white image, `Renderer`, `swapchain.Swapchain` | acquire, record, submit, present; recreate on resize (`vk/swapchain.zig:51`) |
| metal | a `CAMetalLayer` (or the view to attach one to) | `device.Device`, `Layer` (`metal/device.zig:28, 65`), renderer | next drawable; `Layer.resize` |
| d3d12 | HWND | `Device`, `Swapchain` (`d3d12/device.zig:41, 217`), `host.Once`, renderer | `Swapchain.present`, `resize` |
| gles | an EGL native window | `egl.Context` (`gles/egl.zig:123`), function tables, renderer (ES3 or ES2) | `eglSwapBuffers` |
| web | the canvas | WebGPU or canvas2d context via the JS glue | browser |
| wgpu | a `WGPUSurface` from the native window | instance (Vulkan- or Metal-only, see below), adapter, device, queue, `surface.Surface` (`wgpu/surface.zig:32`) | `wgpuSurfacePresent`, reconfigure |
| sw | a pixel buffer from the shell | `Framebuffer` | the shell blits |

The common surface is four calls: `init(window) !Setup`, `frame() ?Frame` (acquire, or null when
the window is minimised), `submit(Frame)` (present), `resize(w, h)`; plus `deinit`. Anything more
is per back end [I].

**What stays platform-specific.** `B.Pass` and `B.Queue` differ per back end and must: Pass is a
`VkCommandBuffer` (vk), `*GraphicsCommandList` (d3d12), an encoder (metal), `void` (gles), a
`Target` (sw), a `WGPURenderPassEncoder` (wgpu); Queue is a frame-slot `u32` (vk, d3d12, webgpu)
or `void` [S `grep 'pub const Pass\|pub const Queue' src/render`]. Custom draws (routes 1-3 in
`src/render/iface.zig`) use the host's own pipeline in that pass, so a custom-draw host is written
against one back end, or switches on the selected one at comptime. The selector should expose
`Backend`, `Backend.Pass` and the `Setup`, and leave custom draws to the app.

**Proving zero cost.** Measured on a scratch copy of the tree: `vk-probe` built twice, once
importing `vk.zig` directly and once through a selector module,

```zig
const opts = @import("render_opts"); // b.addOptions(), enum { vk, none }
pub const Backend = switch (opts.render) {
    .vk => @import("vk.zig"),
    .none => @compileError("no back end"),
};
```

gives the same `size` (text 513,884 B, data 25,872 B, bss 293,645 B) and a byte-identical `.text`
section (`objcopy -O binary --only-section=.text`, SHA-256 `50c3ca56...` for both) [M]. The files
differ only in their build id. A CI check can do exactly this: build one probe per back end both
ways and compare the `.text` hashes. That is stronger than comparing CPU time, which on this
machine moves by 0.4 us between runs [M].

**A run-time `Fallback(.{vk, gles})`** [I]. If it is a tagged union of back ends and `render` does
`switch (fb) { inline else => |*b| iface.render(b, pass.<tag>, draw) }`, the command loop is
compiled once per arm and the branch is taken once per frame, so per-draw cost stays at the
selected back end's. Its costs are elsewhere: both back ends' code in the binary (vk-probe's whole
text is 0.51 MB [M], so this is small), `Pass` becomes a union so custom draws must switch, and
`Setup` must try the first back end and initialise the second only if the first fails (bgfx's
order, not wgpu's).

## Recommendation

Build:

1. **The comptime selector**, `-Drender=auto|sw|vk|metal|d3d12|gles|web|wgpu|null`, `auto`
   resolving per target (Linux/Android/Windows: vk; macOS/iOS: metal; wasm: web; freestanding:
   sw). It is a `switch` on a build option that yields a type; nothing else. Expected cost: zero,
   proven by identical `.text` [M]. Add the CI job that compares `.text` hashes for each back end
   built directly and through the selector.
2. **`Setup` per back end** with `init(window)`, `frame`, `submit`, `resize`, `deinit`, extracted
   from the shells that hard-wire it today (Android's `Gpu` for vk, iOS for metal, Wayland's sw),
   so a shell's `present` calls the selected `Setup` instead of a fixed back end.
3. **Fix the wgpu back end's instance now**, independent of the selector: pass
   `WGPUInstanceExtras.backends` (Vulkan on Linux/Android/Windows, Metal on Apple) in
   `src/render/wgpu/host.zig`. Expected: -46 MB resident at start-up on lavapipe in the golden
   shell (123.1 to 77.4 MB), -81 MB on the NVIDIA driver (159.9 to 78.6 MB), no CPU change [M].
   Update C0389's numbers in `ci/jobs/vk-probe.sh`'s commentary: the +7 MB holds only with this fix.

Do not build:

- **A single-back-end wgpu-native build** for size or speed: -2.3 MB file, no CPU change, and
  resident memory the same as the instance fix gives for free [M]. It would add a Rust toolchain to
  the build for nothing.
- **A runtime-dispatch layer over the native back ends.** The measured dispatch cost inside wgpu is
  3.7% of its overhead [M]; LCGR's own vk back end is 5.6 us per frame against wgpu's 32 us on
  lavapipe and 5.8 against 16.1 on NVIDIA (medians) [M]; the gap is wgpu's tracking, staging and lifetime
  work, which a dispatch layer in LCGR would not add but also would not remove. There is nothing to
  win and per-draw indirection to lose.
- **`Fallback` until a target needs it.** The only case is Linux with no Vulkan driver (old
  GPUs, some VMs); add `Fallback(.{vk, gles})` then, initialising GL only after Vulkan fails.

Expected wins of the native back ends over wgpu, measured here, for the record: CPU per frame
5.4-5.8 us against 31-34 us on lavapipe (5.8x) and 5.5-5.9 us against 15-22 us on NVIDIA (2.8x, medians);
whole frame on NVIDIA 36 us against 54 us; resident at start-up 74.1 MB against 77.4 MB (wgpu
Vulkan-only) or 123.1 MB (wgpu as built today) on lavapipe.

Risks:

- The vk back end's default capacities map 13 MB more host-visible memory than wgpu on NVIDIA
  (`nvidiactl` 22.7 vs 9.7 MB), so after drawing it is 5.8 MB *larger* than wgpu there [M]. Worth
  a look at `max_quads` and per-frame slot sizing before claiming a memory win on hardware.
- The attribution in section 1 is lavapipe's; on NVIDIA the driver share is smaller and the gap
  half as large [M]. The 24% inlined wgpu-core block is not split; a debug-info build of
  wgpu-native would split it but would not measure the release.
- wgpu-native cannot set `MemoryHints` in v29 [S]; if the wgpu back end ever runs on an integrated
  GPU, its 64-128 MB host blocks count against the process.
- A `Setup` per back end is new code on seven platforms; only vk (Android), metal (iOS) and sw
  (Wayland) have a working shell path today to extract it from.

## Sources

Pinned versions:

- wgpu-native **v29.0.1.1** (tag commit `6aed509`), the archive in `build.zig.zon`; source cloned
  from github.com/gfx-rs/wgpu-native at that tag. Its `Cargo.lock` pins **wgpu-core 29.0.3**,
  wgpu-hal 29.0.3, wgpu-types 29.0.3, naga 29.0.3 (crates.io sources), cited by `crate src/file:line`.
- wgpu CHANGELOG.md at tag **v29.0.3** (`4cbe623`), lines cited.
- sokol_gfx.h at floooh/sokol `93aa187`; bgfx `src/config.h`, `src/bgfx.cpp`, `src/bgfx_p.h` at
  bkaradzic/bgfx `3aab320`; Dawn `CMakeLists.txt`, `src/dawn/native/Toggles.cpp` at `d947a20`;
  Zed at zed-industries/zed `52b0e43` (`crates/gpui_wgpu/Cargo.toml`, `src/wgpu_context.rs`, tree
  listing for `gpui_apple`, `gpui_windows`).
- This repo at `5f2567e` (branch `research-render-select`); C0389 is `351c6c9`; the golden shell
  gained EGL in `51c3467` ("gles: create an EGL context").

The two helper scripts (scratch, not committed), for reproduction:

```python
# smaps.py: start COMMAND, wait for its ready line, sum Rss per mapping name from /proc/PID/smaps.
import subprocess, sys, time, collections
p = subprocess.Popen(sys.argv[1:], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True)
line = p.stdout.readline(); time.sleep(0.2)
rss = collections.Counter(); name = None
for l in open(f"/proc/{p.pid}/smaps"):
    parts = l.split()
    if '-' in parts[0] and len(parts) >= 5 and ':' not in parts[0]:
        name = (parts[5] if len(parts) > 5 else '[anon]').split('/')[-1]
    elif parts[0] == 'Rss:':
        rss[name] += int(parts[1])
print(line.strip(), 'total', sum(rss.values()), 'KiB')
for k, v in rss.most_common(25): print(f"{v:8d} KiB  {k}")
p.stdin.close(); p.wait()
```

```python
# crates.py: sum sized text symbols of a library by crate (first path segment of the demangled name).
import sys, subprocess, collections, re
out = subprocess.run(['nm', '-S', '-C', '--defined-only', sys.argv[1]], capture_output=True, text=True).stdout
c = collections.Counter()
for l in out.splitlines():
    p = l.split(None, 3)
    if len(p) < 4 or p[2] not in 'tTwW': continue
    m = re.search(r'(?:<|^)(?:&(?:mut )?)?([a-z_][a-z0-9_]*)::', p[3])
    c[m.group(1) if m else 'other'] += int(p[1], 16)
for k, v in c.most_common(14): print(f'{v/1e6:7.2f} MB  {k}')
```
