# Builds the commit plan: lanes of sequential commits with cross-lane
# prerequisites, then computes waves (what can run in parallel) and the
# critical path. Output: generated.json, which export.py turns into ../plan.json.
import json, os
from refs import OURS, SPEC, ours, spec

U = lambda w: ours("UI", w)
W = lambda w: ours("WG", w)
E = lambda w: ours("EX", w)
K = lambda w: ours("CT", w)
M = lambda t: f"Targets matrix: target {t}"
R = ours
S = spec

LANES = []


def lane(phase, name, needs, ref, tg, done, commits):
    LANES.append(dict(phase=phase, name=name, needs=needs, ref=ref, tg=tg, done=done, commits=commits))


PHASES = {
    "P00": ("Foundations", "Repository, code standard, CI and the measuring tools every later gate uses."),
    "P01": ("Core data model", "The prototype split into small modules: SIMD helpers, value types, memory, input, node columns."),
    "P02": ("Layout engine", "The fixed sequence of passes, then wrap, grid, scroll, RTL and incremental layout."),
    "P03": ("Comptime front end", "UI declared as a comptime value: minimal types, read-only tables, signal masks, generated code."),
    "P04": ("Interaction and input", "Hit testing, pointer state machine, focus, keyboard, gestures."),
    "P05": ("Runtime front end and signals", "Context and Frame for dynamic UI, signals, subtree reuse, frame scheduling."),
    "P06": ("Draw list and paint", "Flat draw commands, visual features, vector paths, damage tracking."),
    "P07": ("Text", "Fonts, rasterizing, shaping, Unicode algorithms, text layout and editing."),
    "P08": ("Renderers", "One draw list, many back ends: software, Vulkan, Metal, D3D12, GL ES, web, wgpu, Gompute."),
    "P09": ("Platform shells", "Windows, macOS, Wayland, X11, web, Android, iOS, bare metal, headless."),
    "P10": ("Widgets", "Each widget in five commits: spec, look, behaviour, accessibility, tests."),
    "P11": ("Animation", "Springs, tweens, transitions, layout animation."),
    "P12": ("Accessibility", "Semantic tree, AccessKit bridge, platform adapters, settings."),
    "P13": ("Styling and theming", "Tokens, state styles, themes, materials."),
    "P14": ("Assets and internationalisation", "Images, icons, message catalogues."),
    "P15": ("Performance and footprint gates", "Benchmark scenes, competitor harnesses, CI gates, measured optimisations."),
    "P16": ("Tooling and developer experience", "Inspector, debug views, docs, examples."),
    "P17": ("Embedded profile", "Freestanding build, fixed point, small framebuffers, flash and RAM budgets."),
    "P18": ("Release engineering", "API review, packaging, versioning, milestones."),
}

# =============================================================================
# P00 Foundations
# =============================================================================
lane("P00", "repo", [], R("ZIG17_BUILD", "what changed in build.zig"), "", "zig build and zig build test pass on Zig 0.17.1", [
    ("repo: initialise with build.zig, build.zig.zon, licence and .editorconfig", dict(done="zig build succeeds on a clean checkout", key="repo-init")),
    ("docs: add CODE_STANDARD.md (names, small functions, no hidden allocation, comments say why)", dict(ref=R("CASEY_API", "the five characteristics") + "; " + R("CASEY_CLEAN", "where textbook clean code costs performance"), done="standard lists which clean-code rules are adopted and which are not")),
    ("docs: add ARCHITECTURE.md with the tier rule (a tier uses only tiers below it)", dict(ref=U("file header: TIERS and RULES"), done="document merged")),
    ("docs: add CONTRIBUTING.md (one logical change per commit, every commit builds and tests)", dict(ref=R("CASEY_COMP", "compress only after the second use"))),
    ("repo: add zig fmt check and commit-message lint", dict(done="CI rejects unformatted code")),
])
lane("P00", "ci", ["repo-init"], R("CHK", "test matrix"), "", "all jobs green", [
    ("ci: run tests in Debug, ReleaseSafe and ReleaseFast", dict(key="ci")),
    ("ci: run tests with 4-lane and 8-lane vectors (x86_64 baseline and AVX2)", dict(ref=R("CHK", "test matrix") + "; " + U("simd.lanes"))),
    ("ci: cross-compile for aarch64-linux, aarch64-macos, x86_64-windows, wasm32-wasi, riscv64-linux", dict(ref=R("CHK", "cross-target compiles"))),
])
lane("P00", "tools-census", ["ci"], R("CHK", "branch census method"), "", "census runs in CI", [
    ("tools: add branch census (count conditional jumps per hot function from objdump)", dict(key="census")),
    ("ci: fail when a per-row loop gains a conditional jump", dict(ref=R("CHK", "branch census results"))),
])
lane("P00", "tools-bench", ["ci"], R("CHK", "benchmark: build 142, layout 163, paint 31 microseconds"), "E2", "numbers printed in CI", [
    ("tools: add benchmark harness with per-pass timers and a 4,000-node scene", dict(key="bench")),
    ("tools: store benchmark baselines as JSON and compare with a tolerance", dict(done="CI prints a delta table per pass")),
    ("tools: add binary-size report per example", dict(ref=M("E2"), done="zig build size prints text, rodata, data, bss")),
    ("tools: add resident-memory and idle-wakeup probes", dict(ref=M("D5") + "; " + R("FTW", "how idle power was measured"))),
])
lane("P00", "tools-golden", ["ci"], R("CHK", "wgpu pixel check"), "", "runner compares images in CI", [
    ("tools: add golden-image test runner", dict(key="golden")),
    ("tools: add GPU pixel-check runner on a software adapter", dict(ref=R("CHK", "wgpu pixel check script"))),
])
lane("P00", "tools-fuzz", ["ci"], R("CHK", "overflow test as the model for hostile input"), "", "fuzzer runs 60 s in CI without a crash", [
    ("tools: add fuzz entry points for input streams and style values", {}),
])
lane("P00", "gates-doc", ["repo"], R("MX", "Targets tab"), "", "document merged", [
    ("docs: add GATES.md with the measurable release gates", dict(key="gates-doc")),
])

# =============================================================================
# P01 Core data model
# =============================================================================
lane("P01", "simd", ["ci"], U("simd"), "B2", "unit tests pass at 4, 8 and 16 lanes", [
    ("simd: add lane count, vector aliases and padded()", dict(ref=U("simd.lanes, simd.padded"))),
    ("simd: add column load and store helpers", dict(ref=U("simd.loadF, simd.storeF"))),
    ("simd: add branch-free selects selU, selF and b2f", dict(ref=U("simd.selU, simd.b2f") + "; " + R("CHK", "why b2f is a bit pattern"), done="census shows no jump")),
    ("simd: add find() over an id column", dict(ref=U("simd.find"))),
    ("simd: add rank() over a sorted column", dict(ref=U("simd.rank"))),
    ("simd: add stream-compaction helper (write always, advance by mask)", dict(ref=U("Anims.sweep, paint.emit sweep 1"))),
    ("simd: add property tests against scalar reference implementations", dict(done="10,000 random cases agree")),
    ("simd: document the padding contract for every column owner", dict(ref=U("Tree.rows"))),
])
lane("P01", "types", ["ci"], U("small value types"), "B2", "unit tests pass", [
    ("types: add Id with compile-time and run-time hashing", dict(ref=U("Id.from, Id.src, Id.hash, Id.with"))),
    ("types: add Node and Axis index types", dict(ref=U("Node, Axis"))),
    ("types: add Color as packed RGBA8", dict(ref=U("Color"))),
    ("types: add Rect with single-max intersection", dict(ref=U("Rect.intersect"))),
    ("types: add Size with coefficient tables", dict(ref=U("Size.k_min .. k_pct"), tg="C1")),
    ("types: add Align with factor table", dict(ref=U("Align.factor"))),
    ("types: add Sense and Response bit sets", dict(ref=U("Sense, Response"))),
    ("types: add Style and TextStyle with defaults", dict(ref=U("Style, TextStyle"))),
    ("types: add Role enum", dict(ref=U("Role"), tg="H2")),
    ("types: add layout-size tests for every extern and packed type", dict(done="@sizeOf and @offsetOf asserted")),
])
lane("P01", "mem", ["ci"], U("mem"), "B3", "unit tests pass; no allocator in the module", [
    ("mem: add Carver.slice over a caller-owned buffer", dict(ref=U("mem.Carver.slice") + "; " + R("CLAY", "static arena, no malloc"))),
    ("mem: add Carver.columns by reflection over []T and [k][]T fields", dict(ref=U("mem.Carver.columns") + "; " + R("ZIG17", "new @typeInfo field layout"))),
    ("mem: add counting mode so sizing and carving share one code path", dict(ref=U("Context.requiredBytes"))),
    ("mem: add copyRows for column sets", dict(ref=U("mem.copyRows"))),
    ("mem: assert 64-byte alignment of every column", dict(ref=U("mem.column_align"))),
    ("mem: document bytes per node and how to budget limits", dict(ref=R("CHK", "0.65 KB per node of capacity"))),
])
lane("P01", "input", ["types"], U("Input"), "G7", "unit tests pass", [
    ("input: add Input struct filled by the host", dict(ref=U("Input"))),
    ("input: add Buttons and Mods bit sets", dict(ref=U("Input.Buttons, Input.Mods"))),
    ("input: add Keys as a 256-bit set", dict(ref=U("Input.Keys"))),
    ("input: add stamp() fingerprint for idle detection", dict(ref=U("Input.stamp"), tg="D5")),
    ("input: add per-frame event queue for key presses and typed text", dict(ref=R("DVUI", "processes every input event"))),
    ("input: add touch and pen fields with pointer ids", dict(ref=R("DVUI", "touch support"))),
    ("input: add high-resolution wheel and pixel-scroll deltas", {}),
    ("input: add recorded-input replay format for tests", dict(done="example tests replay from a file")),
])
lane("P01", "tree", ["simd", "types", "mem"], U("Tree"), "B2", "unit tests pass", [
    ("tree: add Columns grouped by the pass that reads them", dict(ref=U("Tree.Columns") + "; " + R("KELLEY_DOD", "group fields by access pattern"))),
    ("tree: add Look as one paint row per node", dict(ref=U("Look") + "; " + R("FABIAN", "hot / cold splitting"))),
    ("tree: add init and reset", dict(ref=U("Tree.init, Tree.reset"))),
    ("tree: add push as one row write per column", dict(ref=U("Tree.push"), done="census: no jump in push")),
    ("tree: add seal to close a subtree", dict(ref=U("Tree.seal"))),
    ("tree: add find and rect accessors", dict(ref=U("Tree.find, Tree.rect"))),
    ("tree: report overflow instead of writing out of bounds", dict(ref=U("Tree.overflow, Status") + "; " + E('test "running out of rows is reported, not fatal"'))),
    ("tree: add debug-only validate() for structural invariants", dict(done="parent < child, end ranges nest")),
    ("tree: make columns generic over index type and storage (slice or array)", dict(ref=K("Ui().Index, tables"), tg="B2", key="tree-generic")),
])
lane("P01", "sidelists", ["tree"], U("Strings, Texts, Customs"), "B1", "unit tests pass", [
    ("strings: add frame-lifetime byte storage", dict(ref=U("Strings"))),
    ("texts: add text-run side list", dict(ref=U("Texts") + "; " + R("ACTON", "existence-based processing"))),
    ("customs: add custom-draw side list", dict(ref=U("Customs"))),
    ("sidelists: add overflow reporting and tests", dict(ref=U("Status"))),
])

