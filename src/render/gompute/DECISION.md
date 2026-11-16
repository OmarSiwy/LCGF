# Gompute back end: decision record

The Gompute back end is optional and experimental (docs/DESIGN.md): CUDA and HIP compute kernels
written in Zig, for offscreen effects shown as textures, never a replacement for a graphics back
end. This file records each step of lane render-gompute with what was measured. Machine for every
number: x86_64 Linux (NixOS), RTX 4060 Laptop GPU (sm_89) with driver 595.71.05, no AMD GPU, Zig
0.18.0-dev.1151+8dfb7a7cc.

Decision (C0425, last section): keep it as an optional offscreen and heavy-effects back end.

## C0418: pin a Gompute revision that builds with the project's Zig

Decision: pin Gompute 1.0.0 at commit 37432b2 (branch zig-0.18.0-dev.1151, the owner's PR #9) as
a lazy build.zig.zon dependency, fetched only for `zig build gompute`. abd75e4 was its last Zig 0.17
build and the 1.x heads before 37432b2 need 0.18.0-dev.349, which this project does not use.

Device targets are pinned, not left at Gompute's `.auto` (which runs `nvidia-smi` on the build
machine and silently compiles a backend out when it finds no GPU): CUDA as sm_75 PTX (any Turing
or newer card JITs it; no `ptxas` needed, `.sass = false`), HIP as gfx1100 HSACO, compile-only
here because this machine has no AMD GPU.

Measured:

| What | Value |
|---|---|
| Package archive / unpacked | 151 KB / 596 KB, no dependencies of its own |
| Cold `zig build gompute` (fresh cache dir) | 2.96 s wall, 214 MB peak RSS |
| PTX object (nvptx64-cuda, sm_75) | 53 ms |
| HSACO object (amdgcn-amdhsa, gfx1100) | 63 ms, 3.4 KB |
| `fill` test | passes on the CPU path and on CUDA (RTX 4060): the same 1,000 pixels |

One build fix was needed on our side: a kernel's per-thread function takes `g.GlobalPtr(T)`
(a plain `[*]T` on the host, a global-address-space pointer on the device) instead of a slice
made with `@addrSpaceCast`, which LLVM 23 rejected on nvptx64 ("Invalid cast" in bitcode).

## C0419: express the tile rasteriser as kernels that also run on the CPU

Decision: two kernels, `bin` (one thread per 16x16 tile: the indices of the quads whose pixel box
meets the tile, in paint order) and `raster` (one thread per pixel: its tile's quads shaded and
blended over the pixel in order), Laine and Karras's binning and fine rasterisation without the
triangle stages a GUI does not need. Each is a plain Zig function in kernels.zig; the CPU path
(`rasterCpu`) calls it once per tile and once per pixel, the device entry points once per thread.
The per-pixel shading is sw.zig `shade`'s loop body for one lane, expression for expression, with
Gompute's device math (`g.math.exp`, `sin`, `cos`) where the GPU has no libm.

The back end meets the render contract by recording: `drawBatch` and `drawText` append quads and
their texture to a caller-owned `Recorder` (the pass); the host rasterises at each custom command
and at the end, so paint order holds across its own draws. Bins have a fixed capacity; a full bin
makes its pixels walk every quad of the frame instead (slower, never wrong), and the test runs every
scene at a capacity of 2 (overflows) and 16 (does not).

Measured:

| What | Value |
|---|---|
| Conformance scenes, CPU path vs software back end | identical pixels (test `raster: every conformance scene ...`, capacities 2 and 16) |
| `ci/run.sh gompute-golden` | 13 of 13 golden images (4 conformance, 9 draw-feature: borders, corners, gradients, images, nine-slice, opacity, rounded-clip, shadows, transforms), 0 pixels off by more than 2 |
| PTX / HSACO compile of the rasteriser | 0.67 s / 2 s |

CPU time per frame, median of 15, gompute-play ReleaseFast, on a machine shared with other builds
(numbers move by about 30% between runs):

| Scene | Size, quads | CPU path | sw | CPU path / sw |
|---|---|---|---|---|
| rects | 160x120, 3 | 3,107 us | 254 us | 12x |
| text | 160x120, 10 | 2,829 us | 91 us | 31x |
| borders | 800x600, 4 | 11,432 us | 2,262 us | 5x |
| opacity | 800x600, 20 | 20,153 us | 1,678 us | 12x |
| rounded-clip | 800x600, 7 | 41,586 us | 1,031 us | 40x |
| shadows | 800x600, 7 | 58,383 us | 3,429 us | 17x |

