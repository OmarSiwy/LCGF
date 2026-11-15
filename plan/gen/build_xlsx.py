import json, os
HERE = os.path.dirname(os.path.abspath(__file__))
from collections import Counter, defaultdict
from openpyxl import Workbook
from openpyxl.styles import PatternFill, Alignment
from openpyxl.utils import get_column_letter as L
from refs import OURS, SPEC

P = json.load(open(os.path.join(HERE, "generated.json")))
commits, phases, lanes = P["commits"], P["phases"], P["lanes"]
HDR = PatternFill("solid", fgColor="F3F3F3")
WRAP = Alignment(wrap_text=True, vertical="top")
wb = Workbook()


def table(ws, header, rows, widths, wrap_cols=()):
    ws.append(header)
    for r in rows:
        ws.append(r)
    for i, w in enumerate(widths, 1):
        ws.column_dimensions[L(i)].width = w
    for c in range(1, len(header) + 1):
        ws.cell(row=ws.max_row - len(rows), column=c).fill = HDR
    first = ws.max_row - len(rows) + 1
    for rn in range(first, ws.max_row + 1):
        for c in wrap_cols:
            ws.cell(row=rn, column=c).alignment = WRAP


by_phase = defaultdict(list)
for c in commits:
    by_phase[c["phase"]].append(c)
last_wave = max(c["wave"] for c in commits)
wave_count = Counter(c["wave"] for c in commits)

# ---------------------------------------------------------------- Overview
ws = wb.active
ws.title = "Overview"
facts = [
    ("Commits", len(commits)),
    ("Lanes (sequential tracks)", len(lanes)),
    ("Waves (longest dependency chain)", last_wave),
    ("Widest wave (commits that can run at once)", max(wave_count.values())),
    ("Commits on the critical path", sum(c["critical"] for c in commits)),
    ("How to read", "A commit can start when every commit in its Depends on column is merged. Commits in the same wave do not depend on each other and can be done in parallel. Inside a lane, commits are sequential."),
    ("Wave", "1 + the longest chain of prerequisites. It is the earliest step at which the commit can start, not a calendar estimate."),
    ("Critical", "Yes when the commit lies on a longest chain: delaying it delays the last commit."),
    ("Look at", "Where to read before writing the commit, taken from the files delivered and the sources cited earlier in this conversation. The References tab maps every name to its file or address."),
    ("Spec (new)", "An authoritative specification that the earlier sources do not cover. New in this plan."),
    ("Targets", "The target ids of the GUI framework targets matrix (A1 to H3) that the commit advances."),
    ("Starting point", "ui.zig, ui_wgpu.zig, example.zig and comptime_ui_probe.zig exist and pass their tests on Zig 0.17.1. Commits that cite them start as ports; everything else is new work."),
    ("Caveat", "The first few hundred commits follow code that exists. The further down the plan, the more the order and split will change once measurements come in. Gates, not this list, define done."),
]
for k, v in facts:
    ws.append([k, v])
    ws.cell(row=ws.max_row, column=2).alignment = WRAP
ws.append([None, None])
rows = []
for p in sorted(phases):
    cs = by_phase[p]
    ls = sorted({c["lane"] for c in cs})
    rows.append([p, phases[p][0], len(cs), min(c["wave"] for c in cs), max(c["wave"] for c in cs), len(ls), phases[p][1]])
table(ws, ["Phase", "Name", "Commits", "First wave", "Last wave", "Lanes", "What it delivers"], rows, [34, 78, 10, 11, 10, 8, 80], wrap_cols=(7,))

# ---------------------------------------------------------------- Commits
wc = wb.create_sheet("Commits")
rows = []
for c in commits:
    rows.append([
        c["id"], c["title"], c["wave"], ", ".join(c["deps"]) if c["deps"] else "none (can start now)",
        c["ref"], c["done"], c["lane"], f'{c["phase"]} {phases[c["phase"]][0]}', c["spec"] or None,
        c["tg"] or None, "Yes" if c["critical"] else "No", c["unblocks"], "To do",
    ])
