# Direct WebGPU custom drawing with native Vulkan and Metal

**Keep WebGPU optional at build time and cache each custom drawing until the application marks it dirty.** The application gets an ordinary WebGPU device and queue for setup. On a redraw it gets a command encoder and a texture view. It can create its own pipelines, bind groups and WGSL shaders. The host owns submission of the supplied encoder. The sample callback issues the standard WebGPU draw commands directly. [Application code](../../../src/render/wgpu/custom_draw_sample.zig)

LCGR creates one Vulkan device and queue, imports them into a Vulkan-only build of wgpu-native, and exposes a view of an LCGR-owned image to the application. After the callback returns, LCGR records a transition to sampled use, submits the encoder and composites the texture in its native UI pass. Ordinary widgets continue down the Vulkan path. A clean custom node only needs its stored texture. This offscreen experiment serializes frames and waits on a fence after each native submit. [Host and timing loop](../../../src/render/vk/probe_guest.zig)

## What was verified

On November 17, 2026 the patched Rust library and both Zig executables were built from source on Linux x86-64. LCGR base was `766556c`, Zig was `0.18.0-dev.1151+8dfb7a7cc`, and the driver was Mesa lavapipe (llvmpipe, LLVM 21.1.8). The check compared the entire 160 × 120 native frame with a native reference image and independently checked a pixel inside the 56 × 56 custom node.

- Four successive WebGPU clear colors, a textured WGSL draw, and reuse of that texture on the next scene all matched, with **zero differing pixels**. There were five redraws across six frames.
- **2,000 consecutive textured redraws** with synchronization validation enabled completed with zero validation errors. Omitting the final image transition in a control run produced `VUID-vkCmdDraw-None-09600`. In the recovered prototype the HAL also requested the swapchain device extension on its headless device. The probe now enables the corresponding surface instance extension.
- The fresh NVIDIA run could not create a Vulkan instance. The session had no hardware device nodes. NVIDIA timing below comes from the earlier hardware run. D3D12, GLES, resize, multiple frames in flight, and device-loss recovery are open. The Metal follow-up below uses a different sharing path.

The root test, Vulkan test and formatting steps passed (1,201 tests). The prototype suite passed all 10 tests.

## Binary cost

Both executables build from the same Zig fixture in ReleaseFast. The experimental native-only executable uses the v29 type declarations at compile time. It links no wgpu-native archive. Ordinary LCGR builds require neither experiment option.

| Matched executable | Stripped ELF bytes | Code section bytes | Defined WebGPU C entry points |
|---|---:|---:|---:|
| Native only | 543,688 | 407,577 | 0 |
| Native plus statically linked Vulkan/WGSL guest | 5,334,968 | 3,924,778 | 37 |

The opt-in static library adds **4.57 MiB** to this executable. These are file sizes. Resident memory and cold initialization time remain unmeasured. On this branch the existing standalone Vulkan executable (`vk-probe`) had **byte-identical machine code** when built with and without the guest build options. Its 406,985-byte `.text` section had SHA-256 `ce471349a3856faa869722c6ebf75831d751a14275f46cfe8157b9103661ce2d`. The same executable on the base revision had 407,017 bytes of code. Building the matched native target with just the headers also succeeded with the archive option omitted.

## Timing

Fresh lavapipe timings, ten interleaved rounds, 2,000 timed frames per process after one warmup frame. Values are medians of per-run averages in µs. Brackets give min–max across rounds. The one-minute system load ranged from 17.34 to 19.00.

| Application state | WebGPU redraws per 2,000 timed frames | CPU through submit | Full frame |
|---|---:|---:|---:|
| Native-only executable | 0 | 6.85 [5.8–7.7] | 807.65 [733.1–904.0] |
| WebGPU linked, never initialized | 0 | 6.65 [5.5–11.1] | 800.80 [727.4–955.6] |
| WebGPU initialized, node cached | 0 | 6.95 [6.1–7.9] | 799.35 [742.2–862.1] |
| WebGPU node redrawn every frame | 2,000 | 63.55 [52.2–73.0] | 1,040.75 [970.6–1,115.8] |

Relative to the native-only executable within each round, cached-node submit time had a median difference of +0.25 µs (−0.8 to +0.9 µs). These runs cannot resolve a repeatable cached-frame penalty. An active redraw raised submit time in every round, by a median of 56.3 µs, and raised full-frame time by a median of 220.25 µs.

Each row is a separate process. All four states draw the same native scene and composite one identically sized textured quad. The cached case runs the application during warmup and reuses that result for every timed frame. The linked-but-unused case skips WebGPU device creation. The redrawn case writes a uniform, records and submits a textured WebGPU draw, polls the guest device, and samples the result natively. Its delta includes the application drawing, resource transition and extra submission. CPU-side time measures wall time through the native submit. Full-frame time also includes the fence wait. [Fresh measurements](lavapipe.tsv) · [Runner](measure.py)

### Earlier NVIDIA hardware measurements

Five rounds on an RTX 4060 Laptop, with 2,000 frames per run. Each cell gives the median in microseconds. Brackets show the range of the five per-run averages.

| Workload | CPU through submit | Full frame |
|---|---:|---:|
| Native UI alone | 12.6 | 47.7 [34.3–52.9] |
| wgpu-native UI alone | 24.5 | 60.7 [52.8–65.4] |
| WebGPU app alone | 19.7 | 51.7 [45.0–70.4] |
| WebGPU app with UI in its pass | 29.8 | 68.6 [62.5–81.1] |
| Native UI with a static custom-node texture | 11.1 | 40.0 [27.6–46.9] |
| Native UI with one WebGPU node redrawn | 35.1 | 67.1 [58.3–79.8] |