# =============================================================================
# P02 Layout
# =============================================================================
lane("P02", "layout-core", ["sidelists"], U("layout"), "C1", "example tier-0 test passes with exact rects", [
    ("layout: add prepare (SIMD scratch reset and gap totals)", dict(ref=U("layout.prepare"))),
    ("layout: add applyText scatter", dict(ref=U("layout.applyText"))),
    ("layout: add fit, the bottom-up sweep", dict(ref=U("layout.fit") + "; " + R("CLAY", "fit sizing pass"))),
    ("layout: add SIMD reciprocal column after fit", dict(ref=U("layout.fit: grow_inv"))),
    ("layout: add resolve, the top-down sweep", dict(ref=U("layout.resolve"))),
    ("layout: add textAvail gather for wrapping", dict(ref=U("layout.textAvail"))),
    ("layout: add place for both axes", dict(ref=U("layout.place"))),
    ("layout: add finalize (pixel snap, clip, visibility)", dict(ref=U("layout.finalize"))),
    ("layout: add run() as the visible sequence of passes", dict(ref=U("layout.run") + "; " + R("CASEY_API", "granularity: shortcut equals lower-tier calls"))),
    ("layout: port the tier-0 test", dict(ref=E('test "tier 0 alone: no Context, caller sequences the passes"'), key="layout-core-done")),
    ("layout: add census and benchmark entries for every pass", dict(ref=R("CHK", "per-pass timings"), done="fit, resolve, place: loop control jumps only")),
])
lane("P02", "layout-constraints", ["layout-core"], U("layout.resolve"), "C1", "tests cover each rule", [
    ("layout: test min, max and percent against parent inner size", {}),
    ("layout: add aspect-ratio sizing", dict(spec=S("CSS_FLEX", "aspect ratio behaviour"))),
    ("layout: add shrink weights for overflow", dict(ref=U("layout.resolve: shrink"), spec=S("CSS_FLEX", "flex-shrink"))),
    ("layout: add optional second grow round, bounded to two", dict(ref=U("layout.resolve doc comment on single round"))),
    ("layout: add per-child cross alignment override", {}),
    ("layout: add margins as coefficients", {}),
])
lane("P02", "layout-wrap", ["layout-core"], U("layout.fit, layout.place"), "C1", "wrap tests pass; pass count stays fixed", [
    ("layout: design wrapping rows as a line-index column", dict(ref=R("CLAY", "text wrapping and flex-like model"), spec=S("CSS_FLEX", "flex-wrap"))),
    ("layout: assign children to lines after resolve on the main axis", {}),
    ("layout: stack lines on the cross axis", {}),
    ("layout: align within and across lines", {}),
    ("layout: add wrap tests and benchmark", {}),
])
lane("P02", "layout-grid", ["layout-core"], U("layout.resolve"), "C1", "grid tests pass", [
    ("grid: add track list with fixed, fit and fraction sizes", dict(spec=S("CSS_GRID", "track sizing"))),
    ("grid: add explicit cell placement", {}),
    ("grid: add row and column spans", {}),
    ("grid: add auto placement in row order", {}),
    ("grid: resolve fraction tracks in one pass", {}),
    ("grid: add gaps and alignment", {}),
    ("grid: add tests and benchmark", {}),
])
lane("P02", "layout-overlay", ["layout-core"], U("Style.float, Style.offset"), "G1", "overlay tests pass", [
    ("layout: add z-stack container", {}),
    ("layout: add anchors for floating nodes (edge and corner of the parent)", dict(ref=U("layout.place: offset"))),
    ("layout: add anchor to another node's last rect", dict(ref=U("Frame.lastRect"))),
    ("layout: add viewport collision flip for popovers", {}),
    ("layout: add layer index column for paint order", dict(ref=U("hit.at doc: later rows win"), key="layer")),
    ("layout: add overlay tests", {}),
])
lane("P02", "layout-scroll", ["layout-core"], U("Style.scroll, Style.clip"), "E1", "scroll tests pass", [
    ("layout: expose content extent per node", dict(ref=U("Tree.Columns.fit"))),
    ("layout: clamp scroll offsets to the content extent", {}),
    ("layout: add scroll-into-view query", {}),
    ("layout: add sticky children", {}),
    ("layout: add scroll tests", {}),
])
lane("P02", "layout-rtl", ["layout-core"], U("Tree.Columns.main (direction as a coefficient)"), "H1", "mirrored tests pass", [
    ("layout: add inline direction as a sign coefficient", {}),
    ("layout: add logical start and end padding", {}),
    ("layout: mirror alignment factors under RTL", dict(ref=U("Align.factor"))),
    ("layout: add RTL tests", {}),
])
lane("P02", "layout-baseline", ["layout-core"], U("layout.place"), "H1", "baseline tests pass", [
    ("layout: carry text baseline through fit", {}),
    ("layout: add baseline cross alignment", {}),
    ("layout: add baseline tests", {}),
])
lane("P02", "layout-incremental", ["layout-core"], M("C2") + "; " + R("XILEM", "passes over dirty subsets"), "C2", "incremental result equals full layout in a randomised test", [
    ("layout: add dirty bits per node and axis", {}),
    ("layout: mark relayout boundaries (size independent of content)", dict(ref=R("XILEM", "request_layout flags"))),
    ("layout: propagate dirtiness to ancestors up to a boundary", {}),
    ("layout: run fit over dirty ranges only", {}),
    ("layout: run resolve and place over dirty subtrees only", dict(ref=U("Tree.Columns.end (subtree ranges)"))),
    ("layout: add equivalence test against full layout", {}),
    ("layout: add benchmark for a one-node change in 4,000 nodes", dict(ref=R("CHK", "benchmark scene"), key="layout-inc-done")),
])
lane("P02", "layout-latency", ["layout-core", "bench"], R("CHK", "resolve is latency-bound at about 9 ns per node"), "C1", "resolve and place at least 1.5x faster in the benchmark, same results", [
    ("layout: rewrite resolve as K0 + K1*inner + K2*max(inner - taken, 0)", dict(ref=U("layout.resolve"))),
    ("layout: precompute K coefficients in a SIMD pass", {}),
    ("layout: group per-axis inputs into one row per node and measure", dict(ref=R("KELLEY_DOD", "fewer streams per loop"))),
    ("layout: experiment with level-order storage so sweeps vectorise", dict(done="decision recorded with numbers")),
    ("layout: add prefetch of parent rows and measure", {}),
])