The CPU path is a correctness fallback, not a renderer: one scalar thread, every pixel of the
frame visited, the per-quad setup recomputed per pixel (what a GPU thread does). The software back
end shades only each quad's box, `simd.lanes` pixels at a time. Where there is no GPU, use sw.

## C0420: launch the kernels on CUDA and HIP

Decision: `Device(backend)` is generic over Gompute's `.cuda` and `.hip`; it owns the device
buffers it creates (quads, their textures, the image table and texels, the bins, the framebuffer),
sized once by a `Capacity`, and the host keeps the loop: `clear`, `draw` (upload the recorded quads,
queue `bin` then `raster`), `download`, `upload`. `init` fails with `error.InitFailed` or
`error.NoDevice` where there is no driver or card, and the caller takes another path. An inline
custom draw done on the CPU costs a read-back and an upload between the two GPU segments; the
`custom` scene checks that route.

HIP is compile-only: the gfx1100 HSACO is built and `Device(.hip)` is analysed by the test, but this
machine has no AMD card, so nothing ran on HIP.

Measured:

| What | Value |
|---|---|
| CUDA against the CPU path, every conformance scene (bin capacity 4) | bit-identical framebuffers (test `device: CUDA draws ...`) |
| `ci/run.sh gompute-golden`, CPU and CUDA | 26 of 26 golden images, 0 pixels off by more than 2 |

Time per frame on the RTX 4060 (gompute-play ReleaseFast, median of 15, from the clear to the GPU
being done, including the quad upload and three launches, without the read-back), against the
software back end on one CPU core of the same machine:

| Scene | Size, quads | CUDA | sw | sw / CUDA |
|---|---|---|---|---|
| rects | 160x120, 3 | 29 us | 101 us | 3.5x |
| text | 160x120, 10 | 40 us | 99 us | 2.5x |
| custom (read-back and upload in the middle) | 160x120, 2 | 185 us | 227 us | 1.2x |
| borders | 800x600, 4 | 68 us | 948 us | 14x |
| opacity | 800x600, 20 | 138 us | 1,810 us | 13x |
| rounded-clip | 800x600, 7 | 188 us | 1,109 us | 6x |
| shadows | 800x600, 7 | 204 us | 3,562 us | 17x |
| transforms | 800x600, 8 | 90 us | 3,151 us | 35x |

At 160x120 the fixed cost of three launches and a synchronisation (about 25 us) is most of the frame.

## C0421: present by reading back to a CPU framebuffer

Decision: `Device.present(fb)` waits for the queued work and copies the frame into a software back
end framebuffer (`sw.Framebuffer`), which a shell then presents exactly as it presents the software
back end's frames. CUDA has no presentation of its own, so this is the route that works with every
shell and no graphics API. Read-back into pinned memory is the fast case; the framebuffer's
memory stays the caller's (`raster_k.allocPinned` gives pinned pixels for `sw.Framebuffer.init`).

Measured (`gompute-probe readback`, ci/jobs/gompute-probe.sh, median of 50 read-backs of a
cleared frame, two runs on a busy machine):

| Size | Bytes | Pageable memory | Pinned memory |
|---|---|---|---|
| 800x600 | 1.9 MB | 265 to 367 us (5 to 7 GB/s) | 150 to 296 us (6.5 to 12.8 GB/s) |
| 1920x1080 | 8.3 MB | 869 to 1,346 us | 634 to 1,263 us (13 GB/s at best) |
| 3840x2160 | 33.2 MB | 5,128 to 5,592 us | 2,522 to 2,526 us (13.2 GB/s) |

Test `present: CUDA's frame read back into a software framebuffer is the software back end's
frame` draws the `rects` scene in BGRA8 and compares every pixel with sw's.

At 800x600 a read-back costs about as much as drawing the frame on the GPU (C0420: 68 to 204 us),
so the whole frame (draw plus read-back, roughly 0.25 to 0.5 ms) is still 2 to 10 times below sw
on one core for these scenes, but read-back grows with pixels, not with content: at 4K it is 2.5 ms
per frame before anything is drawn, which a 60 Hz budget can afford once and a 144 Hz one barely.

## C0422: present through Vulkan external memory where available