table(wc, ["ID", "Commit", "Wave", "Depends on", "Look at (our sources)", "Done when", "Lane", "Phase", "Spec (new)", "Targets", "Critical", "Unblocks", "Status"],
      rows, [8, 62, 7, 22, 58, 44, 20, 30, 40, 9, 9, 10, 10], wrap_cols=(2, 4, 5, 6, 9))
wc.freeze_panes = "C2"

# ---------------------------------------------------------------- Lanes
wl = wb.create_sheet("Lanes")
ids = {c["id"]: c for c in commits}
rows = []
for ln in lanes:
    cs = [c for c in commits if c["lane"] == ln["name"]]
    pre = sorted({ids[d]["lane"] for d in cs[0]["deps"]})
    rows.append([ln["name"], f'{ln["phase"]} {phases[ln["phase"]][0]}', len(cs), cs[0]["id"], cs[-1]["id"],
                 min(c["wave"] for c in cs), max(c["wave"] for c in cs), ", ".join(pre) if pre else "none",
                 "Yes" if any(c["critical"] for c in cs) else "No"])
table(wl, ["Lane", "Phase", "Commits", "First commit", "Last commit", "Starts in wave", "Ends in wave", "Waits for lanes", "On critical path"],
      rows, [22, 34, 10, 12, 12, 14, 13, 60, 15], wrap_cols=(8,))

# ---------------------------------------------------------------- Waves
ww = wb.create_sheet("Waves")
rows = []
for w in range(1, last_wave + 1):
    cs = [c for c in commits if c["wave"] == w]
    rows.append([w, len(cs), len({c["lane"] for c in cs}), ", ".join(sorted({c["phase"] for c in cs})), cs[0]["id"] if len(cs) == 1 else f'{cs[0]["id"]} and {len(cs) - 1} more'])
table(ww, ["Wave", "Commits in parallel", "Lanes active", "Phases", "Commits"], rows, [8, 18, 13, 60, 24], wrap_cols=(4,))