# =============================================================================
# P03 Comptime front end
# =============================================================================
lane("P03", "ct-spec", ["tree-generic"], K("Spec, col, row, label, checkbox, slider"), "A2", "probe tests pass in the main tree", [
    ("comptime: add Spec node type", dict(ref=K("Spec"))),
    ("comptime: add container builders taking child tuples", dict(ref=K("col, row, kids"))),
    ("comptime: add leaf builders for the first widgets", dict(ref=K("label, checkbox, slider"))),
    ("comptime: accept the full Style in specs", dict(ref=U("Style"))),
    ("comptime: use enum literals for widget ids and state fields", dict(ref=K("Ui().Widget, Ui().Field"))),
    ("comptime: add spec composition (functions that return Spec)", dict(ref=R("CASEY_COMP", "components are just functions"))),
    ("comptime: add spec parameters (comptime arguments to components)", {}),
])
lane("P03", "ct-flatten", ["ct-spec"], K("Ui().flatten, tables"), "B2", "tables equal the runtime tree built from the same UI", [
    ("comptime: count nodes of a spec", dict(ref=K("count"))),
    ("comptime: pick the smallest index type for the node count", dict(ref=K("Ui().Index (u4 for 8 nodes)"), tg="B2")),
    ("comptime: flatten to parent and end tables", dict(ref=K("Ui().parent, Ui().end"))),
    ("comptime: emit depth and level-order tables", {}),
    ("comptime: prove tables land in read-only data", dict(done="objdump section check in CI")),
    ("comptime: add equivalence test against Tree.push", dict(ref=U("Tree.push"))),
    ("comptime: raise and document evaluation quotas", dict(ref=U("Context.requiredBytes: @setEvalBranchQuota"))),
])
lane("P03", "ct-validate", ["ct-flatten"], K("flatten: @compileError checks"), "H2", "each rule has a compile-fail test", [
    ("comptime: reject duplicate widget ids", dict(ref=K("flatten: duplicate widget id"))),
    ("comptime: type-check bindings against the state struct", dict(ref=K("flatten: slider needs an f32 field"))),
    ("comptime: reject bindings to missing fields", dict(ref=K("fieldIndex"))),
    ("comptime: print the spec path in every error", {}),
    ("comptime: lint that interactive widgets have an accessible name", dict(tg="H2")),
    ("comptime: check fixed-viewport layouts for overflow", dict(tg="E3")),
    ("comptime: add compile-fail test harness", {}),
])
lane("P03", "ct-columns", ["ct-flatten"], K("Ui().Runtime") + "; " + U("Tree.Columns"), "B2", "RAM and read-only sizes reported per example", [
    ("comptime: classify every column as constant or dynamic per UI", {}),
    ("comptime: store constant style columns in read-only data", dict(tg="B1")),
    ("comptime: size dynamic columns as exact arrays", dict(ref=K("Ui().Runtime.rect"))),
    ("comptime: choose the coordinate type from the declared maximum viewport", dict(ref=K("Runtime.rect: i16"), tg="E3")),
    ("comptime: index colours through a palette when it fits a byte", {}),
    ("comptime: build one string table with minimal offsets", dict(ref=U("Strings"))),
    ("comptime: drop columns for features the UI does not use", {}),
    ("comptime: report bytes saved against the runtime tree", dict(ref=R("CHK", "0.65 KB per node of capacity"))),
])
lane("P03", "ct-signals", ["ct-flatten"], K("Ui().dirty_masks, Runtime.set"), "A1", "setter compiles to a store and one OR; tests pass", [
    ("comptime: derive the Field enum from the state struct", dict(ref=K("Ui().Field"))),
    ("comptime: compute a dirty mask per state field", dict(ref=K("Ui().dirty_masks"))),
    ("comptime: generate set() as a store plus a constant OR", dict(ref=K("Runtime.set") + "; " + R("CHK", "set_volume disassembly"), tg="A2")),
    ("comptime: choose the mask type by node count (integer or bit-set array)", dict(ref=K("Ui().Mask"))),
    ("comptime: add derived fields with a topological order", dict(ref=R("FLOEM", "signals and effects"))),
    ("comptime: add batched updates", dict(tg="A3")),
    ("comptime: separate layout-dirty from paint-dirty masks", dict(tg="D4")),
    ("comptime: add effects that run when a mask bit is set", {}),
])
lane("P03", "ct-layout", ["ct-columns", "ct-signals", "layout-core-done"], U("layout") + "; " + K("tables"), "C2", "results equal the runtime layout; benchmark recorded", [
    ("comptime: run the generic layout passes over array columns", dict(ref=U("layout.fit, layout.resolve"))),
    ("comptime: fold layout of viewport-independent subtrees at compile time", {}),
    ("comptime: precompute gap totals, child counts and reciprocals", dict(ref=U("layout.prepare, layout.fit: grow_inv"))),
    ("comptime: skip passes a UI cannot need (no grow, no wrap, no text)", {}),
    ("comptime: generate a partial layout routine per dirty mask", dict(ref=M("C2"))),
    ("comptime: unroll sweeps for small trees and measure code size", dict(done="decision recorded: table-driven or unrolled, by node count")),
    ("comptime: add equivalence tests against the runtime front end", {}),
    ("comptime: add layout benchmark for static UIs", dict(key="ct-layout-done")),
])
lane("P03", "ct-paint", ["ct-layout", "draw-core"], U("paint.emit, DrawList"), "D2", "draw list equals the runtime front end's", [
    ("comptime: emit static quad templates as read-only data", dict(ref=U("Quad"))),
    ("comptime: compute batches at compile time", dict(ref=U("paint.emit sweep 3"))),
    ("comptime: sort quads by texture and material within a layer", {}),
    ("comptime: generate a patch list per state field (which quad fields change)", dict(ref=K("dirty_masks"))),
    ("comptime: upload only patched quad ranges", dict(ref=W("Renderer.prepare"))),
    ("comptime: add draw-list equivalence tests", {}),
    ("comptime: add paint benchmark for static UIs", {}),
])
lane("P03", "ct-events", ["ct-flatten", "hit-core"], K("Ui().Widget") + "; " + U("hit.at"), "A2", "exhaustive-switch example compiles; tests pass", [
    ("comptime: generate the Widget enum from ids", dict(ref=K("Ui().Widget via @Enum"))),
    ("comptime: hit test over the static rect table", dict(ref=U("hit.at"))),
    ("comptime: return events as a tagged union over widgets", {}),
    ("comptime: compute the keyboard focus order at compile time", {}),
    ("comptime: build the shortcut table as a perfect hash", {}),
    ("comptime: add event tests with replayed input", {}),
])
lane("P03", "ct-dynamic", ["ct-layout"], R("XILEM_VS", "virtual scrolling of a template") + "; " + U("Frame.reuse"), "E1", "list example runs with a bounded template", [
    ("comptime: add list(max, template) with a run-time count", {}),
    ("comptime: add when(condition, subtree) with reserved rows", {}),
    ("comptime: add switch-like alternatives sharing rows", {}),
    ("comptime: virtualise list templates by scroll offset", dict(ref=R("XILEM_VS"))),
    ("comptime: extend dirty masks to dynamic ranges", {}),
    ("comptime: add tests for count changes", {}),
    ("comptime: document what must stay dynamic and why", {}),
])
lane("P03", "ct-features", ["ct-paint"], W("shader(), default_material"), "E2", "feature-off builds are smaller; sizes recorded", [
    ("comptime: derive feature flags from the spec (text, radius, border, image)", {}),
    ("comptime: specialise the quad shader by feature flags", dict(ref=W("shader_head, shader_tail"))),
    ("comptime: compile out unused paint paths in the software renderer", {}),
    ("comptime: subset the glyph atlas to static strings", dict(tg="E3")),
    ("comptime: record binary size per feature set", dict(ref=M("E2"))),
])
lane("P03", "ct-interop", ["ct-layout", "context"], U("Frame") + "; " + K("Ui()"), "G7", "mixed example runs", [
    ("comptime: host a runtime Frame inside a comptime UI region", dict(ref=U("Frame.open, Frame.end"))),
    ("comptime: host a comptime UI inside a runtime Frame", {}),
    ("comptime: share one draw list between both front ends", dict(ref=U("DrawList"))),
    ("comptime: add mixed-front-end example and tests", {}),
])
lane("P03", "ct-budget", ["ct-layout-done"], R("ZIG17_NOTES", "incremental compilation on x86_64-linux"), "E2", "compile-time and size numbers recorded", [
    ("bench: measure compile time for 100, 1,000 and 10,000 node specs", {}),
    ("bench: measure RAM and read-only bytes against the runtime front end", {}),
    ("bench: measure edit-rebuild time with incremental compilation", {}),
    ("docs: write guidance on when to use which front end", {}),
])

# =============================================================================
# P04 Interaction and input
# =============================================================================
lane("P04", "hit", ["layout-core-done"], U("hit.at"), "D2", "tests pass; census clean", [
    ("hit: add SIMD point-in-rect scan over visible rects", dict(ref=U("hit.at"))),
    ("hit: add touch slop", {}),
    ("hit: add hit tests and census entry", dict(ref=R("CHK", "p_hit: loop control only"), key="hit-core")),
    # Layers come from layout-overlay; the rest of hit does not need them.
    ("hit: respect paint layers", dict(needs=["layer"])),
])
lane("P04", "interaction", ["hit-core", "input"], U("Interaction"), "A3", "replay tests pass", [
    ("interaction: add step() for hover, press, release, click", dict(ref=U("Interaction.step"))),
    ("interaction: add response() as a bit set", dict(ref=U("Interaction.response"))),
    ("interaction: add double click and long press", {}),
    ("interaction: add pointer capture while held", dict(ref=U("Interaction.response: unowned"))),
    ("interaction: add drag threshold and drag deltas", dict(ref=U("Frame.drag"))),
    ("interaction: add multi-touch pointer ids", {}),
    ("interaction: add hover intent delay", {}),
    ("interaction: port click and drag tests", dict(ref=E('test "host loop: layout, draw list, click, drag, idle"'), key="interaction-done")),
])
lane("P04", "focus", ["interaction"], U("Interaction.focus, Sense.focus"), "H2", "keyboard-only walkthrough test passes", [
    ("focus: add focus ring state and visible indicator", {}),
    ("focus: add tab order from tree order", {}),
    ("focus: add arrow-key navigation within groups", dict(spec=S("APG", "keyboard interface"))),
    ("focus: add focus trap for modal layers", dict(spec=S("APG", "dialog (modal) pattern"))),
    ("focus: restore focus when a layer closes", {}),
    ("focus: add focus tests", {}),
])
lane("P04", "keyboard", ["interaction"], U("Input.Keys, Input.text"), "A3", "tests pass", [
    ("keyboard: route key events to the focused widget", {}),
    ("keyboard: add shortcut table with modifiers", {}),
    ("keyboard: add clipboard commands as platform output", dict(ref=U("Platform.clipboard"))),
    ("keyboard: add text-input events with composition ranges", dict(ref=R("ICED_REL", "input method support"))),
    ("keyboard: add keyboard tests with replayed input", {}),
])
lane("P04", "gestures", ["interaction"], U("Input.wheel"), "A3", "tests pass", [
    ("gestures: route wheel to the innermost scrollable under the pointer", {}),
    ("gestures: add kinetic scrolling with a spring", dict(ref=U("Anims.step"))),
    ("gestures: add pinch zoom events", {}),
    ("gestures: add in-app drag and drop", {}),
    ("gestures: add external file drop as an input event", {}),
])

