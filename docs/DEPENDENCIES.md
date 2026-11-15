# Dependencies

The core (tiers 0 to 2) needs the Zig 0.17.1 toolchain and three namespaces of its standard library. Everything else is optional and belongs to one back end, one shell or CI.
Adding a dependency that is not in this table is a design change: raise it, do not just add it.

| Dependency | Kind | Needed by | Required? | Why | Note or alternative |
|---|---|---|---|---|---|
| Zig 0.17.1 toolchain | Toolchain | Everything | Required | Compiler, build system, test runner, cross-compilation. | Gompute's current head needs a Zig 0.18 development build; its last 0.17 build is commit abd75e4. |
| Zig standard library (simd, math, mem only) | Source | Core: tiers 0 to 2 | Required | Vector width query, integer helpers, slices. No libc, no allocator, no I/O. | The embedded profile removes the remaining uses that need an OS. |
| C header translation package | Build time | Back ends that call C APIs: Vulkan, Wayland, X11, wgpu-native, AccessKit, HarfBuzz | Optional | Zig 0.17 removed @cImport, so C headers are translated in the build. | For small APIs, hand-written extern declarations avoid it. |
| Shader translator (for example naga) | Build time | Renderers other than wgpu and web | Optional | Produces SPIR-V, MSL, HLSL and GLSL from the single WGSL source. | The quad shader is small enough to maintain by hand per back end. |
| Unicode Character Database files | Build data | Text: segmentation, line breaking, bidi | Optional | Property tables are generated at compile time from the data files. | Not needed by UIs that use the fixed-advance font only. |
| A test font with an open licence | Test data | Text tests and examples | Optional | Parser, rasteriser and shaping tests need a real font. |  |
| Vulkan loader and a driver | System, run time | render-vk | Optional | Thin GPU path on Linux, Windows and Android. | Software drivers (lavapipe) cover CI. |
| Metal, QuartzCore, AppKit, Core Text | System, run time | render-metal, shell-macos, font fallback | Optional | Native GPU, windowing and font discovery on macOS. | Reached through the Objective-C runtime; no extra library. |
| Direct3D 12, DXGI, user32, imm32, DirectWrite | System, run time | render-d3d12, shell-win32, font fallback | Optional | Native GPU, windowing, IME and font discovery on Windows. | WARP covers CI. |
| libwayland-client, xkbcommon | System, run time | shell-wayland | Optional | Wayland connection and keyboard maps. |  |
| libxcb, xkbcommon-x11 | System, run time | shell-x11 | Optional | X11 connection and keyboard maps. |  |
| EGL and OpenGL ES | System, run time | render-gles | Optional | GPU path for small Linux devices and older Android. |  |
| Browser WebGPU or 2D canvas | Platform | render-web, shell-web | Optional | Drawing and events in the browser. |  |
| Android NDK, iOS SDK | Build time | shell-android, shell-ios | Optional | Mobile shells. |  |
| wgpu-native | Library, run time | render-wgpu | Optional | One portable GPU back end; the route to raw wgpu access. | Costs baseline memory compared with a native back end; measured in lane render-vk. |
| Gompute plus a CUDA or HIP driver | Library, run time | render-gompute (experimental) | Optional | Compute kernels in Zig for offscreen rendering and heavy effects; the same kernels run on the CPU. | Cannot present to a window by itself; needs read-back or interop with a graphics API. |
| AccessKit (C interface) | Library, run time | a11y-bridge | Optional | Bridges the semantic tree to UI Automation, NSAccessibility and AT-SPI. | Alternative: write the three platform adapters by hand. |
| HarfBuzz | Library, run time | shaping (adapter) | Optional | Complex-script shaping beyond the built-in simple shaper. | Plugs into the same measure / wrap data protocol. |
| fontconfig | System, run time | font-fallback on Linux | Optional | System font discovery. |  |
| Platform text input services | System, run time | text-edit, shells | Optional | IME on each platform. | Text Services Framework, NSTextInputClient, Wayland text-input, IBus or Fcitx. |
| Software GPU drivers (llvmpipe, lavapipe, WARP) | CI | Renderer conformance tests | CI only | Pixel tests without hardware. | The earlier pixel check ran on llvmpipe. |
| A scriptable wgpu host (for example wgpu-py) | CI | tools-golden | CI only | Draws dumped frames and reads pixels back. | Used for the earlier shader and layout check. |
| objdump | CI | tools-census | CI only | Counts conditional jumps in hot loops. |  |
| OS performance counters (perf or equivalent) | CI | tools-bench, optimise | CI only | Cache misses, wakeups, resident memory. |  |
| Clay, Dear ImGui, egui, Slint, LVGL, Iced, Qt Quick | Comparison only | vs-* lanes, gates | CI only | The same scenes are measured on each; never linked into the product. |  |