Pairing the last two rows within each round gives **+26.2 µs** through submit and **+30.7 µs** per full frame (full-frame range +27.1 to +32.9 µs). The app-in-pass and guest-node fixtures have different work and compositing order. The hardware runs cover one node, one resolution and a serialized frame loop. They cannot predict the cost per widget for a production window.

The historical TSV contains 120 rows, five rounds of twelve library/mode combinations on two drivers. Eleven rows started at a one-minute load of at least eight. Its columns are round, driver, implementation, mode, one-minute load, CPU through submit, full frame, thread CPU, app time and optional phase breakdown. Timing fields and wall/CPU phase pairs use microseconds. [Historical raw measurements](historical.tsv)

## Dependency decision

Keep the pinned patch on the research branch. The four C entry points import a native device, import an image, query creation requirements and transition a texture. Only the framework calls them. The patch uses internal wgpu APIs, assumes a feature chain for these adapters and has fatal error paths. A production version needs capability negotiation, recoverable errors and an ownership contract for shared handles, submissions and destruction. The pinned public C interface does not expose this Vulkan import path. [Pinned upstream header](https://github.com/gfx-rs/wgpu-native/blob/v29.0.1.1/ffi/wgpu.h) · [Research patch](wgpu-native.patch)

The Vulkan and Metal probes now run the same application callback. Each backend still needs its own verified resource-sharing and synchronization implementation. A software-only build can continue to omit the WebGPU dependency.

## Reproduce on Linux x86-64

Use the LCGR checkout containing this report, Cargo with libclang available to bindgen, and the pinned Zig. Start with an empty scratch directory. Only the experiment links this custom archive.

```sh
repo=$(pwd)
scratch=$(mktemp -d)
git clone https://github.com/gfx-rs/wgpu-native "$scratch/wgpu-native"
cd "$scratch/wgpu-native"
git checkout --detach 6aed50955d934ac36049ba8d002034841633ae02
git submodule update --init ffi/webgpu-headers
git apply "$repo/docs/research/custom-webgpu/wgpu-native.patch"
cargo build --release --locked --no-default-features --features vulkan,wgsl
mkdir -p "$scratch/include/webgpu"
cp ffi/wgpu.h ffi/webgpu-headers/webgpu.h "$scratch/include/webgpu/"
cd "$repo"
nix develop .#golden -c zig build custom-draw-probe -Doptimize=ReleaseFast \
  -Dguest-headers="$scratch/include" \
  -Dguest-library="$scratch/wgpu-native/target/release/libwgpu_native.a"
```

The v29 release archive headers and these two source headers were byte-identical. The included Cargo.lock patch permits a locked build. To build the matched standalone native target, omit `-Dguest-library`. A normal native application can use the existing LCGR Vulkan build.

Set `VK_DRIVER_FILES` to the intended driver's ICD JSON and make the Vulkan loader and Khronos validation layer discoverable. This run used `LP_NUM_THREADS=4` for lavapipe. Execute timing outside the validation environment.

```sh
export LP_NUM_THREADS=4
sh docs/research/custom-webgpu/validate.sh zig-out/bin/custom-draw-webgpu
python3 docs/research/custom-webgpu/measure.py zig-out/bin --rounds 10 > fresh.tsv
for name in native webgpu; do
    bin="zig-out/bin/custom-draw-$name"
    strip --strip-all -o "$scratch/$name.stripped" "$bin"
    wc -c "$scratch/$name.stripped"
    size -A "$bin"
    nm --defined-only "$bin" | awk '$3 ~ /^wgpu[A-Z]/ {n++} END {print n+0}'
done
```

## Metal follow-up

The Metal probe uses the same [application callback](../../../src/render/wgpu/custom_draw_sample.zig). It borrows the Metal device and texture exposed by stock wgpu-native v29. LCGF creates a second command queue on that device and draws the UI with its native Metal renderer. Before sampling a changed texture it waits for WebGPU submission completion. The probe also finishes each native frame before it allows the next write to that texture. A cached frame issues only Metal commands.

On macOS, `ci/run.sh metal-webgpu` in the development shell checks four colors, a patterned WGSL draw and its reuse against full native reference frames. It then times five alternating rounds of 200 frames in each state. These serialized timings include the CPU completion waits. The hosted job logs the Metal device, pixel result and per-round frame times. [Metal probe](../../../src/render/metal/probe_webgpu.zig)

On the hosted macOS runner, all six composed frames matched the native reference pixel for pixel. The device identified itself as `Apple Paravirtual device`. Each value below is the mean wall time per frame for 200 serialized frames. The median round took **1.07 ms cached** and **10.01 ms redrawn**. Physical Mac GPU performance and overlapping frames remain unmeasured. [macOS CI run and logs](https://github.com/OmarSiwy/LCGF/actions/runs/44203217905/job/134462447430)

| Round | Cached (µs) | Redrawn (µs) |
|---:|---:|---:|
| 1 | 1798.77 | 10661.83 |
| 2 | 1169.84 | 10418.92 |
| 3 | 1071.01 | 8348.32 |
| 4 | 916.99 | 10013.77 |
| 5 | 704.10 | 9723.94 |