# =============================================================================
# P05 Runtime front end and signals
# =============================================================================
lane("P05", "context", ["layout-core-done", "interaction-done", "draw-core"], U("Context, Frame"), "G7", "example host-loop test passes", [
    ("context: add Limits and requiredBytes at comptime", dict(ref=U("Limits, Context.requiredBytes"))),
    ("context: add init over a caller buffer", dict(ref=U("Context.init"))),
    ("context: add begin (swap generations, step interaction and springs)", dict(ref=U("Context.begin"))),
    ("frame: add open, close and leaf", dict(ref=U("Frame.open, Frame.close, Frame.leaf"))),
    ("frame: add text and custom leaves", dict(ref=U("Frame.text, Frame.custom"))),
    ("frame: add interact, drag, lastRect, heldRect", dict(ref=U("Frame.interact, Frame.heldRect"))),
    ("frame: add end as the visible pass sequence, and finish", dict(ref=U("Frame.end, Frame.finish"))),
    ("context: report Status and Platform output as data", dict(ref=U("Status, Platform, Output") + "; " + R("CASEY_API", "flow control: no callbacks"))),
    ("context: port the host-loop test", dict(ref=E('test "host loop: layout, draw list, click, drag, idle"'), key="context-done")),
])
lane("P05", "signals", ["context"], U("Signals, Cell"), "A1", "tests pass", [
    ("signals: add version counters and bump", dict(ref=U("Signals.bump"))),
    ("signals: add Cell(T)", dict(ref=U("Cell"))),
    ("signals: add derived cells with cached stamps", dict(ref=U("Signals.stamp"))),
    ("signals: add transactions that coalesce changes", dict(tg="A3")),
    ("signals: add effects run once per frame", {}),
    ("signals: add signal tests", {}),
])
lane("P05", "reuse", ["signals"], U("Frame.reuse, Memos"), "A1", "example signals test passes", [
    ("reuse: add Memos table", dict(ref=U("Memos"))),
    ("reuse: add reuse() decision without branches until the final copy", dict(ref=U("Frame.reuse"))),
    ("reuse: add copySubtree with SIMD link rebasing", dict(ref=U("Frame.copySubtree"))),
    ("reuse: rebuild once after pointer interaction ends", dict(ref=U("Frame.reuse: stamp ^ touched"))),
    ("reuse: allow reuse while unrelated springs move", dict(ref=U("Frame.reuse: ctx.motion == 0 limitation"))),
    ("reuse: skip layout for reused subtrees behind a relayout boundary", dict(needs=["layout-inc-done"], tg="C2")),
    ("reuse: port the signals test", dict(ref=E('test "signals: the sidebar is rebuilt only when it has to be"'))),
])
lane("P05", "scheduler", ["context"], U("Context.needsFrame, Output.wake"), "D5", "idle test: zero frames and zero wakeups without input", [
    ("scheduler: add needsFrame from input stamp, motion and signals", dict(ref=U("Context.needsFrame"))),
    ("scheduler: add one settle frame after input", dict(ref=U("Context.begin: settle"))),
    ("scheduler: add timers with the earliest deadline as wake", dict(ref=U("Output.wake"))),
    ("scheduler: add thread-safe wake and a queue for background results", dict(tg="F1")),
    ("scheduler: add frame pacing hints for the host", dict(tg="F3")),
    ("scheduler: add idle test", dict(ref=R("IMGUI_IDLE", "idling outside the library") + "; " + M("D5"), key="scheduler-done")),
])

# =============================================================================
# P06 Draw list and paint
# =============================================================================
lane("P06", "draw-core", ["layout-core-done"], U("DrawList, paint"), "D2", "draw-list tests pass; census clean", [
    ("draw: add Quad as the GPU instance layout", dict(ref=U("Quad") + "; " + R("ZIG_VEC", "arrays, not vectors, in extern structs"))),
    ("draw: add TextRun and CustomDraw", dict(ref=U("TextRun, CustomDraw"))),
    ("draw: add DrawList with command columns", dict(ref=U("DrawList, DrawList.CmdColumns"), key="drawlist")),
    ("draw: add command() tagged-union view", dict(ref=U("DrawList.command, Cmd"))),
    ("paint: add sweep 1 (nodes to quads and ops)", dict(ref=U("paint.emit sweep 1"))),
    ("paint: add sweep 2 (side lists to geometry)", dict(ref=U("paint.emit sweep 2"))),
    ("paint: add sweep 3 (run-length encode ops into commands)", dict(ref=U("paint.emit sweep 3"))),
    ("paint: clip children inside the border", dict(ref=U("layout.finalize: inner clip"))),
    ("paint: add draw-list tests and census entry", dict(ref=R("CHK", "p_paint: loop control only"), key="draw-core")),
])
lane("P06", "draw-features", ["draw-core"], U("Quad.params, Style") + "; " + W("shader_tail"), "G3", "golden images match", [
    ("draw: add linear and radial gradients through quad params", {}),
    ("draw: add analytic box shadows for rounded rects", {}),
    ("draw: add images with UV rects", dict(ref=U("Quad.uv"))),
    ("draw: add nine-slice images", {}),
    ("draw: add per-corner radii", dict(ref=W("rounded_box"))),
    ("draw: add dashed and dotted borders", {}),
    ("draw: add opacity for subtrees", {}),
    ("draw: add 2D transforms per node", {}),
    ("draw: add rounded clipping in the shader", dict(ref=U("Tree.Columns.child_clip doc: rectangular only"))),
])
lane("P06", "draw-paths", ["draw-core"], R("DVUI", "TinyVG icons"), "G1", "golden images match", [
    ("paths: add path builder with lines and Beziers", {}),
    ("paths: flatten curves to a tolerance", {}),
    ("paths: add stroker with joins and caps", {}),
    ("paths: fill through a coverage atlas", {}),
    ("paths: add TinyVG icon decoding", dict(spec=S("TINYVG"))),
    ("paths: add path tests", {}),
])
lane("P06", "damage", ["draw-core"], M("D4") + "; " + R("SLINT", "redraws only what changed"), "D4", "one-node change repaints one small rect in the test", [
    ("damage: hash each node's paint inputs per frame", {}),
    ("damage: compare against last frame with SIMD", dict(ref=U("Context.trees (two generations)"))),
    ("damage: union dirty rects into a small region", dict(ref=U("Rect.intersect (same sign trick for union)"))),
    ("damage: emit only quads touching the region", {}),
    ("damage: expose the region to renderers", {}),
    ("damage: add damage tests", dict(key="damage-done")),
])
lane("P06", "draw-order", ["draw-core"], R("QT_RENDERER", "opaque batches and ordering"), "D2", "batch counts recorded", [
    ("draw: add stacking layers", {}),
    ("draw: merge batches across text when layers allow", {}),
    ("draw: draw opaque quads front to back where the back end has depth", {}),
    ("draw: add batch-count benchmark", {}),
])

# =============================================================================
# P07 Text
# =============================================================================
lane("P07", "text-protocol", ["sidelists"], U("fonts.Mono"), "G6", "tests pass", [
    ("text: document the measure / wrap protocol (data, not callbacks)", dict(ref=U("fonts section comment") + "; " + R("CASEY_API", "flow control"))),
    ("text: add Mono.measure with SIMD", dict(ref=U("fonts.Mono.measure"))),
    ("text: add Mono.wrap with SIMD", dict(ref=U("fonts.Mono.wrap"))),
    # The cache needs measure and Texts only; quads needs Quad and DrawList (lane draw-core).
    ("text: add measurement cache keyed by string hash, font and size", dict(key="text-measure")),
    ("text: add Mono.quads for a byte-indexed atlas", dict(ref=U("fonts.Mono.quads"), needs=["drawlist"], key="text-protocol-done")),
])
lane("P07", "font-load", ["text-measure"], R("DVUI", "font support") + "; " + R("DEVTO", "why the text stack dominates weight"), "D1", "a test font parses; metrics match known values", [
    ("font: parse the table directory", dict(spec=S("OT", "font file structure"))),
    ("font: parse cmap", dict(spec=S("OT", "cmap"))),
    ("font: parse head, hhea, hmtx and maxp", dict(spec=S("OT", "metrics tables"))),
    ("font: parse loca and glyf outlines", dict(spec=S("OT", "glyf"))),
    ("font: parse kern and basic GPOS pair adjustment", dict(spec=S("OT", "GPOS"))),
    ("font: parse composite glyphs", dict(spec=S("OT", "glyf composite"))),
    ("font: add font collections and face selection", {}),
    ("font: fuzz the parser", dict(done="no crash in 5 minutes of fuzzing")),
])
lane("P07", "glyph-raster", ["font-load"], U("fonts.Mono.quads (atlas contract)"), "D1", "glyph images match references", [
    ("raster: add outline scan conversion with accumulated coverage", {}),
    ("raster: vectorise coverage accumulation", dict(ref=U("simd"))),
    ("raster: add subpixel positioning", {}),
    ("raster: add gamma-correct blending tables", {}),
    ("atlas: add skyline packer", dict(ref=R("QT_RENDERER", "texture atlas"))),
    ("atlas: add eviction and repacking", {}),
    ("atlas: upload dirty atlas regions only", dict(ref=W("Renderer.addTexture"))),
    ("raster: add optional signed-distance glyphs", {}),
])
lane("P07", "shaping", ["font-load"], R("ICED_FAQ", "shaping and IME status") + "; " + M("H1"), "H1", "shaping tests pass", [
    ("shaping: add simple shaper (cmap, advances, kerning)", {}),
    ("shaping: add ligatures through basic GSUB", dict(spec=S("OT", "GSUB"))),
    ("shaping: add mark positioning through basic GPOS", dict(spec=S("OT", "GPOS mark attachment"))),
    ("shaping: add cluster mapping for cursor placement", {}),
    ("shaping: add shaping cache", {}),
    ("shaping: add optional HarfBuzz adapter behind the same data protocol", dict(done="complex-script sample renders through the adapter")),
])
lane("P07", "unicode", ["text-measure"], M("H1"), "H1", "Unicode conformance files pass", [
    ("unicode: generate property tables at comptime from the character database", dict(spec=S("UAX29", "property data"))),
    ("unicode: add grapheme cluster iterator", dict(spec=S("UAX29", "grapheme cluster boundaries"))),
    ("unicode: add word boundary iterator", dict(spec=S("UAX29", "word boundaries"))),
    ("unicode: add line break opportunities", dict(spec=S("UAX14"))),
    ("unicode: add bidi levels", dict(spec=S("UAX9"))),
    ("unicode: add bidi reordering of runs", dict(spec=S("UAX9", "reordering"))),
    ("unicode: add script itemisation", {}),
    ("unicode: run the conformance test files in CI", {}),
    ("unicode: measure table size and compress with two-stage tables", dict(tg="E2")),
])
lane("P07", "text-layout", ["shaping", "unicode"], U("layout.textAvail, fonts.Mono.wrap"), "H1", "golden images match", [
    ("text: break shaped runs into lines", {}),
    ("text: add alignment and justification", {}),
    ("text: add ellipsis and maximum lines", {}),
    ("text: add rich text spans", {}),
    ("text: add position-to-index and index-to-position queries", {}),
    ("text: plug the full stack into the measure / wrap protocol", dict(ref=U("Frame.end: where a shaper slots in"))),
    ("text: add text layout tests", dict(key="text-layout-done")),
])
lane("P07", "font-fallback", ["text-layout"], R("SLINT", "platform text integration") + "; " + R("GPUI", "OS text systems"), "H1", "mixed-script sample renders", [
    ("fallback: add fallback chain per script", {}),
    ("fallback: discover system fonts on Windows (DirectWrite)", dict(spec=S("WIN32", "DirectWrite font enumeration"))),
    ("fallback: discover system fonts on macOS (Core Text)", dict(spec=S("APPKIT", "Core Text font descriptors"))),
    ("fallback: discover system fonts on Linux (fontconfig)", {}),
    ("fallback: add fallback tests", {}),
])
lane("P07", "text-edit", ["text-layout", "keyboard"], R("ICED_REL", "input method support") + "; " + R("DVUI", "text entry"), "H1", "editing tests pass with replayed input", [
    ("edit: add text buffer with a gap", {}),
    ("edit: move the caret by grapheme, word and line", dict(spec=S("UAX29"))),
    ("edit: add selection with keyboard and pointer", {}),
    ("edit: add cut, copy and paste", dict(ref=U("Platform.clipboard"))),
    ("edit: add undo and redo", {}),
    ("edit: add IME composition with a preedit range", dict(ref=U("Platform.wants_text, Platform.ime_rect"))),
    ("edit: add password and single-line modes", {}),
    ("edit: add bidi-aware caret movement", dict(spec=S("UAX9"))),
    ("edit: add editing tests", dict(key="text-edit-done")),
])

