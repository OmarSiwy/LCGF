# LCGF C++ bindings: redesign plan (v3)

Planning document from a read-only study of `main` @ 141d297d (planner: plan-cpp, 2026-11-26). No code was edited and no benchmarks were run; every speed claim is a hypothesis with the measurement that settles it. The erratum agreed with the Rust planner is applied: the `src/abi/` design is the shared one in `docs/plans/bindings-rust.md` §6, and `tools/abi-gen` (the emitter shared by C, C++ and Rust) is specified there too.

**Main finding: the toolbar gap is not a C++ cost.** Toolbar C++ runs at about 1134 ns per frame against about 976 ns for Zig comptime. The C++ benchmark times `ui.frame()` in `check.cpp:104-113`, which is one `LCGF_FRAME` call into Zig's own seam frame. Each frame, that seam frame re-decodes every row, rebuilds its `Style` from words and runs `Template.from` again (`seam.zig:352-357`, `plan.zig:510-521`). `ComptimeUi` has all of that folded at compile time. No change to C++ code can close this gap; the seam row cache (WP0.5 in both plans) and the spec-UI decision attack it.

## 0. Decisions

| # | Decision | Per-frame effect |
|---|---|---|
| D1 | `tools/abi-gen` (shared) writes `lcgf.h`, `lcgf/types.hpp` with the C++ wrappers, and `sys.rs`, all from the one export list in `src/abi/api.zig`. Outputs are committed; `zig build test` fails when they are stale. | 0 |
| D2 | `src/abi` becomes the Zig API in C form, per `bindings-rust.md` §6. | Same as today: one direct call per call |
| D3 | Hybrid push. The binding stores a row inline only when it has no extras, its parent fully participates, and the tree and the stack have room. Every other row is one call to `lcgf_frame_open`/`leaf`. `Close` becomes inline. | 0 or less on plain rows; one call on rare rows. Measured. |
| D4 | Spec UIs: keep `tables_ui.zig` plus the seam row cache (WP0.5 in both plans); A8 (`TablesUi`) or S2 later, as decided under open question 12. | Removes the decode and `from` per row. |
| D5 | Static UIs keep their compiled passes (`ct.hpp`). What depends on the paint data moves into generated tables. The static-table format and its prebuilt frame stay seam-specific. | Equal or less |
| D6 | An idiomatic C++ surface (§5). | 0: inline or consteval |
| D7 | Optional cross-language ThinLTO (`LCGF_LTO=ON`) for clang whose LLVM matches Zig's. | Removes the remaining call overhead |

## 1. Inventory

**Classes:**
- **(a)** Thin wrapper over a C call.
- **(b)** Hand mirror of a Zig layout or constant.
- **(c)** Hand re-implementation of Zig logic.

### Line counts

| File | Lines | Class |
|---|---|---|
| `include/lcgf/lcgf.hpp` | 196 | mostly a; some b |
| `include/lcgf/runtime.hpp` | 521 | about 150 a, 110 b, 200 c |
| `include/lcgf/ct.hpp` | 780 | about 740 c, 40 b |
| `gpu.hpp` | 20 | selector |
| `gpu/types.hpp` | 175 | b, from desc.zig |
| `gpu/{vulkan, gles, wgpu, metal, d3d12}.hpp` | 934 + 784 + 533 + 725 + 866 | c: per-backend projections of `lcgf_render.gpu`, held to Zig by call logs (run.sh:39-141) |
| `scenes/scenes.hpp` | 173 | bench and gate |
| `cmake/lcgfConfig.cmake` | 189 | no `lcgfConfigVersion.cmake`, so a versioned `find_package` cannot resolve |
| `check/*` | 1,596 | tests |

**`src/abi`:** `lcgf.h` 322 lines; `lib.zig` 9; `runtime.zig` 457; `seam.zig` 750; `plan.zig` 954; `ct.zig` 1,549; `auto.zig` 221; `zon.zig` 629. **Tools:** `tools/lcgf-gen/main.zig`, 1,359 lines. **Rust** mirrors the same pieces: `runtime.rs` 1,066 lines, `ct.rs` 1,184, `lib.rs` 481, and keeps its own copy of the layout hash (`runtime.rs:248`).

### `lcgf.hpp`

