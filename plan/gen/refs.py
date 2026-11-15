# Reference keys used by the plan. "ours" = produced or cited earlier in this
# conversation; "spec" = authoritative external specification, new in this plan.
OURS = {
    # ---- delivered files
    "UI": ("ui.zig (delivered prototype, tested)", "file"),
    "WG": ("ui_wgpu.zig (delivered renderer tier, tested)", "file"),
    "EX": ("example.zig (delivered usage code and tests)", "file"),
    "API": ("API.md (generated index of public declarations)", "file"),
    "CT": ("comptime_ui_probe.zig (comptime UI probe, compiled on 0.17.1)", "file"),
    "MX": ("GUI framework targets matrix (sheet): Targets and Matrix tabs", "sheet"),
    "CHK": ("Checks run earlier: test matrix, branch census, benchmark, wgpu pixel check", "method"),
    # ---- frameworks and articles cited earlier
    "CLAY": ("Clay README: arena memory, bounded-pass layout, renderer-agnostic commands", "https://github.com/nicbarker/clay"),
    "SLINT": ("Slint README: compiled UI, property bindings, single memory region per component", "https://github.com/slint-ui/slint"),
    "SLINT_WGPU": ("Slint wgpu integration: rendering notifier, texture import, per-version modules", "https://docs.slint.dev/latest/docs/rust/slint/wgpu_28"),
    "SLINT_MCU": ("Slint blog: port to a microcontroller with 264K RAM", "https://slint.dev/blog"),
    "SLINT_A11Y": ("Slint issue 32: screen-reader support through AccessKit", "https://github.com/slint-ui/slint/issues/32"),
    "EGUI_CB": ("egui-wgpu CallbackTrait: prepare / finish_prepare / paint in the same pass", "https://docs.rs/egui-wgpu/latest/egui_wgpu/trait.CallbackTrait.html"),
    "EGUI": ("egui feature list (immediate mode, AccessKit)", "https://docs.rs/crate/egui/0.37.0"),
    "ICED_REL": ("Iced 0.14 release notes: reactive rendering, animation API, input method support", "https://github.com/iced-rs/iced/releases/tag/0.14.0"),
    "ICED_SHADER": ("Iced Shader widget: custom wgpu pipeline per widget", "https://docs.iced.rs/iced/widget/shader/index.html"),
    "ICED_FAQ": ("Iced FAQ: text and IME status", "https://book.iced.rs/faq.html"),
    "QT_NODE": ("Qt custom render node: the three ways to integrate custom rendering", "https://doc.qt.io/qt-6/qtquick-scenegraph-customrendernode-example.html"),
    "QT_UNDER": ("Qt RHI Under QML: underlay / overlay in the same pass", "https://doc.qt.io/QT-6/qtquick-scenegraph-rhiunderqml-example.html"),
    "QT_RENDERER": ("Qt scene graph renderer: batching, texture atlas, render thread", "https://doc.qt.io/qtforpython-6/overviews/qtquick-visualcanvas-scenegraph-renderer.html"),
    "LVGL": ("LVGL requirements: minimum flash and RAM", "https://docs.lvgl.io/9.5/introduction/requirements.html"),
    "GPUI": ("GPUI README: hybrid immediate / retained, entities, elements", "https://github.com/zed-industries/zed/blob/main/crates/gpui/README.md"),
    "ZED_WGPU": ("Zed commit: Linux renderer moved from Blade to wgpu (memory discussion)", "https://git.secluded.site/zed/commit/af8ea0d6c26192c45f44f473c0d4a7d6f72ed018"),
    "FLOEM": ("Floem README: signals over a view tree built once, virtual list, renderers", "https://github.com/lapce/floem"),
    "XILEM": ("Xilem / Masonry: view diff over retained widgets, passes over dirty subsets", "https://github.com/linebender/xilem"),
    "XILEM_VS": ("Xilem virtual_scroll view", "https://docs.rs/crate/xilem/latest/source/src/view/virtual_scroll.rs"),
    "MAKEPAD": ("Makepad docs: shader-styled widgets, live DSL", "https://publish.obsidian.md/makepad-docs"),
    "DIOXUS": ("Dioxus Native / Blitz: features incl. accessibility", "https://docs.rs/crate/dioxus-native/0.7.7"),
    "DVUI": ("DVUI: Zig immediate-mode GUI, backends, AccessKit", "https://github.com/david-vanderson/dvui"),
    "IMGUI_IDLE": ("Dear ImGui wiki: implementing power save / idling", "https://github.com/ocornut/imgui/wiki/Implementing-Power-Save%2C-aka-Idling-outside-of-ImGui"),
    "FTW": ("Proving Immediate Mode GUIs are Performant (power measurements)", "https://www.forrestthewoods.com/blog/proving-immediate-mode-guis-are-performant/"),
    "DEVTO": ("135 MB to 30 MB by dropping the GPU renderer (where GUI memory goes)", "https://dev.to/trystan_sarrade/how-i-took-my-rust-gui-from-135-mb-to-30-mb-by-ditching-the-gpu-2i7d"),
    "ACCESSKIT": ("AccessKit: accessibility infrastructure for UI toolkits", "https://github.com/AccessKit/accesskit"),
    "ZIG17": ("Zig 0.17 upgrade guide: breaking changes", "https://blog.codercops.com/blog/zig-0-17-upgrade-guide-breaking-changes-2026"),
    "ZIG17_NOTES": ("Zig 0.17.0 release notes summary", "https://daily.dev/posts/zig-0-17-0-release-notes-y2kcmyvvv"),
    "ZIG17_BUILD": ("Zig 0.17 build system: configurer / maker split", "https://dispatch-blog.hashnode.dev/zig-0-17-split-its-build-into-two-processes-why-that-matters"),
    "ZIG_VEC": ("Ziggit: @Vector rules in 0.17", "https://ziggit.dev/t/vector-abuse/17854"),
    "GOMPUTE": ("Gompute README: Zig GPU kernels compiled to PTX / HSACO, CPU fallback", "https://github.com/OmarSiwy/Gompute"),
    "CUDA_INTEROP": ("CUDA programming guide: graphics interoperability", "https://docs.nvidia.com/cuda/cuda-programming-guide/04-special-topics/graphics-interop.html"),
    "CUDARASTER": ("Laine and Karras 2011: High-Performance Software Rasterization on GPUs", "https://diglib.eg.org/handle/10.2312/14912"),
    # ---- sources listed by the two design skills used earlier
    "CASEY_API": ("Casey Muratori: Designing and Evaluating Reusable Components (granularity, redundancy, coupling, retention, flow control)", "caseymuratori.com/blog_0024"),
    "CASEY_COMP": ("Casey Muratori: Semantic Compression", "caseymuratori.com/blog_0015"),
    "CASEY_CLEAN": ("Casey Muratori: Clean Code, Horrible Performance", "computerenhance.com"),
    "KELLEY_DOD": ("Andrew Kelley: Practical Data-Oriented Design (talk)", "talk"),
    "FABIAN": ("Richard Fabian: Data-Oriented Design (book)", "dataorienteddesign.com"),
    "ACTON": ("Mike Acton: Data-Oriented Design and C++ (CppCon 2014)", "talk"),
}