# =============================================================================
# P08 Renderers
# =============================================================================
lane("P08", "render-iface", ["draw-core", "golden"], W("Binding, Renderer"), "G6", "null back end passes the conformance scenes", [
    ("render: define the back-end contract (prepare, draw batch, draw text, custom)", dict(ref=W("Renderer.prepare, drawBatch, drawText, render"))),
    ("render: add conformance scenes with golden images", dict(ref=R("CHK", "wgpu pixel check scene"))),
    ("render: add null back end that records calls", dict(ref=W("Mock"))),
    ("render: document the three custom-rendering routes", dict(ref=R("QT_NODE", "underlay, texture, inline") + "; " + R("EGUI_CB"))),
    ("render: require full state rebinding after custom draws", dict(ref=W("Renderer.bind"), key="render-iface")),
])
lane("P08", "shaders", ["render-iface"], W("shader(), shader_head, shader_tail"), "G3", "all shader variants validate in CI", [
    ("shaders: keep WGSL as the single source", dict(ref=W("shader()"), spec=S("WGSL"))),
    ("shaders: translate to SPIR-V, MSL, HLSL and GLSL at build time", {}),
    ("shaders: validate every variant in CI", dict(ref=R("CHK", "WGSL validated by drawing on a software adapter"))),
    ("shaders: add material API (user fragment function)", dict(ref=W("addMaterial, default_material") + "; " + R("ICED_SHADER"))),
    ("shaders: add shader tests", dict(key="shaders")),
])
lane("P08", "render-sw", ["render-iface", "glyph-raster"], M("D3") + "; " + R("DEVTO", "memory saved by a software renderer") + "; " + R("SLINT", "software renderer"), "D3", "conformance scenes match golden images", [
    ("sw: add framebuffer abstraction (RGBA8, BGRA8)", {}),
    ("sw: fill opaque rects with SIMD spans", dict(ref=U("simd"))),
    ("sw: blend premultiplied spans", dict(spec=S("PD"))),
    ("sw: add rounded-rect coverage from the same distance function as the shader", dict(ref=W("rounded_box"))),
    ("sw: add borders", {}),
    ("sw: apply per-quad clip rects", dict(ref=U("Quad.clip"))),
    ("sw: blit glyph coverage", {}),
    ("sw: blit and scale images", {}),
    ("sw: add gradients", {}),
    ("sw: redraw only the damage region", dict(needs=["damage-done"], tg="D4")),
    ("sw: split work into tiles across threads", {}),
    ("sw: pass the conformance scenes", dict(key="render-sw-done")),
])
lane("P08", "render-wgpu", ["shaders"], W("Renderer(gpu)") + "; " + R("SLINT_WGPU", "per-version wgpu modules"), "G4", "pixel check passes on a software adapter", [
    ("wgpu: port Renderer(gpu) and its mock test", dict(ref=W("Renderer, test \"renderer: one upload per buffer...\""))),
    ("wgpu: add wgpu-native binding adapter through translated C headers", dict(ref=W("Binding") + "; " + R("ZIG17", "@cImport removed"))),
    ("wgpu: create pipelines with the documented layouts", dict(ref=W("Renderer.PipelineDesc, quad_attrs"))),
    ("wgpu: configure the surface and handle resize", {}),
    ("wgpu: add texture registry", dict(ref=W("addTexture"))),
    ("wgpu: add glyph buffer and atlas texture", dict(ref=W("Glyphs, drawText"))),
    ("wgpu: add optional multisampling", {}),
    ("wgpu: gate the wgpu version behind a build option", dict(ref=R("SLINT_WGPU", "one module per wgpu major"))),
    ("wgpu: pass the conformance scenes", dict(ref=R("CHK", "wgpu pixel check"), key="render-wgpu-done")),
])
lane("P08", "render-vk", ["shaders"], R("ZED_WGPU", "why a thin back end matters for memory") + "; " + W("Binding (contract to satisfy)"), "D1", "conformance scenes pass on a software Vulkan driver", [
    ("vk: load the Vulkan library and create an instance", dict(spec=S("VK", "instance creation"))),
    ("vk: pick a device and queue", dict(spec=S("VK", "physical device selection"))),
    ("vk: create the swapchain", dict(spec=S("VK", "WSI swapchain"))),
    ("vk: record with dynamic rendering", dict(spec=S("VK", "dynamic rendering"))),
    ("vk: create the quad pipeline from SPIR-V", {}),
    ("vk: upload instances through a persistently mapped ring buffer", dict(ref=W("Renderer.prepare"))),
    ("vk: add descriptor sets for globals and textures", {}),
    ("vk: add frame synchronisation and present", {}),
    ("vk: handle resize and device loss", {}),
    ("vk: expose the command buffer for inline custom draws", dict(ref=R("QT_NODE", "inline approach") + "; " + U("Cmd.custom"), tg="G4")),
    ("vk: measure memory of an empty window against wgpu", dict(ref=R("ZED_WGPU", "100 MB against 10 MB report"))),
    ("vk: pass the conformance scenes", dict(key="render-vk-done")),
])
lane("P08", "render-metal", ["shaders"], R("GPUI", "Metal renderer on macOS") + "; " + W("Binding"), "D1", "conformance scenes pass on macOS CI", [
    ("metal: create device and layer", dict(spec=S("APPKIT", "Metal layer"))),
    ("metal: create the quad pipeline from MSL", {}),
    ("metal: upload instances", {}),
    ("metal: add textures and samplers", {}),
    ("metal: present with display link timing", {}),
    ("metal: expose the encoder for inline custom draws", dict(tg="G4")),
    ("metal: handle resize and scale changes", {}),
    ("metal: pass the conformance scenes", {}),
])
lane("P08", "render-d3d12", ["shaders"], R("GPUI", "DirectX renderer on Windows") + "; " + W("Binding"), "D1", "conformance scenes pass on the software rasteriser (WARP)", [
    ("d3d12: create device and flip-model swapchain", dict(spec=S("D3D12", "DXGI flip model"))),
    ("d3d12: create root signature and pipeline state from HLSL", {}),
    ("d3d12: upload instances through an upload heap", {}),
    ("d3d12: add descriptor heap for textures", {}),
    ("d3d12: present with a waitable swapchain", dict(tg="F3")),
    ("d3d12: expose the command list for inline custom draws", dict(tg="G4")),
    ("d3d12: handle resize and device removal", {}),
    ("d3d12: pass the conformance scenes", {}),
])
lane("P08", "render-gles", ["shaders"], R("SLINT", "FemtoVG on OpenGL ES 2.0") + "; " + R("LVGL", "small-device constraints"), "D2", "conformance scenes pass on a software GL driver", [
    ("gles: create an EGL context", dict(spec=S("GLES", "EGL"))),
    ("gles: compile the GLSL ES variant", {}),
    ("gles: draw instanced quads", {}),
    ("gles: add textures", {}),
    ("gles: add a path without instancing for GL ES 2", {}),
    ("gles: pass the conformance scenes", {}),
])
lane("P08", "render-web", ["shaders"], R("DVUI", "web back end") + "; " + R("CLAY", "wasm build"), "E2", "example runs in a browser test", [
    ("web: add minimal JavaScript glue for wasm", {}),
    ("web: draw through WebGPU", dict(spec=S("WEBGPU"))),
    ("web: add 2D-canvas fallback from the software renderer", dict(needs=["render-sw-done"])),
    ("web: measure wasm size", dict(ref=R("CLAY", "15 kB wasm claim for layout alone"))),
    ("web: add browser smoke test", {}),
])
lane("P08", "render-gompute", ["render-sw-done"], R("GOMPUTE", "kernels, CPU fallback, embedded PTX and HSACO") + "; " + R("CUDARASTER", "compute rasteriser within 2 to 8 times of hardware"), "G6", "decision record written with measurements", [
    ("gompute: pin a Gompute revision that builds with the project's Zig", dict(ref=R("GOMPUTE", "abd75e4 is the last build for Zig 0.17"))),
    ("gompute: express the tile rasteriser as kernels that also run on the CPU", dict(ref=R("GOMPUTE", "kernels are plain Zig functions"))),
    ("gompute: launch the kernels on CUDA and HIP", {}),
    ("gompute: present by reading back to a CPU framebuffer", dict(ref=R("CUDA_INTEROP", "no presentation in CUDA itself"))),
    ("gompute: present through Vulkan external memory where available", dict(ref=R("CUDA_INTEROP", "Vulkan interoperability"), needs=["render-vk-done"])),
    ("gompute: measure context memory and start-up against Vulkan", {}),
    ("gompute: measure frame time against the software and Vulkan back ends", dict(ref=R("CHK", "benchmark scene"))),
    ("gompute: record the decision (keep as offscreen and heavy-effects back end, or drop)", {}),
])