Decision: where the GPU's Vulkan driver exports memory (VK_KHR_external_memory_fd) and CUDA can
import it, Vulkan allocates the framebuffer, CUDA maps it (cuImportExternalMemory,
cuExternalMemoryGetMappedBuffer) and the kernels draw straight into it (`Capacity.framebuffer`);
Vulkan then copies it into an image that the Vulkan back end samples like any texture (route 3 of
src/render/iface.zig), or that a host copies to a swapchain image. No pixel crosses to the host.
Elsewhere (no Vulkan, a driver without the extension, HIP) the read-back of C0421 stays.

Built over the Vulkan back end's public device code without editing it: `vulkan.device` creates a
`vk.device.Device` the way `Device.init` does, plus the one extension (`Device.init` takes no
extension list). Synchronisation is the simple kind (the host waits for CUDA, then for the copy);
external semaphores would let the queues overlap. The device is the one `vk.device.pick` prefers;
matching it to CUDA's by UUID is left for a machine with two GPUs.

Measured on the RTX 4060 with the NVIDIA Vulkan driver (`ci/run.sh gompute-vk`, golden shell with
the NVIDIA ICD instead of lavapipe):

| What | Value |
|---|---|
| Test `vulkan: CUDA draws into Vulkan memory, Vulkan copies it into an image, the pixels are the CPU path's` | passes: `rects` and `clip`, every byte read back from the Vulkan image equals the CPU path's |
| Hand-over, 800x600 (GPU done to image ready: record, submit, wait; median of 50, two runs) | 145 to 149 us |
| Hand-over, 1920x1080 | 266 to 296 us |
| Hand-over, 3840x2160 | 823 to 930 us |

Against the read-back of C0421 (pinned memory): equal at 800x600 (150 to 296 us), 2 to 4 times
cheaper at 1080p (634 to 1,263 us) and about 3 times at 4K (2,522 us). About 100 us of each
hand-over is the submit-and-wait round trip, not the copy; a frame that the Vulkan back end goes
on to draw anyway would put the copy in its own command buffer and pay none of it.

## C0423: measure context memory and start-up against Vulkan

Measured on the RTX 4060, both back ends ReleaseFast on the same GPU (Vulkan through the NVIDIA
driver, not lavapipe), `ci/run.sh gompute-startup`. Start-up is the wall time from spawning the
probe to its ready line, median of 5, three sessions; GPU memory is what nvidia-smi attributes to the
process.

| | Gompute (CUDA) | Vulkan back end | Gompute - Vulkan |
|---|---|---|---|
| Driver and context only: start-up | 169 to 252 ms | 175 to 186 ms | about the same |
| Driver and context only: resident memory | 95.5 MiB | 61.9 MiB | +33.6 MiB |
| Driver and context only: GPU memory | 96 MiB | 3 MiB | +93 MiB |
| Empty 800x600 frame: start-up | 206 to 225 ms | 173 to 214 ms | 0 to +50 ms |
| Empty 800x600 frame: resident memory | 97.5 MiB | 76.5 MiB | +21 MiB |
| Empty 800x600 frame: GPU memory | 104 MiB | 8 MiB | +96 MiB |
| Idle wake-ups after the empty frame (probe.py, 2 s) | 31.5 to 81.5 /s | 134 to 135 /s | both nonzero: driver threads |
| Driver and context, PTX JIT cache disabled (`CUDA_CACHE_DISABLE=1`) | 789 to 929 ms, 136.8 MiB resident | | |

What these say: a CUDA context costs about 93 MiB of GPU memory before any buffer (the driver's
own per-context reservations; not broken down here), 30 times what a Vulkan device costs, and 34 MiB more resident host memory. Start-up is the same order
as Vulkan's (both are dominated by loading the NVIDIA driver) as long as the driver's JIT cache
already holds the kernels: the PTX is built for sm_75 and JIT-compiled for this sm_89 card on first
use, about 0.7 s more when the cache is cold. Embedding SASS for the target cards (Gompute's
`.sass = true`, which needs `ptxas` at build time) would remove that, at the cost of a toolkit
dependency in the build.

For an application that already runs Vulkan, enabling Gompute adds a second driver context: the
+93 MiB of GPU memory and +34 MiB resident are the price of the back end on top of the Vulkan one,
which is the comparison the decision (C0425) has to weigh against what the kernels buy.

## C0424: measure frame time against the software and Vulkan back ends