# ---------------------------------------------------------------- Dependencies
wd = wb.create_sheet("Dependencies")
deps = [
    ("Zig 0.17.1 toolchain", "Toolchain", "Everything", "Required", "Compiler, build system, test runner, cross-compilation.", "Gompute's current head needs a Zig 0.18 development build; its last 0.17 build is commit abd75e4."),
    ("Zig standard library (simd, math, mem only)", "Source", "Core: tiers 0 to 2", "Required", "Vector width query, integer helpers, slices. No libc, no allocator, no I/O.", "The embedded profile removes the remaining uses that need an OS."),
    ("C header translation package", "Build time", "Back ends that call C APIs: Vulkan, Wayland, X11, wgpu-native, AccessKit, HarfBuzz", "Optional", "Zig 0.17 removed @cImport, so C headers are translated in the build.", "For small APIs, hand-written extern declarations avoid it."),
    ("Shader translator (for example naga)", "Build time", "Renderers other than wgpu and web", "Optional", "Produces SPIR-V, MSL, HLSL and GLSL from the single WGSL source.", "The quad shader is small enough to maintain by hand per back end."),
    ("Unicode Character Database files", "Build data", "Text: segmentation, line breaking, bidi", "Optional", "Property tables are generated at compile time from the data files.", "Not needed by UIs that use the fixed-advance font only."),
    ("A test font with an open licence", "Test data", "Text tests and examples", "Optional", "Parser, rasteriser and shaping tests need a real font.", ""),
    ("Vulkan loader and a driver", "System, run time", "render-vk", "Optional", "Thin GPU path on Linux, Windows and Android.", "Software drivers (lavapipe) cover CI."),
    ("Metal, QuartzCore, AppKit, Core Text", "System, run time", "render-metal, shell-macos, font fallback", "Optional", "Native GPU, windowing and font discovery on macOS.", "Reached through the Objective-C runtime; no extra library."),
    ("Direct3D 12, DXGI, user32, imm32, DirectWrite", "System, run time", "render-d3d12, shell-win32, font fallback", "Optional", "Native GPU, windowing, IME and font discovery on Windows.", "WARP covers CI."),
    ("libwayland-client, xkbcommon", "System, run time", "shell-wayland", "Optional", "Wayland connection and keyboard maps.", ""),
    ("libxcb, xkbcommon-x11", "System, run time", "shell-x11", "Optional", "X11 connection and keyboard maps.", ""),
    ("EGL and OpenGL ES", "System, run time", "render-gles", "Optional", "GPU path for small Linux devices and older Android.", ""),
    ("Browser WebGPU or 2D canvas", "Platform", "render-web, shell-web", "Optional", "Drawing and events in the browser.", ""),
    ("Android NDK, iOS SDK", "Build time", "shell-android, shell-ios", "Optional", "Mobile shells.", ""),
    ("wgpu-native", "Library, run time", "render-wgpu", "Optional", "One portable GPU back end; the route to raw wgpu access.", "Costs baseline memory compared with a native back end; measured in lane render-vk."),
    ("Gompute plus a CUDA or HIP driver", "Library, run time", "render-gompute (experimental)", "Optional", "Compute kernels in Zig for offscreen rendering and heavy effects; the same kernels run on the CPU.", "Cannot present to a window by itself; needs read-back or interop with a graphics API."),
    ("AccessKit (C interface)", "Library, run time", "a11y-bridge", "Optional", "Bridges the semantic tree to UI Automation, NSAccessibility and AT-SPI.", "Alternative: write the three platform adapters by hand."),
    ("HarfBuzz", "Library, run time", "shaping (adapter)", "Optional", "Complex-script shaping beyond the built-in simple shaper.", "Plugs into the same measure / wrap data protocol."),
    ("fontconfig", "System, run time", "font-fallback on Linux", "Optional", "System font discovery.", ""),
    ("Platform text input services", "System, run time", "text-edit, shells", "Optional", "IME on each platform.", "Text Services Framework, NSTextInputClient, Wayland text-input, IBus or Fcitx."),
    ("Software GPU drivers (llvmpipe, lavapipe, WARP)", "CI", "Renderer conformance tests", "CI only", "Pixel tests without hardware.", "The earlier pixel check ran on llvmpipe."),
    ("A scriptable wgpu host (for example wgpu-py)", "CI", "tools-golden", "CI only", "Draws dumped frames and reads pixels back.", "Used for the earlier shader and layout check."),
    ("objdump", "CI", "tools-census", "CI only", "Counts conditional jumps in hot loops.", ""),
    ("OS performance counters (perf or equivalent)", "CI", "tools-bench, optimise", "CI only", "Cache misses, wakeups, resident memory.", ""),
    ("Clay, Dear ImGui, egui, Slint, LVGL, Iced, Qt Quick", "Comparison only", "vs-* lanes, gates", "CI only", "The same scenes are measured on each; never linked into the product.", ""),
]
table(wd, ["Dependency", "Kind", "Needed by", "Required?", "Why", "Note or alternative"], deps, [42, 18, 40, 11, 60, 60], wrap_cols=(1, 3, 5, 6))