# =============================================================================
# P09 Platform shells
# =============================================================================
lane("P09", "shell-iface", ["context-done", "scheduler-done"], U("Input, Platform, Output") + "; " + R("CASEY_API", "the caller owns the loop"), "G7", "headless shell runs the example", [
    ("shell: define the host contract (poll events into Input, apply Platform)", dict(ref=U("Input, Platform"))),
    ("shell: add headless shell for tests", dict(ref=E("frame()"))),
    ("shell: add run() as a short loop over the contract", dict(ref=R("CASEY_API", "redundancy: a shortcut for the common case"))),
    ("shell: document how to embed in an existing loop", dict(ref=R("DVUI", "on top of an existing application"))),
    ("shell: add wake from other threads", dict(key="shell-iface")),
])
PLATFORMS = [
    ("win32", "Windows", S("WIN32"), R("GPUI", "Win32 windowing"), [
        "create a window and pump messages without owning the loop",
        "translate mouse, wheel and keyboard messages into Input",
        "handle per-monitor DPI and scale changes",
        "set cursors from Platform output",
        "add clipboard read and write",
        "add IME through the text-input framework",
        "add timers and cross-thread wake",
        "add multiple windows",
        "add file drop",
        "follow system dark mode and accent colour",
    ]),
    ("macos", "macOS", S("APPKIT"), R("GPUI", "macOS platform layer"), [
        "create a window and view through the Objective-C runtime",
        "translate events into Input",
        "handle backing scale changes",
        "set cursors from Platform output",
        "add pasteboard read and write",
        "add IME through the text input client protocol",
        "add timers and cross-thread wake",
        "add multiple windows and the menu bar",
        "add file drop",
        "follow system appearance",
    ]),
    ("wayland", "Wayland", S("WAYLAND"), R("GPUI", "Wayland support") + "; " + R("ZED_WGPU", "Wayland issues that drove the change"), [
        "connect and create an xdg toplevel",
        "translate pointer, keyboard (xkb) and touch events into Input",
        "handle fractional scale",
        "set cursors from Platform output",
        "add clipboard through data devices",
        "add IME through text-input",
        "add timers and cross-thread wake",
        "add multiple windows and popups",
        "add file drop",
        "add client-side decorations or the decoration protocol",
    ]),
    ("x11", "X11", S("XCB"), R("GPUI", "X11 support"), [
        "connect and create a window",
        "translate events into Input with xkb",
        "handle DPI from resources and RandR",
        "set cursors from Platform output",
        "add clipboard through selections",
        "add IME through XIM or IBus",
        "add timers and cross-thread wake",
        "add multiple windows",
        "add file drop through XDND",
    ]),
    ("web", "web", S("WEBGPU"), R("DVUI", "web back end"), [
        "attach to a canvas and animation frames",
        "translate DOM events into Input",
        "handle device pixel ratio",
        "set cursors through CSS",
        "add clipboard through the async API",
        "add IME through a hidden input element",
        "add timers and wake",
    ]),
    ("android", "Android", S("NDK"), R("SLINT", "Android support") + "; " + R("MAKEPAD", "mobile targets"), [
        "create a native activity surface",
        "translate touch and key events into Input",
        "handle density and insets",
        "add clipboard through JNI",
        "add the soft keyboard and IME",
        "handle pause, resume and surface loss",
    ]),
    ("ios", "iOS", S("UIKIT"), R("SLINT", "mobile support") + "; " + R("MAKEPAD", "mobile targets"), [
        "create a view with a Metal layer",
        "translate touches into Input",
        "handle scale and safe areas",
        "add pasteboard",
        "add the soft keyboard and IME",
        "handle backgrounding",
    ]),
    ("baremetal", "bare metal", "", R("LVGL", "tick, flush and input driver model") + "; " + R("SLINT_MCU"), [
        "define the flush interface for a framebuffer or a line buffer",
        "define the touch and encoder input interface",
        "define the tick source",
        "add a simulator shell on the desktop",
    ]),
]
for pkey, pname, pspec, pref, steps in PLATFORMS:
    lane("P09", f"shell-{pkey}", ["shell-iface"], pref, "G7", f"example runs on {pname}; input replay test passes", [
        (f"{pkey}: {s}", dict(spec=pspec)) for s in steps
    ] + [(f"{pkey}: add platform test job and example", dict(ref=R("CHK", "test matrix")))])

# =============================================================================
# P10 Widgets
# =============================================================================
lane("P10", "widget-base", ["context-done", "ct-events", "text-protocol-done"], U("widgets, Theme") + "; " + R("CASEY_API", "widgets use only the public API"), "G1", "four reference widgets pass their tests in both front ends", [
    ("widgets: define the five-commit recipe (spec, look, behaviour, accessibility, tests)", dict(ref=U("widgets section comment"))),
    ("widgets: add Theme with default tokens", dict(ref=U("Theme"))),
    ("widgets: add state-indexed colour tables", dict(ref=U("widgets.button: fills[...]"))),
    ("widgets: add shared helpers that stay public (unit clamp, state index)", dict(ref=U("widgets.unit"))),
    ("widgets: add the widget test harness with replayed input and golden images", dict(key="widget-base")),
])
WIDGETS = [
    # key, name, needs, pattern, behaviour, role, ref
    ("label", "label", [], "", "none (static text)", "label", U("widgets.label")),
    ("button", "button", [], "button", "click, Enter and Space", "button", U("widgets.button")),
    ("checkbox", "checkbox", [], "checkbox", "toggle on click and Space; mixed state", "checkbox", U("widgets.checkbox")),
    ("slider", "slider", [], "slider", "drag, arrows, Home and End", "slider", U("widgets.slider, Frame.heldRect")),
    ("icon", "icon", [], "", "none", "image", R("DVUI", "icon support")),
    ("image", "image", ["images"], "", "none", "image", U("Quad.uv, Style.texture")),
    ("separator", "separator", [], "", "none", "separator", U("Frame.leaf")),
    ("spacer", "spacer", [], "", "none", "none", U("Size.fill")),
    ("toggle", "toggle button", [], "button", "pressed state on click", "toggle button", U("widgets.button")),
    ("radio", "radio group", [], "radio group", "arrows move and select", "radio group", U("widgets.checkbox")),
    ("switch", "switch", [], "switch", "toggle on click and Space", "switch", U("widgets.checkbox, Frame.animate")),
    ("range", "range slider", [], "slider (multi-thumb)", "two thumbs, arrows per thumb", "slider", U("widgets.slider")),
    ("progress", "progress bar", [], "meter", "none", "progress indicator", U("widgets.slider (track and fill)")),
    ("spinner", "spinner", [], "", "none; animates", "progress indicator", U("Frame.animate")),
    ("textfield", "text field", ["text-edit-done"], "textbox", "editing, selection, IME", "text input", U("Platform.wants_text, Role.text_input")),
    ("textarea", "text area", ["text-edit-done"], "textbox (multiline)", "multiline editing and scrolling", "multiline text input", U("Platform.ime_rect")),
    ("number", "number field", ["text-edit-done"], "spinbutton", "typing, arrows, wheel", "spin button", U("widgets.slider")),
    ("search", "search field", ["text-edit-done"], "searchbox", "editing with clear button", "search box", U("widgets.button")),
    ("scroll", "scroll area", [], "", "wheel, drag thumb, keyboard paging", "scroll view", U("Style.scroll, Style.clip")),
    ("list", "list", [], "listbox", "arrows, type-ahead, selection", "list box", U("Frame.reuse")),
    ("vlist", "virtual list", [], "listbox", "as list; builds only visible rows", "list box", R("XILEM_VS") + "; " + M("E1")),
    ("select", "select", [], "combobox (select-only)", "open, arrows, Enter, Escape", "combo box", U("Style.float, Style.offset")),
    ("combobox", "combo box", ["text-edit-done"], "combobox", "typing filters; arrows pick", "combo box", U("Style.float")),
    ("menu", "menu", [], "menu", "arrows, Enter, Escape, submenus", "menu", U("Style.float")),
    ("menubar", "menu bar", [], "menubar", "left and right move between menus", "menu bar", U("widgets.button")),
    ("contextmenu", "context menu", [], "menu", "opens on secondary click and menu key", "menu", U("Input.Buttons.right")),
    ("tooltip", "tooltip", [], "tooltip", "hover delay; Escape closes", "tooltip", U("Frame.lastRect")),
    ("popover", "popover", [], "dialog (non-modal)", "click outside and Escape close", "dialog", U("Style.float")),
    ("dialog", "dialog", [], "dialog (modal)", "focus trap; Escape closes", "dialog", U("Interaction.focus")),
    ("toast", "toast", [], "alert", "times out; pause on hover", "alert", U("Frame.animate")),
    ("tabs", "tabs", [], "tabs", "arrows move; activation on focus or Enter", "tab list", U("widgets.button")),
    ("accordion", "accordion", [], "accordion", "Enter and Space expand", "group with buttons", U("Frame.animate")),
    ("tree", "tree view", [], "tree view", "arrows expand, collapse and move", "tree", U("Tree.Columns.end (subtree ranges)")),
    ("table", "table", [], "grid", "cell navigation, sort, resize columns", "grid", R("DVUI", "data grid")),
    ("splitter", "splitter", [], "window splitter", "drag and arrows resize panes", "separator (focusable)", U("Frame.drag")),
    ("toolbar", "toolbar", [], "toolbar", "one tab stop; arrows inside", "toolbar", U("widgets.button")),
    ("statusbar", "status bar", [], "", "none", "status", U("widgets.label")),
    ("breadcrumb", "breadcrumb", [], "breadcrumb", "links activate on Enter", "navigation", U("widgets.button")),
    ("chip", "chip", [], "", "optional remove button", "button or static text", U("widgets.button")),
    ("card", "card and group box", [], "", "none", "group", U("Frame.open")),
    ("colorpicker", "colour picker", [], "", "2D drag area plus sliders", "group with sliders", U("widgets.slider, Style.material")),
    ("datepicker", "date picker", ["text-edit-done"], "date picker dialog", "grid navigation by day, week, month", "dialog with grid", U("Style.float")),
]
for wkey, wname, wneeds, pattern, behaviour, role, wref in WIDGETS:
    pat = S("APG", f"{pattern} pattern") if pattern else ""
    lane("P10", f"w-{wkey}", ["widget-base"] + wneeds, wref, "G1", f"{wname}: replay test and golden image pass in both front ends", [
        (f"{wkey}: add spec, state and compile-time validation", dict(ref=wref + "; " + K("flatten: binding checks"))),
        (f"{wkey}: lay out and paint in the default theme", dict(ref=wref, tg="G2")),
        ((f"{wkey}: handle input ({behaviour})" if not behaviour.startswith("none") else f"{wkey}: take no input; verify hit testing and tab order skip it"), dict(ref=wref if not behaviour.startswith("none") else U("hit.at, Sense"), spec=pat, tg="A3")),
        (f"{wkey}: expose role ({role}), name, value and states", dict(ref=U("Role, Tree.Columns.role, Tree.Columns.value"), spec=pat, tg="H2")),
        (f"{wkey}: add example page, replay test and golden image", dict(ref=E("test style: scripted input, exact expectations"))),
    ])