| Item | Lines | Class |
|---|---|---|
| `Status` | 19-27 | b |
| `Str` | 31-41 | b |
| `Input` (bit constants and `tab = 0x2b`) | 45-54 | a+b |
| `Quad`, `TextRun`, `CustomDraw` aliases | 56-58 | a over the hand C mirrors at lcgf.h:52-73 |
| `CmdKind` | 60 | b |
| `Command`, `DrawList` | 64-86 | a |
| `Events` | 89-118 | a |
| `Ui` (spec UI) | 122-153 | a |
| `StaticUi` (SeamUi) | 158-187 | a |
| `Buffer` | 190-194 | a |

### `runtime.hpp`

| Item | Lines | Class | Re-implements or mirrors |
|---|---|---|---|
| `Id::From`, `With` | 40-57 | c | `Id.hash` / `with` |
| Colours, `inf` | 59-64 | b | |
| `Dir`, `Align`, `Role` | 66-68 | b | |
| `Size` | 71-79 | b | |
| `Style` (59 words; `cursor` and `participation` are bare `uint32`) | 83-118 | b | |
| `Row(const Style&)` | 123-199 | c | `Template.from` (tree.zig:130-195). Lines 166-190 are the extras section the styling merge edited. |
| `TextStyle`, `Theme`, `Spring`, `Ease`, `Color` | 202-228 | b, and a for `Theme` | |
| `Components` | 234-279 | c | `values.flatten` / `build` / `take` |
| `Response` | 282-290 | b | |
| `Frame::Open`, `Leaf` | 301-312 | c | |
| `Close`, `Text`, `TextStyled`, `Custom`, `Animate`, `Tween`, `TextF` | 304-347 | a | `Animate` makes n calls for an n-component value (352-358) |
| `Push` | 367-432 | c | `Tree.pushRow` (tree.zig:473-546) |
| `Enter` | 435-443 | c | `Frame.enter` |
| Widget free functions | 449-478 | a | |
| `Context` | 481-519 | a | |

### `ct.hpp`

| Item | Lines | Class | Re-implements |
|---|---|---|---|
| Float helpers | 40-57 | c | |
| `Sink` | 62-105 | c | `fmt.Sink` |
| `Region`, `Select` | 109-117 | b | |
| `select_window` | 120-127 | c | |
| `Tree` passes | 131-309 | c | |
| `Event`, `Shortcut` | 313-334 | b | |
| `Ui`: frame, relayout, patch | 351-416 | c | |
| `Ui`: events and focus | 425-486 | c | |
| gather, layout, finalize | 544-664 | c | |
| `shown` | 668-679 | c | Includes the "material 3 = shadow, grows 3σ" decoding |
| `emit`, `encode`, `paint` | 681-777 | c | Lines 751-753 hand-fill the `TextRun` defaults |

### Mirrors in Zig and in the checks

- `CLimits` (runtime.zig:29-40) carries 6 of the 11 `Limits` fields.
- `CInput` (seam.zig:410-434) carries 7 of the 16 `Input` fields.
- `ZStyle` (zon.zig:78-124) carries 13 of the `Style` fields.
- `rowSweep` (rt_dump.zig:130-161) indexes words by hand.
- Two hand edits have already drifted: the doc comment at rt_dump.zig:13 still says "50 … 55 words", and the diagnostic loop at rt_check.cpp:52 still runs `i < 55`. The row is 66 words.
- `lcgf_quad`, `text_run`, `custom_draw`, `draw` and `input` are in no layout hash.

**Reusable generic machinery already exists:**
- `plan.wordsOf`, `put`, `get` and `hashType` (plan.zig:542-640).
- `@Struct(.@"extern", …)` (`seam.ExternState`, seam.zig:549-554).
- `cView` filling the view by field-name reflection (runtime.zig:191-198).
- `static_assert(offsetof)` emission for state structs in lcgf-gen (main.zig:351-366).
- A harness that runs one UI through both the runtime front end and `ComptimeUi` and fails if their draw lists differ (`base.Harness`, widgets/base.zig:864-900).

## 2. Coverage gaps: the Zig surface against C++ today