SPEC = {
    "UAX9": ("Unicode Bidirectional Algorithm (UAX 9)", "https://www.unicode.org/reports/tr9/"),
    "UAX14": ("Unicode Line Breaking Algorithm (UAX 14)", "https://www.unicode.org/reports/tr14/"),
    "UAX29": ("Unicode Text Segmentation (UAX 29)", "https://www.unicode.org/reports/tr29/"),
    "OT": ("OpenType specification", "https://learn.microsoft.com/typography/opentype/spec/"),
    "WGSL": ("WGSL specification", "https://www.w3.org/TR/WGSL/"),
    "WEBGPU": ("WebGPU specification", "https://www.w3.org/TR/webgpu/"),
    "VK": ("Vulkan specification and registry", "https://registry.khronos.org/vulkan/"),
    "APG": ("WAI-ARIA Authoring Practices: widget keyboard and role patterns", "https://www.w3.org/WAI/ARIA/apg/"),
    "WAYLAND": ("Wayland protocol documentation", "https://wayland.freedesktop.org/"),
    "XCB": ("XCB documentation", "https://xcb.freedesktop.org/"),
    "WIN32": ("Win32 API documentation (windowing, input, IMM/TSF)", "learn.microsoft.com"),
    "D3D12": ("Direct3D 12 and DXGI documentation", "learn.microsoft.com"),
    "APPKIT": ("AppKit / Core Text / Metal documentation", "developer.apple.com"),
    "UIKIT": ("UIKit documentation", "developer.apple.com"),
    "NDK": ("Android NDK documentation", "developer.android.com"),
    "GLES": ("OpenGL ES 3.0 and EGL specifications", "https://registry.khronos.org/"),
    "PD": ("Porter and Duff 1984: Compositing Digital Images", "paper"),
    "CSS_FLEX": ("CSS Flexible Box Layout (as a behaviour reference, not a compatibility goal)", "https://www.w3.org/TR/css-flexbox-1/"),
    "CSS_GRID": ("CSS Grid Layout (as a behaviour reference)", "https://www.w3.org/TR/css-grid-1/"),
    "UIA": ("Microsoft UI Automation documentation", "learn.microsoft.com"),
    "ATSPI": ("AT-SPI2 documentation", "freedesktop.org"),
    "PNG": ("PNG specification", "https://www.w3.org/TR/png/"),
    "TINYVG": ("TinyVG specification", "tinyvg.tech"),
}


def ours(key, where=""):
    name = OURS[key][0].split(":")[0].split(" (")[0]
    return f"{name}: {where}" if where else name


def spec(key, where=""):
    name = SPEC[key][0].split(":")[0].split(" (")[0]
    return f"{name}: {where}" if where else name