# =============================================================================
# P11 Animation
# =============================================================================
lane("P11", "anim", ["context-done"], U("Anims, Spring"), "F2", "spring test passes; idle after rest", [
    ("anim: add spring columns and slot()", dict(ref=U("Anims.slot"))),
    ("anim: add SIMD step()", dict(ref=U("Anims.step"))),
    ("anim: add sweep() by stream compaction", dict(ref=U("Anims.sweep"))),
    ("anim: add Frame.animate", dict(ref=U("Frame.animate"))),
    ("anim: add tweens with an easing table", dict(ref=R("FLOEM", "transitions and keyframes"))),
    ("anim: add transitions on style change", dict(ref=R("ICED_REL", "animation API"))),
    ("anim: add keyframe sequences", {}),
    ("anim: animate layout changes from the last rect", dict(ref=U("Frame.lastRect"))),
    ("anim: honour the reduced-motion setting", {}),
    ("anim: size spring arrays at comptime in the comptime front end", dict(ref=K("exact arrays"), needs=["ct-layout-done"])),
    ("anim: port the spring test", dict(ref=E('test "springs keep the host awake until they land"'))),
])

# =============================================================================
# P12 Accessibility
# =============================================================================
lane("P12", "a11y-core", ["context-done", "focus"], U("Role, Tree.Columns.role, Tree.Columns.value") + "; " + M("H2"), "H2", "tree export test passes", [
    ("a11y: complete the role set", dict(spec=S("APG", "roles used by the patterns"))),
    ("a11y: compute accessible names from labels and text children", {}),
    ("a11y: add states (checked, expanded, selected, disabled)", {}),
    ("a11y: export the semantic tree as flat arrays", dict(ref=U("Output.tree"))),
    ("a11y: diff against last frame and emit only changes", dict(ref=U("Context.trees (two generations)"))),
    ("a11y: accept actions (press, focus, set value) as input events", dict(ref=R("CASEY_API", "no callbacks: actions arrive as data"))),
    ("a11y: add export tests", dict(key="a11y-core")),
])
lane("P12", "a11y-bridge", ["a11y-core", "shell-iface"], R("ACCESSKIT") + "; " + R("SLINT_A11Y") + "; " + R("DVUI", "AccessKit integration") + "; " + R("DIOXUS", "accessibility feature"), "H2", "screen reader announces the example on each platform", [
    ("a11y: add AccessKit adapter through its C interface", {}),
    ("a11y: convert tree diffs into AccessKit updates", {}),
    ("a11y: route AccessKit action requests into Input", {}),
    ("a11y: wire the Windows adapter", dict(spec=S("UIA"))),
    ("a11y: wire the macOS adapter", dict(spec=S("APPKIT", "NSAccessibility"))),
    ("a11y: wire the Linux adapter", dict(spec=S("ATSPI"))),
    ("a11y: add screen-reader smoke tests", {}),
])
lane("P12", "a11y-settings", ["a11y-core"], M("H2"), "H2", "settings tests pass", [
    ("a11y: add high-contrast theme switch", {}),
    ("a11y: add text scaling", {}),
    ("a11y: add reduced motion", {}),
    ("a11y: always show focus for keyboard users", {}),
    ("a11y: add compile-time lint rules for the comptime front end", dict(ref=K("flatten: @compileError checks"))),
    ("a11y: add contrast check for theme tokens", {}),
])

# =============================================================================
# P13 Styling and theming
# =============================================================================
lane("P13", "theme", ["widget-base"], U("Theme, Style") + "; " + M("G2"), "G2", "theme switch test passes", [
    ("theme: add design tokens (colour, space, radius, type scale)", dict(ref=U("Theme"))),
    ("theme: add state style tables indexed by interaction bits", dict(ref=U("widgets.button: fills[...]"))),
    ("theme: add light and dark themes", {}),
    ("theme: add density settings", {}),
    ("theme: fold comptime themes into constants", dict(ref=K("read-only tables"))),
    ("theme: switch themes at run time through palette indices", {}),
    ("theme: inherit text colour and size down the tree", {}),
    ("theme: allow per-widget overrides", dict(ref=R("CASEY_API", "granularity"))),
    ("theme: add custom material example", dict(ref=W("shader(), addMaterial") + "; " + R("MAKEPAD", "shader-styled widgets"))),
    ("theme: add theme tests", {}),
])

# =============================================================================
# P14 Assets and internationalisation
# =============================================================================
lane("P14", "images", ["render-iface"], U("Style.texture, Quad.uv") + "; " + W("addTexture"), "D1", "decoder tests pass; fuzzing clean", [
    ("images: decode PNG", dict(spec=S("PNG"))),
    ("images: embed assets at comptime", {}),
    ("images: decode on a background thread and wake", dict(tg="F1")),
    ("images: pack small images into an atlas", dict(ref=R("QT_RENDERER", "texture atlas"))),
    ("images: generate mipmaps where the back end samples them", {}),
    ("images: fuzz the decoder", {}),
    ("images: add image tests", dict(key="images")),
])
lane("P14", "i18n", ["text-layout-done"], M("H1"), "H1", "catalogue tests pass", [
    ("i18n: add message catalogues checked at comptime", {}),
    ("i18n: add plural selection", {}),
    ("i18n: add number formatting", {}),
    ("i18n: add date formatting", {}),
    ("i18n: switch language at run time", {}),
    ("i18n: add pseudo-localisation test mode", {}),
])

# =============================================================================
# P15 Performance and footprint gates
# =============================================================================
lane("P15", "bench-scenes", ["context-done", "bench"], R("CHK", "benchmark scene") + "; " + R("MX", "Targets tab"), "E2", "scenes run headless and print numbers", [
    ("bench: add static form scene (200 nodes)", {}),
    ("bench: add long list scene (100,000 rows, virtualised)", dict(ref=M("E1"))),
    ("bench: add text-heavy scene", {}),
    ("bench: add animation scene (1,000 springs)", dict(ref=U("Anims.step"))),
    ("bench: add resize storm scene", {}),
    ("bench: add idle scene", dict(ref=M("D5"), key="bench-scenes")),
])
COMPETITORS = [
    ("clay", "Clay", R("CLAY")),
    ("imgui", "Dear ImGui", R("IMGUI_IDLE")),
    ("egui", "egui", R("EGUI")),
    ("slint", "Slint", R("SLINT")),
    ("lvgl", "LVGL", R("LVGL")),
    ("iced", "Iced", R("ICED_REL")),
    ("qtquick", "Qt Quick", R("QT_RENDERER")),
]
for ckey, cname, cref in COMPETITORS:
    lane("P15", f"vs-{ckey}", ["bench-scenes"], cref + "; " + R("MX", f"Matrix row for {cname}"), "E2", f"{cname} numbers recorded on the same machine", [
        (f"bench: port the scenes to {cname}", {}),
        (f"bench: automate {cname} measurement (frame time, memory, binary size, idle)", {}),
    ])