| Zig surface | C++ today | Gap |
|---|---|---|
| **Style fields** (types.zig:394-454) | All words present | No `Cursor` enum (35 shapes); no `Participation` constants |
| Resolved cursor (`Output.platform.cursor`, context.zig:69-87) | No | The new cursor styling cannot be observed from C++ |
| Semantics read-out (role and value after participation) | No | |
| `textfStyled`, `outline` | No | |
| `interact`, `drag`, `lastRect`, `heldRect` | No | `Sense` is not exposed, so no custom interactive node is possible |
| `setFill`, `setCursor`, `focusScope` | No | |
| `timer` | No | `lcgf_input` has no `time` |
| `reuse` with signals | No | |
| `animateLayout`, `sequence`, `transition`, `setFillAnimated` | No | |
| `endRounded`, `arrangeWith`, `finalizeLayout`, `finish` | No | |
| `endText` and the other text-backed ends | No | Needs the font stack; deferred |
| `Limits` | 6 of 11 | |
| `Output.status`, `pace` | No | Overflow is invisible |
| `beginWithHit`, settings | No | |
| `Input` | 7 of 16 fields | |
| **Widgets** (45 files) | 4 | About 25 more have C-friendly signatures. `textfield`, `textarea`, `search` and `number` need runtime-capacity text. `menu`, `select`, `combobox`, `dialog`, `popover`, `toast`, `tooltip`, `datepicker`, `menubar`, `contextmenu`, `table` and `tree` take comptime parameters. |
| Theme | Hidden default | `Runtime.theme` is pinned (runtime.zig:106); no tokens |
| `style.resolve`, recipes, prepared `bake`/`bind`, effects, vectors | No | Open question |
| Spec `.zon` styles | 13 fields | |
| Static UIs | | Refuse transform, paint reference, outset and partial participation (ct.zig, about 604-613) |
| GPU descriptors | Partial | Missing dimensions, compare samplers, write mask, labels |
| Draw-list renderer | None | |

With D2, most of this table closes mechanically: every `pub fn` of an exported container is exported, or skipped with a stated reason.

## 3. `src/abi/`: the Zig API in C form