# ---------------------------------------------------------------- Gates
wg = wb.create_sheet("Gates")
gates = [
    ("Frame CPU time", "No slower than the fastest comparison framework on each benchmark scene, same machine.", "bench-scenes and vs-* lanes", "Prototype today: about 0.34 ms for 3,961 nodes on one 2.1 GHz VM core.", "Target"),
    ("One-node change in 4,000 nodes", "At most 5% of the full layout and paint time.", "layout-incremental benchmark, damage tests", "Prototype today: full layout every frame.", "Target"),
    ("Memory of a static UI (comptime front end)", "Only state, dynamic rects and a dirty mask in RAM; structure and style in read-only data.", "ct-columns size report", "Probe today: 104 bytes of RAM for an 8-node UI.", "Measured in probe"),
    ("Memory of a dynamic UI (runtime front end)", "At most the prototype's bytes per node, then lower with each measured change.", "optimise lane", "Prototype today: about 0.65 KB per node of capacity.", "Measured in prototype"),
    ("Resident memory of an empty window", "No more than the lightest comparison framework; a software back end must exist.", "tools-bench probes", "Reference: reports of 100 MB against 10 MB for wgpu against a thin back end.", "Target"),
    ("Binary size", "A budget per example, set after the first measurement; growth above 2% fails CI.", "tools-bench size report", "Not measured yet.", "Target"),
    ("Embedded footprint", "Label-and-button demo within LVGL's documented minimum flash class.", "embedded budget tests", "Reference: LVGL documents 64 kB flash as its minimum.", "Target"),
    ("Idle", "Zero frames and zero wakeups while nothing changes.", "scheduler idle test, idle scene", "Prototype today: needsFrame is false and wake is infinite when idle.", "Measured in prototype"),
    ("Time to first frame", "No slower than the lightest comparison framework.", "gates lane", "Not measured yet.", "Target"),
    ("Branches in hot loops", "Per-row loops contain loop-control jumps only.", "tools-census", "Prototype today: true for every pass checked.", "Measured in prototype"),
    ("Portability", "Tests pass at 4, 8 and 16 lanes; cross-compiles for five targets.", "ci lane", "Prototype today: passes at 2, 4, 8 and 16 lanes (16 and 2 forced by hand: the std width query returns 8 even with AVX-512) and cross-compiles for five targets.", "Measured in prototype"),
    ("Accessibility", "A screen reader announces every widget in the example on Windows, macOS and Linux.", "a11y-bridge smoke tests", "Prototype today: role and value columns only.", "Target"),
    ("Text", "Unicode segmentation, line breaking and bidi conformance files pass.", "unicode lane", "Prototype today: fixed-advance font only.", "Target"),
    ("Compile time (comptime front end)", "A budget per spec size, set after the first measurement.", "ct-budget lane", "Not measured yet.", "Target"),
    ("API quality", "Every public function passes the nine-question checklist of the API design guide.", "release lane review", "Applied to the prototype by hand.", "Target"),
]
table(wg, ["Gate", "Definition", "Measured by", "Where we are", "Kind"], gates, [36, 70, 40, 60, 20], wrap_cols=(2, 3, 4))

# ---------------------------------------------------------------- References
wr = wb.create_sheet("References")
used = Counter()
for c in commits:
    for key, (name, _) in list(OURS.items()) + list(SPEC.items()):
        short = name.split(":")[0].split(" (")[0]
        if short in c["ref"] or (c["spec"] and short in c["spec"]):
            used[key] += 1
rows = []
WHERE = {"file": "Delivered as a file in this conversation", "sheet": "https://claude.ai/artifact/XuE2hAjhwJwgFE8x11ytys",
         "method": "Described in the earlier replies of this conversation", "talk": "Conference talk, listed by the design guides used earlier", "paper": "Published paper"}
for key, (name, where) in OURS.items():
    rows.append([name.split(":")[0].split(" (")[0], "Earlier in this conversation", name, WHERE.get(where, where), used[key]])
for key, (name, where) in SPEC.items():
    rows.append([name.split(":")[0].split(" (")[0], "New in this plan", name, WHERE.get(where, where), used[key]])
table(wr, ["Name used in the plan", "Origin", "What it is", "File or address", "Commits citing it"], rows, [44, 26, 80, 70, 16], wrap_cols=(3, 4))

wb.save(os.path.join(os.path.dirname(HERE), "gui-framework-commit-plan.xlsx"))
print("rows:", len(commits), "cells:", sum(ws.max_row * ws.max_column for ws in wb.worksheets))
zero = [r[0] for r in rows if r[4] == 0]
print("references never cited:", zero)