lane("P15", "gates", ["bench-scenes", "gates-doc"] + [f"vs-{c[0]}" for c in COMPETITORS], R("MX", "Targets tab") + "; " + R("CHK", "measured baselines"), "E2", "CI fails when a gate regresses", [
    ("gates: frame CPU time no worse than the fastest comparison on each scene", {}),
    ("gates: resident memory no worse than the lightest comparison on each scene", dict(ref=R("DEVTO", "what counts as resident memory"))),
    ("gates: binary size budget per example", dict(ref=M("E2"))),
    ("gates: time to first frame budget", {}),
    ("gates: zero wakeups in the idle scene", dict(ref=M("D5"))),
    ("gates: input-to-photon latency budget", {}),
    ("gates: compile-time budget for the comptime front end", {}),
    ("gates: no conditional jumps in per-row loops", dict(ref=R("CHK", "branch census"))),
    ("gates: publish the comparison table with methods", dict(key="gates")),
])
lane("P15", "optimise", ["bench-scenes"], R("CHK", "per-pass timings") + "; " + R("ACTON", "measure, then change the data"), "B2", "each commit states before and after numbers", [
    ("perf: profile cache misses per pass", {}),
    ("perf: build rows from style templates with one copy", dict(ref=U("Tree.push: about 36 ns per node in the benchmark"))),
    ("perf: regroup columns by measured access", dict(ref=U("Look (already grouped)"))),
    ("perf: vectorise quad emission for runs of visible nodes", dict(ref=U("paint.emit sweep 1"))),
    ("perf: try huge pages for the column buffer", {}),
    ("perf: reduce bytes per node and record the result", dict(ref=R("CHK", "0.65 KB per node of capacity"))),
    ("perf: review every scalar sweep for dependency-chain length", dict(ref=R("CHK", "resolve is latency-bound"))),
])

# =============================================================================
# P16 Tooling and developer experience
# =============================================================================
lane("P16", "devtools", ["widget-base", "render-sw-done"], U("Output.tree, DrawList") + "; " + R("CLAY", "built-in debug tools"), "G1", "inspector runs inside the example", [
    ("devtools: add inspector overlay built with the framework", {}),
    ("devtools: draw layout rects and clip rects", dict(ref=U("Tree.Columns.rect, Tree.Columns.vis"))),
    ("devtools: add per-pass timing display", dict(ref=R("CHK", "per-pass timers"))),
    ("devtools: add event log", {}),
    ("devtools: show draw batches and overdraw", {}),
    ("devtools: show signal changes and reuse decisions", dict(ref=U("Frame.reuse"))),
    ("devtools: record and replay sessions", {}),
])
lane("P16", "docs", ["widget-base"], R("API") + "; " + U("doc comments"), "G1", "docs build in CI", [
    ("docs: generate the API index in the build", dict(ref=R("API", "how it was generated"))),
    ("docs: write the comptime front end guide", dict(ref=K("usage section"))),
    ("docs: write the runtime front end guide", dict(ref=E("buildUi"))),
    ("docs: write the custom rendering guide", dict(ref=W("file header: RAW GPU ACCESS"))),
    ("docs: write the text protocol guide", dict(ref=U("fonts section comment"))),
    ("docs: write the porting guide for a new platform", {}),
    ("docs: write the performance guide with measured numbers", dict(ref=R("CHK"))),
    ("docs: catalogue compile errors with fixes", {}),
])
lane("P16", "examples", ["widget-base", "shell-iface"], E("buildUi, render"), "G1", "every example builds and has a smoke test", [
    ("examples: hello window", {}),
    ("examples: counter with signals", {}),
    ("examples: form with validation", {}),
    ("examples: list with 100,000 rows", {}),
    ("examples: dashboard with charts as custom draws", dict(ref=U("Frame.custom"))),
    ("examples: 3D viewport under the UI", dict(ref=E("id_viewport") + "; " + R("QT_UNDER"))),
    ("examples: UI rendered into a texture", dict(ref=W("file header: texture out"))),
    ("examples: microcontroller demo in the simulator", dict(needs=["shell-baremetal"])),
])

# =============================================================================
# P17 Embedded profile
# =============================================================================
lane("P17", "embedded", ["render-sw-done", "ct-layout-done", "shell-baremetal"], R("LVGL", "64 kB flash and tens of kB RAM minimum") + "; " + R("SLINT_MCU") + "; " + M("E3"), "E3", "demo fits the stated flash and RAM budget", [
    ("embedded: build freestanding without the standard library's I/O", {}),
    ("embedded: add fixed-point coordinates as a build option", dict(ref=K("Runtime.rect: i16"))),
    ("embedded: add RGB565 and 1-bit framebuffers", {}),
    ("embedded: render line by line without a full framebuffer", dict(ref=R("SLINT", "line-by-line rendering"))),
    ("embedded: flush only damaged regions", dict(ref=M("D4"))),
    ("embedded: subset fonts at comptime", {}),
    ("embedded: add a build without floating point", {}),
    ("embedded: add flash and RAM budget tests", dict(ref=R("LVGL"))),
    ("embedded: add a generic SPI display driver interface", {}),
    ("embedded: add board example in the simulator", {}),
])

# =============================================================================
# P18 Release engineering
# =============================================================================
lane("P18", "release", ["gates", "a11y-core"], R("CASEY_API", "evaluation checklist") + "; " + R("MX", "target H3"), "H3", "release checklist complete", [
    ("release: review every public API against the five characteristics", dict(ref=R("CASEY_API"))),
    ("release: review names and module boundaries against the code standard", {}),
    ("release: define the versioning and deprecation policy", dict(ref=R("GOMPUTE", "only adding features as a stability policy"))),
    ("release: package options in build.zig", dict(ref=R("ZIG17_BUILD"))),
    ("release: audit licences of optional dependencies", {}),
    ("release: write the changelog process", {}),
    ("release: publish docs and the comparison table", dict(needs=["docs"])),
])
ALL_LANES = [L["name"] for L in LANES]
lane("P18", "milestones", ["widget-base", "render-sw-done", "render-wgpu-done", "shell-win32", "ct-layout-done"], R("MX", "target H3: stable 1.0+ API"), "H3", "tag pushed; gates recorded for the tag", [
    ("release: tag 0.1 (core, both front ends, software and wgpu back ends, first desktop shell)", {}),
    ("release: tag 0.5 (all desktop shells, text stack, accessibility bridge, native GPU back ends)", dict(needs=["shell-macos", "shell-wayland", "shell-x11", "text-edit-done", "a11y-bridge", "render-vk-done", "render-metal", "render-d3d12", "theme"])),
    ("release: tag 1.0 when every lane is merged and every gate has held for three months", dict(needs=ALL_LANES)),
])

# =============================================================================
# Resolve, order, compute waves
# =============================================================================
commits = []
lane_first, lane_last, keys = {}, {}, {}
n = 0
for L in LANES:
    for i, c in enumerate(L["commits"]):
        title, o = (c, {}) if isinstance(c, str) else c
        n += 1
        cid = f"C{n:04d}"
        commits.append(dict(id=cid, title=title, phase=L["phase"], lane=L["name"], pos=i,
                            ref=o.get("ref", L["ref"]), spec=o.get("spec", ""), tg=o.get("tg", L["tg"]),
                            done=o.get("done", L["done"]), extra=o.get("needs", []), lane_needs=L["needs"]))
        if i == 0:
            lane_first[L["name"]] = cid
        lane_last[L["name"]] = cid
        if "key" in o:
            assert o["key"] not in keys, o["key"]
            keys[o["key"]] = cid


def resolve(name):
    if name in keys:
        return keys[name]
    assert name in lane_last, f"unknown prerequisite {name}"
    return lane_last[name]


by_id = {c["id"]: c for c in commits}
prev = None
for c in commits:
    deps = []
    if c["pos"] == 0:
        deps += [resolve(x) for x in c["lane_needs"]]
    else:
        deps.append(prev["id"])
    deps += [resolve(x) for x in c["extra"]]
    c["deps"] = sorted(set(deps))
    prev = c

# waves: longest path from a commit with no prerequisites
wave = {}


def w(cid, stack=()):
    assert cid not in stack, f"cycle at {cid}"
    if cid not in wave:
        wave[cid] = 1 + max((w(d, stack + (cid,)) for d in by_id[cid]["deps"]), default=0)
    return wave[cid]


for c in commits:
    c["wave"] = w(c["id"])
unblocks = {c["id"]: [] for c in commits}
for c in commits:
    for d in c["deps"]:
        unblocks[d].append(c["id"])
tail = {}


def t(cid):
    if cid not in tail:
        tail[cid] = 1 + max((t(x) for x in unblocks[cid]), default=0)
    return tail[cid]


last_wave = max(wave.values())
for c in commits:
    c["unblocks"] = len(unblocks[c["id"]])
    c["critical"] = (c["wave"] + t(c["id"]) - 1) == last_wave

json.dump(dict(commits=commits, phases=PHASES, lanes=[dict(phase=L["phase"], name=L["name"], needs=L["needs"]) for L in LANES]),
          open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "generated.json"), "w"), indent=1)

from collections import Counter
print("commits:", len(commits), "lanes:", len(LANES), "waves:", last_wave)
print("critical-path commits:", sum(c["critical"] for c in commits))
pc = Counter(c["phase"] for c in commits)
for p in sorted(pc):
    ws = [c["wave"] for c in commits if c["phase"] == p]
    print(f"  {p} {PHASES[p][0]:36s} {pc[p]:4d} commits, waves {min(ws)}-{max(ws)}")
wc = Counter(c["wave"] for c in commits)
print("widest wave:", max(wc.values()), "commits in parallel; median width", sorted(wc.values())[len(wc) // 2])
missing = [c["id"] for c in commits if not c["ref"]]
print("commits without a reference:", len(missing))