The design is `docs/plans/bindings-rust.md` §6 ("`src/abi/`: the Zig API in C form (shared with the C++ plan)"), adopted verbatim: the rule, the audit, what stays seam-specific, the target layout (about 4,380 hand lines against 4,891 today) and migration steps A1-A8. (`CInput` carries 7 of `Input`'s 16 fields.)

**Notes sent to both plans, none blocking:**
- **(a) Tripwire test.** A test fails when a `pub fn` is added to `Context` or `Frame` but is neither in `api.zig` nor in a skip list. It counts the names with `std.zig.Ast`, since declarations are not enumerated by reflection. (Now in §6.5 / A2 of the shared design.)
- **(b) S2 as an alternative to A8 (`TablesUi`).** `lcgf-gen` writes spec UIs as runtime-front-end code, and `tables_ui.zig` plus the dynamic tables format are deleted. This holds only if a `base.Harness` test shows the runtime front end draws the same as `ComptimeUi` for toolbar, mixer and panel. Open question 12.

### C++ consequences of the shared design

1. **Generated wrappers.** `runtime.hpp`'s calls become generated inline members over `lcgf_frame_*`, `lcgf_context_*` and `lcgf_<widget>`, all from `api.zig` through abi-gen.
2. **Explicit theme and font.** Widgets take `const lcgf_theme*` and `lcgf_frame_end` takes the Mono font, as in Zig. The C++ `lcgf::Context` keeps the theme and a default `Mono`, so `f.Button(id, {.label = "Save"})` still reads as before at no extra cost.
3. **Context storage.** `lcgf_context` lives in caller memory of `LCGF_CONTEXT_SIZE`/`_ALIGN`. The C++ `Context` holds that as an `alignas` byte member, plus a span of the caller's work buffer, so there is still no heap use.
4. **Frame and input.** `lcgf::Frame` wraps the two-pointer `lcgf_frame` by value, plus a pointer to the inline-push view from `view.zig`. Because `Context.begin` copies the Input, a temporary `lcgf::Input` is safe.
5. **Spec and static UIs.** C++ `lcgf::Ui` calls `lcgf_ui_frame_*`, and `StaticUi` (SeamUi) calls `lcgf_static_ui_frame_*`. The `LCGF_FRAME` and `LCGF_CT_FRAME` macros follow the rename.
6. **Animate and tween.** Instantiations at `f32` only: a `Color` still takes four calls, unless `api.zig` adds `Color` and `[N]f32` instantiations, which is recommended.

## 4. Making the C++ bindings thinner

**T1. Generated mirrors (D1, abi-gen).** These types come from Zig, for C, C++ and Rust:
- `Style`, `TextStyle`, `Size`, `Color`, `Theme`, tokens.
- `Limits`, `Input`, `Output`, `Platform`.
- `DrawList` (`Quad`, `TextRun`, `CustomDraw`).
- `FlatRow`, `Look`, `Extra`, `Tree.Columns`.
- Enums: `Cursor`, `Role`, `Ease`, `Pace`, `Sense`, `Response`, rounding options.

How the C++ side is written:
- Defaults come from `T{}` words.
- A rename table keeps today's spellings (`Axis`→`Dir`, `float`→`floating`). `?Cursor` maps to `Cursor::inherit = 0xffffffff`.
- Every field gets a `static_assert(offsetof)`.
- The hashes are generated.
- C++ also gets constexpr chain setters per `Style` field, and one inline member wrapper per exported fn.

**What it removes:** about 200 lines of `lcgf.h`, about 70 lines of `runtime.hpp`, and all 4 hand widget wrappers (runtime.hpp:449-478, which become generated). Zero per-frame cost.

**T2. Hybrid push (D3).** C++ keeps only the node-column half of `Template.from` (`Fast`): size coefficients, align factors, flow, shrink, clips, the untinted fill, texture/material masks, role and value; it is stable code.

A generated "slow mask" sets the slow bit when `clip` is set, or when any `Style` word outside a new `Template.node_inputs` list (tree.zig) differs from its default. A Zig property test keeps that list honest. The bit is conservative: a false positive only costs speed, because the slow path is Zig.

| Path | Taken when | What runs |
|---|---|---|
| Fast | Not slow, `len < cap`, `depth < depth_cap - 1`, parent `active_participation == 15` | Stores generated from `Template.node_fields` into `lcgf_tree_columns`, plus about 8 hand lines |
| Slow | Anything else | `lcgf_frame_open` / `leaf` with the style |

- **`Close`** becomes inline: `end[stack[d]] = len; --depth`, which is all of `Tree.seal` and `Frame.close`.
- **Removed:** runtime.hpp:166-190, 370-376 and 394-431, and their Rust twins.
- **The rows check** becomes "node words equal Zig's, and the slow bit is sound", and also reports the false-positive rate.

A new paint-extra or behaviour field then needs no hand edit.

**T3. Static tables (D5).** `lcgf-gen --static` writes `paint_grow[k]`, computed with `geometry.paintBounds`' arithmetic. `TextRun run{}` takes the generated defaults, replacing ct.hpp:751-753. ct.hpp:668-679 drops its material knowledge.

**T4. Animate and tween** use the instantiations in `api.zig` (`f32`, `Color`, `[2]f32`, `[4]f32`). The call for a colour is `lcgf_frame_animate_color`, one call. `Components` stays only for user types.

**T5. Spec UIs (D4).**
- **S2:** generated runtime-front-end code. Regions become `if`/`for`; formatted labels become `TextF`; springs become `Animate`; events become `Response`s.
- **S1 / now:** a row cache built at `lcgf_ui_init` (constant `Template`s; 4 button fills, 2 checkbox boxes, patched slider and thumb rows).

**Options rejected, and what would reopen them:**

| Option | What would reopen it |
|---|---|
| All rows through calls | The all-call variant of §6 passes the same thresholds |
| Per-UI C++ for static UIs | GCC (1.2-1.6× Zig on settings and todo) |
| SeamUi only | Your call (open question 3) |
| Generated GPU back ends | None; only `gpu/types.hpp` is generated, from desc.zig |

## 5. An idiomatic C++ API

### Principles

- Everything on the hot path is inline or `consteval`.
- No `std::function`, no virtual calls, no exceptions, no allocation in the library. A lambda is a template parameter.
- C++20 is the floor. `std::expected` is used when `__cpp_lib_expected` is defined.

### Pieces

| Piece | Form | Cost |
|---|---|---|
| Ids | `consteval operator""_id`; `Id::From(std::string_view)`; `.With(i)` | 0 for literals |
| Scopes | `[[nodiscard]] Scope f.Open(id, style)`, closing on scope exit; `f.Open(id, style, [&]{…})` | Inline `Close` |
| Members | Every exported `Frame` fn and widget is a generated member: `f.Button(…)`, `f.Interact(…)`, `f.Tabs(…)`. `[[nodiscard]]` where Zig forces `_ =` on non-binding results (`Button`, `Interact`, `Open`). | One direct call |
| Theme and font | Explicit, as in Zig, with a defaulted `Frame` member: `f.Button(id, {.label = "Save"})` uses `ctx.Theme()` | 0 |
| Styles | Designated initializers must follow declaration order in C++, which Zig does not require. Generated constexpr chain setters work in any order: `Style{}.Pad(12).Radius(8).Fill(0x2a2d36_rgb)`. `constexpr Row`. | 0 when constant |
| Strings | `std::string_view`, `std::span<const std::string_view>` | 0 |
| Draw list | Spans; a `commands()` view; `customs<T>()` | Plain loops |
| Setup | `Context::Create(buffer, limits) -> std::expected<Context, Status>`; `AlignedBytes(n)` | Setup only |
| Output | `const Output& out = ctx.End();` with `.draw`, `.status`, `.platform.cursor`, `.wake`, `.pace` | One load each |
| CMake | `find_package(lcgf 1 REQUIRED CONFIG)`, `lcgf::lcgf`, `lcgf_add_ui`, a generated ConfigVersion file, `LCGF_LTO` | |

### Side by side

**1. A typical app frame**

Zig:
```zig
var f = ctx.begin(&in);
_ = f.open(.from("toolbar"), .{ .dir = .x, .gap = 8, .fill = th.panel });
const ui = kit.on(&f, &th);
if (ui.button(.reset, .{ .label = "Reset" }).clicked) resets += 1;
_ = ui.checkbox(.wire, &wire, .{ .label = "Wireframe" });
_ = ui.slider(.exposure, &exposure, .{});
f.close();
const out = f.end(.{});
```

C++ today:
```cpp
lcgf::Frame f = ctx.Begin(input);
f.Open(lcgf::Id::From("toolbar"), {.dir = lcgf::Dir::x, .gap = 8, .fill = ctx.theme().panel});
if (lcgf::Button(f, lcgf::Id::From("reset"), "Reset").clicked()) ++resets;
lcgf::Checkbox(f, lcgf::Id::From("wire"), wire, "Wireframe");
lcgf::Slider(f, lcgf::Id::From("exposure"), exposure, 0, 1);
f.Close();                                     // forgotten: tree silently wrong
const lcgf::DrawList& draw = ctx.End();       // no status, no cursor
```

C++ after:
```cpp
using namespace lcgf::literals;
auto f = ctx.Begin(input);
{
    auto bar = f.Open("toolbar"_id, {.dir = Dir::x, .gap = 8, .fill = th.panel});
    if (f.Button("reset"_id, {.label = "Reset"}).clicked()) ++resets;
    f.Checkbox("wire"_id, wire, {.label = "Wireframe"});
    f.Slider("exposure"_id, exposure);
}
const lcgf::Output& out = ctx.End();
```

**2. A styled, interactive control**

Zig:
```zig
const n = f.leaf(.from("knob"), .{ .size = .{ .px(24), .px(24) }, .radius = 12, .cursor = .grab, .border = 1, .border_color = th.accent });
const r = f.interact(n, .{ .hover = true, .drag = true });
f.setFill(n, if (r.held) th.accent else th.control);
value += f.drag(.from("knob"))[0] * 0.01;
```

C++ today: not possible.

C++ after:
```cpp
constexpr auto kKnob = Style{}.Size(Px(24), Px(24)).Radius(12).Cursor(Cursor::grab).Border(1, kAccent);
const Node n = f.Leaf("knob"_id, kKnob);                 // border: slow path, one call
const Response r = f.Interact(n, Sense::hover | Sense::drag);
f.SetFill(n, r.held() ? th.accent : th.control);
value += f.Drag("knob"_id)[0] * 0.01f;
```

**3. An animation**

Zig:
```zig
const ink = f.animate(.from("ink"), if (hot) hot_c else cold_c, .{});
const w = f.tween(.from("bar"), if (open) 120 else 20, 0.5, .out_cubic);
_ = f.leaf(.from("bar"), .{ .size = .{ .px(w), .px(6) }, .fill = ink });
```

C++ today:
```cpp
const lcgf::Color ink = f.Animate(lcgf::Id::From("ink"), lcgf::Color::From(hot ? kHot : kCold));   // 4 calls
const float w = f.Tween(lcgf::Id::From("bar"), open ? 120.0f : 20.0f, 0.5f, lcgf::Ease::out_cubic);
f.Leaf(lcgf::Id::From("bar"), lcgf::Style{.size = {lcgf::Size::Px(w), lcgf::Size::Px(6)}, .fill = ink.rgba()});
```

C++ after:
```cpp
const Color ink = f.Animate("ink"_id, hot ? kHot : kCold);           // lcgf_frame_animate_color: 1 call
const float w = f.Tween("bar"_id, open ? 120.f : 20.f, .5f, Ease::out_cubic);
f.Leaf("bar"_id, kBar.Width(Px(w)).Fill(ink));                       // inline fast path
```

**4. A list, with reuse**

Zig:
```zig
for (items, 0..) |it, i| {
    const id = Id.from("row").with(@intCast(i));
    if (f.reuse(id, &.{it.sig})) continue;
    _ = f.open(id, row_style);
    _ = f.text(it.name, .{});
    f.close();
}
```

C++ today: there is no reuse, and `Close` is manual.

C++ after:
```cpp
for (std::uint32_t i = 0; i < items.size(); ++i) {
    const Id id = "row"_id.With(i);
    if (f.Reuse(id, {items[i].sig})) continue;
    auto row = f.Open(id, kRowRow);                   // constexpr Row: stores only
    f.Text(items[i].name);
}
```

**5. Custom draw**

Zig:
```zig
_ = f.custom(.from("plot"), .{ .size = .{ .fill, .px(200) } }, @intFromPtr(&plot));
```

C++ today:
```cpp
f.Custom(lcgf::Id::From("plot"), {.size = {lcgf::Size::Fill(), lcgf::Size::Px(200)}}, reinterpret_cast<std::uint64_t>(&plot));
for (const lcgf::CustomDraw& c : draw.customs()) DrawPlot(*reinterpret_cast<Plot*>(c.data), c);
```

C++ after:
```cpp
f.Custom("plot"_id, Style{}.Size(Fill(), Px(200)), &plot);
for (auto [plot, c] : out.draw.customs<Plot>()) DrawPlot(*plot, c.rect, c.clip, c.xform, c.opacity);
```

## 6. Performance: matching Zig's speed

### Where each choice stands

| Choice | Per-frame cost | How it stays at zero |
|---|---|---|
| Mechanical ABI (D2) | Same as today: one direct call; style conversion as today's `plan.get`; one `Input` conversion per `begin` | Wrappers are generated `inline` bodies around the Zig fn |
| Explicit theme and font | 0 (one pointer argument) | |
| `_id`, constexpr styles and rows, enums, `[[nodiscard]]`, spans and views | 0 | consteval/constexpr |
| `Scope`, lambda `Open` | Negative (a call is removed) | Inline `Close` |
| Hybrid push | 0 on plain rows; one call plus `from` on slow rows | Stores generated from Zig's own field list |
| Widgets as members | One call, as today | D7 removes it |
| Animate instantiations | n-1 fewer calls per value | |
| D7 ThinLTO | Removes call overhead | Bitcode of the fixed-lane `liblcgf_l{4,8,16}`; clang with the same LLVM major; not with `liblcgf_auto` or GCC |

### Where parity is reachable

1. **Runtime front end: reachable.** The layout and paint passes are the same Zig code, and rows are inline. What remains is about 1-3 ns per widget or text call that Zig would inline: at most a few percent of springs' roughly 57 µs. D7 removes it.
2. **Static UIs: reachable with clang and Rust**, which already match or beat Zig (bindings.md:313-323). GCC runs 1.2-1.6× Zig on the large UIs: per-UI codegen probe, or "use clang".
3. **Spec UIs:** under S2 they run as runtime-front-end code at runtime-front-end speed (whether that equals `ComptimeUi`'s speed is unknown until measured on toolbar, mixer and panel). With the row cache, the decode and `from` per row go; whatever remains is the interpreter. Exact parity by construction needs an opt-in Zig toolchain at build time: `lcgf_add_ui(... ZIG)` compiling `ComptimeUi` per `.zon` (open question 10).

### The benchmark that proves it

A parity section in `bindings/check/run.sh`:
- **Coverage**: every gated scene and UI, on identical frames, in Zig, C++ and Rust. `lcgf-rt-dump` and `lcgf-cpp-rt-check` gain `--bench` (the runtime front end is not benched in the gate today), plus the existing spec and static `--bench` lines.
- **Per row of output**: median of 9 runs (ns per frame) and `perf stat -e instructions:u` per frame.
- **Run conditions**: Zig runs twice, so its own spread is measured, under `taskset` on one core. Report the machine, compiler and flags.
- **Gate**: C++/Zig instructions ratio ≤ 1.02. Print the ns ratio; the VM's 5-25% spread makes timing unsuitable for gating.
- **The three push variants, shared with the Rust plan**, on `vs-lcgf-bindings` form, list, springs, resize and text: (1) full inline; (2) all-call; (3) hybrid. Hybrid is accepted at ≤ +1% instructions against full inline, with slow rows ≤ 5% (WP0 counter).

## 7. Completeness

With D2, every `pub fn` of `Context` and `Frame` is exported: interaction, paint state, focus scopes, timers, reuse and signals, all the motion calls, the split ends and rounding, outline, and the prepared row. So are the C-mappable widgets (about 29), theme tokens, `Input`, `Limits` and `Output` (with status, pace and platform), and the tree columns. The C++ members for all of them are generated.

**Skipped, each with its reason in `api.zig`:**
- The `comptime`-definition widgets (menu, select, combobox, dialog, popover, toast, tooltip, datepicker, menubar, contextmenu, table, tree).
- The `anytype` text-state widgets (textfield, textarea, search, number), until runtime-capacity variants exist.
- `endText` and the other text-backed ends.
- Kit (`on`).

**Spec UIs:** `ZStyle` is derived from `Style`. **GPU:** `gpu/types.hpp` is generated from desc.zig.

## 8. Work packages

Each package must pass `nix develop .#vs -c ci/run.sh bindings` (byte-identical draw lists), `nix develop -c zig build test fmt`, `nix develop -c ci/run.sh census-src`, and the §6 parity numbers against WP0. Rust moves in the same package. A-steps are the shared design's (`bindings-rust.md` §6.6).

| WP | What | Files | Verification |
|---|---|---|---|
| 0 | Baseline: parity section, runtime `--bench`, slow-row counter, three push variants | run.sh, rt_dump.zig, rt_check.cpp, bench/vs/lcgf-cpp, Rust twins | Numbers recorded with conditions |
| 0.5 | Seam row cache (shared) | seam.zig | Gate spec UIs; toolbar/mixer/panel parity |
| 1 | Generic `rowSweep`; fix the stale 50/55 | rt_dump.zig:13 and 130-161, rt_check.cpp:52 | Gate rows step |
| 3 = A1, A6 | Move-only commits | zon.zig, testdata, ct.make, plan core, words.zig; src/lcgf.zig | Gate identical, tables tests |
| 4 | abi-gen types (shared) | tools/abi-gen, build.zig, lcgf.h, runtime.hpp:59-118, 202-228 and 282-290, lcgf.hpp:19-27, sys.rs, hash tests | Gate unchanged |
| 5 = A2 | `api.zig` and the mapping engine, mechanical names beside the old | src/abi, lib.zig | Gate unchanged; tripwire test |
| 6 = A3, A4 | Switch C++ and Rust to the mechanical API; delete `runtime.zig` | runtime.hpp, runtime.rs, scenes.hpp, rt_check | Gate runtime scenes plus the overflow runs; parity |
| 7 = A5 | Generated `Input`, `Limits` and `Output` | src/abi, seam.zig, dump formats | Gate |
| 8 | Hybrid push and inline `Close` | tree.zig `node_inputs`, abi-gen, runtime.hpp, runtime.rs, rows check | Gate; three-way measurement |
| 9 | S2 or `TablesUi` decision (open question 12) | base.Harness test, lcgf-gen, lcgf.hpp `Ui`, Rust lib.rs | Gate spec UIs against `ComptimeUi`; toolbar/mixer/panel parity |
| 10 = A6 | `static.zig`, `paint_grow`, `TextRun{}` | ct.zig → static.zig, StaticGen, ct.hpp, ct.rs | Gate static and partial; `--bench` |
| 12 | Idiomatic C++ surface | runtime.hpp, lcgf.hpp, abi-gen members and setters, CMake ConfigVersion, the kit scene in the new style | Gate; parity unchanged; compile-time tests |
| 13 = A7 | Widget exports (`api.zig` entries) | api.zig, events.py | Gate: every widget had an event |
| 14 | `ZStyle` from `Style`; tokens | zon.zig, theme exports | Tables test; gate |
| 15 | D7 ThinLTO, opt-in | build.zig, lcgfConfig.cmake | Parity with and without LTO |
| 16 | Generated `gpu/types.hpp` | abi-gen, desc.zig | GPU log comparisons |
| 17 | Docs | bindings.md, CHECKS.md:143-169, DESIGN.md:113-132 | `zig build docs` |

(WP2, the reflection probe, was dropped: `api.zig` names each method explicitly. WP11, `auto.zig` reading `api.zig`, is part of A4.)

**Expected sizes:**
- `src/abi`: about 4,380 hand lines per the shared §6.4, or less after A8 or S2.
- `runtime.hpp`: about 370 hand lines, plus about 150 lines of idiomatic layer. A new paint field or a new Frame fn needs no hand edit in C++ or Rust.

## 9. Open questions

1. **Generated files.** Commit them with a staleness test (agreed with the Rust planner)?
2. **Parity gating.** Gate on the instructions ratio ≤ 1.02? Accept the hybrid thresholds (≤ +1% instructions, slow rows ≤ 5%)?
3. **Static UIs.** Keep compiled `ct.hpp`/`ct.rs`, or settle for SeamUi only?
4. **C++ standard.** C++20 floor with optional `std::expected`, or require C++23?
5. **ABI and source breaks in one release.** Mechanical renames (`lcgf_rt_*` → `lcgf_frame_*` and `lcgf_context_*`); `lcgf_frame` now meaning `Frame`; theme and font as explicit arguments; `cursor` and `role` as enums; `Row` reshaped. Acceptable?
6. **Widget scope.** Are the text widgets and the comptime-definition widgets needed in C++? Each needs a runtime Zig variant first, which then exports mechanically.
7. **Styling libraries.** Should `style.resolve`, recipes, prepared `bake`/`bind`, effects and vectors become exported containers in `api.zig`? Mechanical once their signatures are C-mappable, but a large surface.
8. **Draw-list renderer for C++.** Export the software renderer, ship the quad WGSL through `lcgf-gen`, or neither?
9. **GCC.** Is GCC a target for static UIs?
10. **Spec-UI parity.** Is an opt-in Zig toolchain at build time acceptable, if S2 or the row cache leaves a gap to `ComptimeUi`?
11. **ThinLTO.** Is an optional path that only works when clang's LLVM matches Zig's worth maintaining?
12. **S2.** If the probe passes, may S2 delete the spec-UI interpreter and the dynamic table format, so the C ABI holds no second front end?

---

## 10. Decisions (2026-11-26, user: "best long-term approach, recommended approach")

| Q | Decision |
|---|---|
| 1 Generated files | Committed with a staleness test. |
| 2 Parity gating | Gate on instructions ratio ≤ 1.02; print ns. Hybrid push accepted at ≤ +1% instructions against full inline and ≤ 5% slow rows. |
| 3 Static UIs | Keep compiled `ct.hpp`/`ct.rs`. |
| 4 C++ standard | C++20 floor; `std::expected` when `__cpp_lib_expected` is defined. |
| 5 Breaks | Yes, all in one release (mechanical renames, explicit theme and font, enums, reshaped `Row`). |
| 6 Widget scope | All widgets: text widgets through exported capacities; comptime-definition widgets through run-time variants. |
| 7 Styling libraries | Yes, exported through `api.zig` after the core batches. |
| 8 Renderer | Export the software renderer and ship the quad WGSL through lcgf-gen. |
| 9 GCC | Supported; clang is the parity reference. A per-UI codegen probe for GCC on settings and todo comes later. |
| 10 Spec-UI parity | Row cache, then S2. An opt-in Zig toolchain path only if a measured gap remains. |
| 11 ThinLTO | Yes, opt-in. |
| 12 S2 | Yes, if the probe passes. |