The benchmark scene of docs/CHECKS.md section 3 (bench/scenes/rows.zig, 330 rows; its first frame
laid out for a 1280x720 window: 116 quads, 1,320 text runs, 8,910 glyph quads, 152 commands), drawn
by each back end from the same draw list, ReleaseFast, median of 300 frames after 20 warm-up
frames, three runs (`gompute-bench-frame`, ci/jobs/gompute-vk.sh):

| Back end | Per frame | Against Vulkan |
|---|---|---|
| sw, one CPU core (clear, then draw) | 4,714 to 5,132 us | 12 to 34x |
| Gompute on CUDA (record, clear, upload, bin, raster, GPU done) | 730 to 733 us | 1.8 to 4.8x |
| Gompute on CUDA, with read-back into pinned memory | 830 to 835 us | 2 to 5.5x |
| Vulkan back end on the same GPU (prepare, record, submit, GPU done) | 151 to 410 us | 1x |

The Vulkan numbers move with the laptop GPU's clocks between runs (151 us in one, 404 to 410 in the
two after); Gompute's did not move (why was not measured). On the four 160x120 conformance scenes the order is reversed: Gompute
29 to 40 us per frame (C0420) against 45 to 52 us for the Vulkan back end (vk-probe `scenes` on
the NVIDIA driver), where both are launch and submission overhead.

Read against Laine and Karras (a compute rasteriser within 2 to 8 times of the hardware), the
tile rasteriser lands at 1.8 to 4.8 times the hardware path on a real GUI frame, inside their range,
and 6 to 7 times faster than the software back end on one core. The binning kernel is the simple
kind (every tile walks every quad: 3,600 tiles times 9,026 quads here); per-quad coarse binning, as
Laine and Karras do it, is where the remaining gap would be attacked. Not measured: the split of the
730 us between `bin` and `raster`, and a multithreaded software back end (sw draws tile bands on
threads, `sw.tile`).

## C0425: the decision

**Keep Gompute, as an optional offscreen and heavy-effects back end; not as a presenting renderer
and not as a replacement for any graphics back end.** It stays out of lcgr.zig, behind the lazy
`zig build gompute` steps, and nothing else depends on it.

Why keep it, from the numbers above:

- It is correct, and cheaply so: one kernel source gives bit-identical framebuffers on the CPU
  and on CUDA (C0420), matches the software back end pixel for pixel on the conformance scenes
  (C0419), and passes all 26 golden images on both paths. The kernels are the stock shader's
  math, so every draw feature works.
- It is fast where the software back end is not: 6 to 7 times sw on one core for the benchmark
  scene at 1280x720 (C0424), 6 to 35 times on the 800x600 draw-feature scenes, shadows and
  rounded clips included (C0420). That is what an offscreen or effects pass needs.
- Its output reaches the screen without the host where Vulkan exports memory: the frame becomes a
  Vulkan texture in 134 to 164 us at 800x600 and under 1 ms at 4K (C0422), so the "texture" route
  of iface.zig shows Gompute output as an ordinary node.

Why not more than that:

- The hardware path is faster: the Vulkan back end draws the same frame in 151 to 410 us against
  Gompute's 730 (1.8 to 4.8 times, inside Laine and Karras's 2 to 8; C0424). A compute rasteriser
  gives up the fixed-function hardware a GUI uses most, as docs/DESIGN.md expected.
- It costs a second driver context: +93 MiB of GPU memory and +34 MiB resident against a Vulkan
  device, and about 0.7 s more start-up when the driver's JIT cache is cold (C0423). An application
  that does not already use CUDA pays that for nothing a graphics back end cannot do.
- It cannot present by itself (C0421): the read-back is 0.15 to 0.3 ms at 800x600 but 2.5 ms at 4K,
  and grows with pixels, not with what is drawn.
- Two vendors, one verified: HIP builds (gfx1100 HSACO) but has never run; there is no AMD card here.

When to use it: an application that already holds a CUDA context (simulation, ML, video), to
draw offscreen UI or heavy effects (large blurs, shadows, many gradients) into memory it then shows
through the Vulkan back end as a texture, or reads back where there is no Vulkan. When not: as the
renderer of an ordinary window, where Vulkan, Metal, D3D12, GL ES, web or wgpu do it faster and
smaller, and sw does it with no GPU at all.

Revisit (drop it) if HIP still has not run on hardware when the lane is next touched, or if the
Gompute pin falls behind the project's Zig again. Improve it, if kept and used: per-quad coarse
binning (the bin kernel walks every quad per tile), external semaphores instead of host waits
(C0422), and embedded SASS to remove the cold-cache JIT (C0423).
