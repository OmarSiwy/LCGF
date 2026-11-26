# Rust bindings: thinner, comprehensive, idiomatic, at Zig's speed, over a C ABI that is the Zig API in C form

Planning document from a read-only study of `main` @ 141d297d (planner: plan-rust, 2026-11-26). No code was edited and no benchmarks were run; speed claims are hypotheses with the measurement that settles each. Errata E1–E3 (agreed with the C++ planner) are applied. The `src/abi/` design (§6) is shared with `docs/plans/bindings-cpp.md`, which references it.

Requirements covered:
- thinner: generated, not hand-copied
- comprehensive: the full Zig surface, including the new styles
- byte-identical draw lists in the gate
- a Rust-native API (§4)
- speed equal to Zig's (§5)
- `src/abi/` reflecting the normal Zig interface mechanically (§6, shared with the C++ plan)

Three facts found while reading, which change how to read today's numbers and coverage:

- **The gate's Rust timings run a narrower build than the Zig ones.**
  - `bindings/check/run.sh` builds Rust with no `RUSTFLAGS`, and the workspace `Cargo.toml` has no `[profile.release]`.
  - `lcgf/build.rs:17-24` therefore links `liblcgf_l4.a` (the default x86-64 target has no `avx`), with 16 codegen units, no LTO and unwinding panics. The Zig dumps are native; only `ci/jobs/vs-lcgf-bindings.sh:15` sets `-C target-cpu=native`.
  - So "toolbar rust ~1146 vs comptime ~976" compares a 4-lane prebuilt *seam* frame against Zig's unrolled comptime frame.
- **The seam frame itself does extra work every frame.** `seam.zig:350–356` decodes each row's style (`tb.style()` → `plan.get(Style)`) and converts it (`plan.emit` → `Template.from`) per row, per frame. A row-template cache built at init (WP0.5) helps Rust and C++ equally.
- **The gate does not cover the runtime push's styling paths.** No runtime gate scene sets participation, cursor, paint_reference or paint_outset, so Rust's inline copy of `Tree.pushRow` is never run on them. The `rows` sweep covers only `Row::from`. WP0 closes this.

---

## 1. Inventory

Kinds:
- **(a)** thin wrapper over an `extern "C"` call
- **(b)** hand mirror of a Zig layout
- **(c)** hand re-implementation of Zig logic
- **(g)** generated
- **(r)** Rust-only API

### Line counts

| Path | Lines |
|---|---|
| `lcgf/src/lib.rs` | 481 (17 `unsafe`) |
| `lcgf/src/runtime.rs` | 1,066 (29 `unsafe`) |
| `lcgf/src/ct.rs` | 1,184 (2 `unsafe`) |
| `lcgf/src/gpu/` | mod 498, vulkan 1,680, gles 1,289, wgpu 1,588, metal 1,330, d3d12 1,700, d3d12_sys 7,256 (g) |
| `lcgf-macros/src/lib.rs` | 630 |
| `lcgf-check/src/*` | 2,953 |
| `d3d12-bindgen` | 62 |

### lib.rs

| Item | Line | Kind | Notes |
|---|---|---|---|
| `COLUMN_ALIGN`, `NO_WIDGET` | 38–39 | b | |
| `Status` | 44 | b | |
| `Str` | 57–79 | b | `ExternState` string (seam.zig:549) |
| `Input` + consts + `keys` / `key_events` / `Default` | 84–153 | b | `CInput` (seam.zig:410), 7 of `Input`'s 16 fields; defaults hand-copied |
| `KeyEvent` | 102 | b | `Input.Event`; `kind` is a raw u8 |
| `Quad`, `TextRun`, `CustomDraw` | 158, 175, 191 | b | draw_list.zig:14/37/55 |
| `RawDraw`, `RawFrame` | 204, 222 | b | `CDraw`, `CFrame` |
| `CmdKind`, `Command` | 232, 241 | b/r | |
| `DrawList<'a>` | 250–298 | r | |
| `WidgetEnum`, `Events<W>`, `Frame<'a,W>` | 301–342 | r | |
| `Buffer`, `Tables`, `StaticTables` | 346–369 | r | |
| externs | 371–379, 420–428 | a | `lcgf_ct_layout` is declared but never called |
| `StaticUi` | 384–418 | a | |
| `Ui` | 432–479 | a | |
| size assert | 481 | b | |

### runtime.rs

| Item | Line | Kind | Notes |
|---|---|---|---|
| `Id::from` / `with` | 21–43 | c | |
| `rgb` | 45 | c | |
| `Dir`, `Align`, `Size` | 51–84 | b | |
| `Style` + `DEFAULT` | 90–168 | b | 59 words; `floating` where Zig has `float`; `participation`, `cursor`, `role`, `texture`, `material` and the colours are untyped `u32` |
| `TextStyle` | 172 | b | |
| `Theme` | 191 | b | |
| `Response` | 206 | b | `pressed` and `released` are missing |
| `Limits` | 226 | b | 6 of 11 fields |
| `RT_LAYOUT` | 249 | b | |
| `Row` | 256–297 | b | |
| `Row::from` | 309–396 | **c** | `Template.from`, tree.zig:130–196 |
| `Look`, `Extra` | 407–434 | b | |
| `View` | 439–477 | b | |
| `DEPTH_BIT` | 480 | b | |
| `View::push` | 486–584 | **c** | `Tree.pushRow`, tree.zig:473–546 |
| `View::enter` | 588 | **c** | |
| externs | 602–632 | a | |
| `Context` | 635–705 | a | |
| `Frame` (open, open_row, close, leaf, leaf_row, text, text_styled, custom, custom_row, animate, animate_with, tween, text_fmt, label_fmt) | 708–815 | a, plus c for the pushes | |
| `label!`, `text!` | 819, 825 | r | |
| `Spring`, `Ease`, `Color` | 831–879 | b | |
| `Animatable`, `round_f32`, `each` | 884–996 | c | `anim/values.zig` |
| `label`, `button`, `checkbox`, `slider` free functions | 998–1009 | a | |
| option structs, `Kit` | 1011–1066 | r | |

### ct.rs

- `simd` select and round helpers (16–50): c
- `Region`, `Block`, `trait Tables` (55–155): b
- `Sink`, `decimal`, `round_half_away` (159–243): c (fmt.zig)
- `select_window` (253): c
- `Scratch` passes `live_mask`, `fit`, `resolve`, `place`, `passes`, `relayout_span` (268–525): c (layout.zig, ct_dynamic)
- `Ui` and `QUAD0` / `RUN0` (530–616): b
- `frame`, `relayout`, `patch*`, `gather`, `select`, `layout`, `finalize` (673–881): c
- `at`, `pointer`, `next_focus`, `focus_keys`, `shortcut` (885–991): c (ct_events)
- `vis_of` / `rect_of`, which duplicate one clamp block (994–1051): c
- `shown`, `emit_quads`, `encode`, `paint` (1065–1183): c (ct.zig, paint.encode)
- The per-UI tables are (g), from lcgf-gen main.zig:761–905.

### lcgf-macros

- `ui!` (38), `include_ui!` (50), `include_shader!` (102): r
- DSL parser (310–598): b, a copy of zon.zig's grammar
- `style_value` whitelist (600–629): **b**, a second subset of `Style`, narrower than ZStyle (no min or max)

### gpu

A per-language projection by design (DESIGN.md:131), with no liblcgf calls. The `mod.rs` enums are (b) copies of `src/render/gpu/desc.zig`. The back ends exclude each other through `compile_error!` (mod.rs:31–42), so the features are not additive.

### Soundness: undefined behaviour reachable from safe code

| # | Where | Issue | Fix |
|---|---|---|---|
| S1 | ct.rs:566, 683, 1172–1182 | Pointers into its own arrays; `draw()` after a move hands out dangling slices | Keep lengths only; build `RawDraw` in `draw()` |
| S2 | lib.rs:95, 123–137 | `Input::keys` keeps a raw pointer with no lifetime | `Input<'k>` |
| S3 | lib.rs:391, 440 | Safe constructors generic over any state type `S`; a wrong one lets the library write out of bounds | Make them `unsafe` / `doc(hidden)`; check the state's size and alignment against the header |
| S4 | runtime.rs:256, 527 | `pub` `Row` fields let safe code push bad `text`, `custom` or `paint_reference` indices; `geometry.zig:87` only debug-asserts them | Private `Row`; a `paint_reference < i` select in pushRow's extras branch |
| S5 | lib.rs:291, 395, 444; runtime.rs:655 | `transmute` to `CmdKind` / `Status` | `match` |
| S6 | runtime.rs:692 | `ctx.end()` without `begin` reads `Runtime.frame = undefined` | `Frame::end(self)` typestate |
| S7 | lib.rs:104 | Arbitrary `KeyEvent.kind` against an exhaustive Zig enum | `KeyKind` enum |
| S8 | ct.rs | No check that the installed lcgf-gen matches the crate's template format | Generated format/hash assert |
| S9 | lib.rs:481 | Draw structs are only size-asserted | Generated layout hash over every exported type (§6) |

---

## 2. Coverage gap: Zig against Rust

Under §6, every "needed" C function below is a generated wrapper named after its Zig declaration (`lcgf_frame_interact` ↔ `Frame.interact`). Adding one means adding a name to `src/abi/api.zig`.

| Zig | Rust today | Needed |
|---|---|---|
| open, leaf, close, openRow / leafRow / customRow, text, textStyled, textWritten, custom, animate, tween, end | yes | `textfStyled` missing |
| `Frame.interact(node, Sense)` | **no**; no custom widget is possible | `lcgf_frame_interact` |
| `drag`, `lastRect`, `heldRect`, `setFill`, `setCursor`, `focusScope`, `outline` | no | `lcgf_frame_<method>` each |
| `Frame.timer` | no; the C input has no `time` | mechanical `lcgf_input` (§6) + `lcgf_frame_timer` |
| `Frame.reuse` + Signals | no | `lcgf_frame_reuse`, `lcgf_signals_create` / `_bump` |
| `animateLayout`, `sequence`, `transition`, `setFillAnimated` | no | `lcgf_frame_<method>` |
| `layoutWith` / `finish`, `endRounded`, `layoutRounded`, `arrangeWith`, `finalizeLayout` | no | `lcgf_frame_<method>`; needed for prepared paint and custom passes |
| `endText` / `TextStack` | no | open question |
| `Output.status`, `.platform` (cursor, IME, clipboard, paste), `.pace`, `.tree` | only draw and wake | mechanical `lcgf_output` |
| Context settings, `track_pointer`, `waker`, `beginWithHit` | no | `lcgf_context_<method>` / fields |
| Input: time, wheel, scroll, keys, **text** (`.text` events carry no bytes), contacts, safe_area, appearance, redraw | 7 of 16 fields | mechanical `lcgf_input` |
| Limits: tweens, flips, signals, timers, memos | missing | mechanical `lcgf_limits` |
| Theme | read-only default | passed as `*const lcgf_theme`, as widgets take it in Zig |
| Widgets | 4 of ~45 files in src/widgets/ | `lcgf_<module>` per widget function, listed in api.zig; generated `Kit` |
| Typed Style (Participation, `Option<Cursor>`, Role, Color, texture / material) | raw u32 | generated types |
| `prepared_texture` / `paint_revision` | always 0 | `prepared.bind` exported after layout |
| style.resolve, tokens, recipes, prepared paint, effects, vectors | none | open question |
| `.zon` / `ui!` styles | 15 / 12 keys | every Style field |
| Tables UI: `set_focus`, status | no | `lcgf_ui_<method>` |
| UI renderer over `lcgf::gpu` | none | open question |

---

## 3. Thinning

- **T1. bindgen from lcgf.h: reject.** lcgf.h is itself a hand mirror today, and becomes generated under §6. bindgen adds libclang to user builds and still leaves no defaults, enums or `const fn`.
- **T2. The shared emitter `tools/abi-gen` (core of the plan; same tool for C and C++).**
  - It reads the export list in `src/abi/api.zig` (§6) and the types it names.
  - Its walk is the one `words.zig` does (moved from plan.zig:542–640).
  - It emits:
    - (i) `sys.rs`: the C structs (extern or word structs), enums, `DEFAULT`s from `plan.put(T, .{})`, `offset_of!` asserts, the layout hash over every exported type, and one `extern` per api.zig entry;
    - (ii) **the user-facing `Style` and `TextStyle` as idiomatic Rust types**: `bool`, `Option<Cursor>`, `Participation`, `Color`, `Role`, the same field names as Zig (`float` included), plus a `const fn` setter per field;
    - (iii) `lcgf.h` and `lcgf/types.hpp` for C and C++, with doc comments taken from the Zig `///` via `std.zig.Ast`;
    - (iv) for the hybrid push, the `Template.node_fields` store list and a per-Style-word slow mask (from a new `Template.node_inputs` declaration in tree.zig).
  - One rename table: Zig `Axis` → `Dir`; field `float` stays `float` in Rust and becomes `floating` in C and C++; `?Cursor` is `0xffffffff` in word structs.
  - Delivery: **committed generated files plus a `zig build test` staleness check**, as the C++ plan adopts, so both bindings work the same way. The layout hash checked at init guards against a prefix built from another commit.
  - It removes about 420 hand-written Rust lines and every edit like the styling merge's.
  - Per-frame cost: zero (identical layouts and consts).
- **T3. Logic behind C calls, case by case:**
  - **`Row::from`: keep** as a `const fn`. It is the only way to get `const` rows, and the 4,096-style sweep gates it. Its extras-field copies become generated.
  - **`View::push`:** chosen by a three-way measurement (§5 M2):
    - (a) today's full inline push;
    - (b) all-call (`lcgf_frame_open_row` / `leaf_row`);
    - (c) hybrid: inline stores only when `own == 0`, the parent's active participation is 15, `len < cap` and `depth < depth_cap - 1`; otherwise one call to `lcgf_frame_open` / `lcgf_frame_leaf` with the Style, where Zig does `Template.from` and `pushRow`.

    Pick (c) unless (b) is within noise. Under (c) the fast path needs only the node-column half of `Template.from` and the generated stores; new paint-extra fields need no Rust edit, and the overflow paths are Zig's. `Close` is inlined through the view too (`end[stack[d]] = len; depth--`, never popping the root), only if (c) wins.
  - **`ct.rs`: keep.** It is measured at or below Zig's time. Thin `QUAD0` / `RUN0` from the generated defaults and merge the duplicated clamp.
  - `Id`, `Animatable` and `Sink`: keep (tiny, gated).
- **T4. Per-UI ct code from lcgf-gen: reject.** It would be a third copy of the passes; generic code over consts already folds.
- **T5. Spec subsets.**
  - `ZStyle` is derived from `Style` with `@Struct` (Color → `?ZColor`).
  - The `ui!` macro passes unknown style keys through and zon.zig reports errors. Removes about 45 macro lines.
- **T6. GPU:** leave it hand-written. Optionally generate the `mod.rs` enums from desc.zig.

---

## 4. Idiomatic API

### Principles and their per-frame cost

| Choice | Design | Per-frame cost and how it stays zero |
|---|---|---|
| Nesting | `f.row(id, &style, \|f\| { … }) -> Node` and `f.col(…)`, closure `FnOnce(&mut Frame)`; guard form `let g = f.open(id, &s)` (derefs to `Frame`, `Drop` calls close) for early returns | Generic closure, `#[inline(always)]`, monomorphized, so no indirect call; the guard's `Drop` is the same close. `mem::forget` only leaves the node open; Zig's close never pops the root and end seals, so it is not UB. Check: `cargo asm` of the `app` scene shows no `call` through a closure pointer. |
| Ids | `id!("save")` = `const { Id::from("save") }`; `ID.with(i)` in loops | Hashed at compile time, as Zig's `.from("…")` is. |
| Styles | Generated idiomatic `Style`: `const CARD: Style = Style { radius: 8.0, cursor: Some(Cursor::Pointer), ..Style::DEFAULT };` or `Style::DEFAULT.radius(8.0).cursor(Cursor::Pointer)` | `const fn` setters plus `#[inline(always)] const fn Row::from`. A constant style folds to its row (proved today by rt_check's `PANEL` const asserts). A run-time style costs `Template.from` at run time, as Zig's `open` does. |
| Types | `Cursor`, `Role`, `Dir`, `Align`, `KeyKind`, `Ease`, `Cmd` enums (exhaustive `match`); `Participation`, `Sense` bit newtypes with consts; `Color(u32)` `repr(transparent)` | Same words, so zero. |
| Responses | `#[must_use] struct Response(u8)` with `hovered()`, `held()`, `pressed()`, `released()`, `clicked()`, `focused()` | Zero. |
| Frame lifetime | `ctx.begin(&input) -> Frame<'c>`; `f.end(self) -> Output<'c>`; `DrawList<'c>`, `Platform<'c>` borrow the context until the next `begin` | Lifetimes are free; also fixes S6. Mirrors Zig's `Context.begin` / `Frame.end` one to one (§6). |
| Errors | `Context::new(&mut buf, &Limits) -> Result<Context, Error>` with `Error: Display + core::error::Error`, generated from Zig's error set; frames do not fail (overflow is in `Output::status`, as in Zig) | Init only. |
| Draw list | `for cmd in out.draw.commands()` yields `Cmd::Quads { quads, key } \| Cmd::Text { run, bytes } \| Cmd::Custom(&CustomDraw)` | Host side. One up-front `debug_assert` of the column lengths; `get_unchecked` under the library's documented invariant. Check: no `panic_bounds_check` in `cargo asm`. |
| Animation | `f.animate(id, target, Spring::DEFAULT) -> T`, `f.tween(id, target, secs, Ease)` for `T: Animatable`; `#[derive(Animatable)]` (lcgf-macros), keyed in field order as Zig's `values.flatten` keys | The f32 path const-folds; composites are one call per number, as in Zig. |
| Memo | `f.reuse(id, &[sig], \|f\| build(f))`: the closure runs only when not reused | Zero (closure inlined). |
| `no_std` | The core stays `#![no_std]`; feature `alloc` adds `Context::boxed(limits)`; `context_bytes!(nodes = 4096, …)` gives a const size for a `static` buffer (`LCGF_CONTEXT_SIZE` and `required_bytes` from §6) | — |
| Cargo features | GPU back ends become additive modules `lcgf::gpu::{vulkan, gles, wgpu, metal, d3d12}`, each behind its own feature (no `compile_error!` exclusion) | Zero. |
| Docs | Every public item gets a doctest that compiles. Pure-data ones run (`cargo test --doc` with `LCGF_PREFIX`, in the gate); window-dependent ones are `no_run`. The five snippets below become `bindings/rust/lcgf/examples/*.rs` **and** gate scenes, byte-compared to Zig twins and benchmarked for parity. | — |

### Snippets: Zig, Rust today, proposed Rust

**1. A typical app frame**

Zig:
```zig
var ctx = try Context.init(&buf, .{});
if (ctx.needsFrame(&in)) {
    var f = ctx.begin(&in);
    _ = f.open(.from("toolbar"), .{ .dir = .x, .gap = 8, .pad = @splat(8), .fill = th.panel });
    const ui = kit.on(&f, &th);
    if (ui.button(.reset, .{ .label = "Reset" }).clicked) resets += 1;
    _ = ui.slider(.exposure, &exposure, .{});
    _ = ui.text("Resets: {d}", .{resets});
    f.close();
    const out = f.end(.{});
    render(out.draw);
}
```
Rust today:
```rust
let mut ctx = runtime::Context::new(&mut buf, &Limits::default())?;
if ctx.needs_frame(&input) {
    let th = *ctx.theme();
    let mut f = ctx.begin(&input);
    f.open(Id::from("toolbar"), &Style { dir: Dir::X, gap: 8.0, pad: [8.0; 4], fill: th.panel, ..Style::DEFAULT });
    if runtime::button(&mut f, Id::from("reset"), "Reset").clicked() { resets += 1; }
    runtime::slider(&mut f, Id::from("exposure"), &mut exposure, 0.0, 1.0);
    lcgf::label!(f, "Resets: {}", resets);
    f.close();
    let (draw, _wake) = ctx.end();          // callable even without begin (S6)
    render(&draw);
}
```
Proposed:
```rust
use lcgf::prelude::*;
let mut ctx = Context::new(&mut buf, &Limits::DEFAULT)?;
if ctx.needs_frame(&input) {
    let mut f = ctx.begin(&input);
    let th = f.theme();
    f.row(id!("toolbar"), &Style::DEFAULT.gap(8.0).pad(8.0).fill(th.panel), |f| {
        if f.button(id!("reset"), "Reset").clicked() { resets += 1; }
        f.slider(id!("exposure"), &mut exposure, 0.0..=1.0);
        text!(f, "Resets: {resets}");
    });
    let out = f.end();
    render(&out.draw);
}
```
Same node sequence and same draw list as the Zig version. `th.panel` is a run-time value in both languages, so both convert the style to a row at run time.

**2. A styled control (cursor, hover transition, focus outline, collapsing child)**

Zig:
```zig
const card_style: Style = .{ .pad = @splat(12), .gap = 4, .radius = 8, .border = 1,
    .border_color = .rgb(70, 76, 90), .cursor = .pointer, .role = .button };
const card = f.open(.from("card"), card_style);
_ = f.text("Open project", w.labelText(&th));
_ = f.leaf(.from("detail"), .{ .size = .{ .fill, .px(40) },
    .participation = if (app.expanded) .all else .collapsed });
f.close();
const r = f.interact(card, .button);
f.setFillAnimated(card, .from("card"), if (r.hovered) .rgb(52, 58, 70) else .rgb(40, 44, 52), .{});
if (r.focused) _ = f.outline(card, .{ .width = 2, .color = th.accent, .offset = 2 });
if (r.clicked) app.expanded = !app.expanded;
```
Rust today: cannot be written. There is no `interact`, `set_fill_animated` or `outline`. Participation and cursor are raw words (`participation: if expanded { 15 } else { 0 }`, `cursor: 1`), and nothing gates these rows (WP0).

Proposed:
```rust
const CARD: Style = Style::DEFAULT.pad(12.0).gap(4.0).radius(8.0)
    .border(1.0, Color::rgb(70, 76, 90)).cursor(Cursor::Pointer).role(Role::Button);
let card = f.col(id!("card"), &CARD, |f| {
    f.text("Open project", &th.label);
    f.leaf(id!("detail"), &Style::DEFAULT.size(FILL, px(40.0))
        .participation(if app.expanded { Participation::ALL } else { Participation::COLLAPSED }));
});
let r = f.interact(card, Sense::BUTTON);
f.set_fill_animated(card, id!("card"),
    if r.hovered() { Color::rgb(52, 58, 70) } else { Color::rgb(40, 44, 52) }, Transition::DEFAULT);
if r.focused() { f.outline(card, Outline { width: 2.0, color: th.accent, offset: 2.0, radii: None }); }
if r.clicked() { app.expanded = !app.expanded; }
```

**3. Animation**

Zig:
```zig
const w_px = f.animate(.from("drawer"), if (app.open) @as(f32, 240) else 0, .{});
const tint = f.tween(.from("tint"), if (app.alert) Color.rgb(200, 40, 40) else Color.rgb(40, 40, 48), 0.3, .out_cubic);
_ = f.leaf(.from("drawer"), .{ .size = .{ .px(w_px), .fill }, .fill = tint });
const p = f.animate(.from("pose"), app.pose, .{}); // a struct of f32s
```
Rust today:
```rust
let w = f.animate(Id::from("drawer"), if open { 240.0f32 } else { 0.0 });
let tint = f.tween(Id::from("tint"), Color::from(if alert { rgb(200, 40, 40) } else { rgb(40, 40, 48) }), 0.3, Ease::OutCubic);
f.leaf(Id::from("drawer"), &Style { size: [Size::px(w), Size::FILL], fill: tint.rgba(), ..Style::DEFAULT });
// a struct: implement Animatable by hand (N, put, take)
```
Proposed:
```rust
let w: f32 = f.animate(id!("drawer"), if open { 240.0 } else { 0.0 }, Spring::DEFAULT);
let tint = f.tween(id!("tint"), if alert { Color::rgb(200, 40, 40) } else { Color::rgb(40, 40, 48) }, 0.3, Ease::OutCubic);
f.leaf(id!("drawer"), &Style::DEFAULT.size(px(w), FILL).fill(tint));
#[derive(Clone, Copy, Animatable)] struct Pose { x: f32, y: f32, alpha: f32 }
let p: Pose = f.animate(id!("pose"), app.pose, Spring::DEFAULT);
```

**4. A list (memoised)**

Zig:
```zig
if (!f.reuse(.from("files"), &.{app.files_sig})) {
    _ = f.open(.from("files"), .{ .gap = 2, .size = .{ .fill, .fit } });
    for (app.files, 0..) |file, i| {
        _ = f.open(Id.from("file").with(@intCast(i)), row_style);
        _ = w.label(f, &th, file.name);
        _ = f.textf("{d} KB", .{file.kb}, small);
        f.close();
    }
    f.close();
}
```
Rust today (no reuse):
```rust
f.open(Id::from("files"), &Style { gap: 2.0, size: [Size::FILL, Size::FIT], ..Style::DEFAULT });
for (i, file) in files.iter().enumerate() {
    f.open(Id::from("file").with(i as u32), &ROW_STYLE);
    runtime::label(&mut f, file.name);
    lcgf::text!(f, &SMALL, "{} KB", file.kb);
    f.close();
}
f.close();
```
Proposed:
```rust
const LIST: Style = Style::DEFAULT.gap(2.0).size(FILL, FIT);
f.reuse(id!("files"), &[app.files_sig], |f| {
    f.col(id!("files"), &LIST, |f| {
        for (i, file) in app.files.iter().enumerate() {
            f.row(id!("file").with(i as u32), &ROW, |f| {
                f.label(file.name);
                text!(f, &SMALL, "{} KB", file.kb);
            });
        }
    });
});
// 100k rows: f.vlist(id!("rows"), &names, 20, &mut selected, &mut scroll)  (WP10)
```

**5. Custom draw**

Zig:
```zig
_ = f.custom(.from("plot"), .{ .size = .{ .fill, .px(120) } }, plot_tag);
const out = f.end(.{});
for (0..out.draw.cmd_len) |k| switch (out.draw.cmd.kind[k]) {
    .quads => r.quads(out.draw, k), .text => r.text(out.draw, k),
    .custom => drawPlot(out.draw.customs[out.draw.cmd.first[k]]),
};
```
Rust today:
```rust
f.custom(Id::from("plot"), &Style { size: [Size::FILL, Size::px(120.0)], ..Style::DEFAULT }, PLOT);
let (d, _) = ctx.end();
for i in 0..d.command_count() {
    let c = d.command(i);
    match c.kind {
        CmdKind::Quads => r.quads(&d.quads()[c.first as usize..][..c.count as usize], c.key),
        CmdKind::Text => { let run = &d.runs()[c.first as usize]; r.text(run, d.text(run)) }
        CmdKind::Custom => plot(&d.customs()[c.first as usize]),
    }
}
```
Proposed:
```rust
f.custom(id!("plot"), &Style::DEFAULT.size(FILL, px(120.0)), PLOT);
let out = f.end();
for cmd in out.draw.commands() {
    match cmd {
        Cmd::Quads { quads, key } => r.quads(quads, key),
        Cmd::Text { run, bytes } => r.text(run, bytes),
        Cmd::Custom(c) => plot(c.rect, c.clip, c.xform, c.data),
    }
}
```

The generated tables UIs (`ui!` / `include_ui!`) gain the same exhaustive event enum the static ones already have: `for ev in frame.events() { match ev { Event::Mute => …, Event::Volume(v) => … } }`.

Under §6, every Rust method above is named after the Zig declaration it calls (`Frame::interact` → `lcgf_frame_interact` → `Frame.interact`), so the Rust API, the C ABI and the Zig API read as one interface.

---

## 5. Same speed as Zig

### Where the time goes, per front end

| Front end | Rust's own code per frame | What can differ from Zig | Is parity reachable? |
|---|---|---|---|
| **Static** (`ct::Ui`, generic over const tables) | all of it | Codegen only | **Already reached**: 43–1,029 ns against Zig's 60–1,481 ns (bindings.md:313). Keep it, and keep it measured. |
| **Runtime** (`lcgf::runtime`) | inline row pushes; layout and paint are liblcgf's Zig code | One direct C call per close, text, widget, animate and end, which Zig inlines; target CPU and lanes; Rust profile | **Yes**, with cross-language LTO and matched flags. Without LTO the residue is about one call per non-push builder call; M1 measures it. |
| **Tables** (`lcgf::Ui`, ui! / include_ui!) | one frame call plus setter stores | The prebuilt frame reads the tables as data, and today decodes and converts each row's style every frame (seam.zig:350–356) | **Against Zig through the seam: yes** (same code). **Against Zig comptime:** first fix the seam (WP0.5 row-template cache), then measure again. If a gap remains, close it with per-UI specialized code (`specialize`, WP13), a shared `TablesUi` (§6.5), or S2 (open question 10). |

### Each choice: cost and how it stays zero

| Choice | Cost | How it stays zero / how it is verified |
|---|---|---|
| Generated `sys.rs`, typed enums, newtypes, mechanical C structs | 0 | Same words; `offset_of!` asserts; the layout hash is checked at init. |
| Generated export wrappers (§6) instead of hand `cX` functions | 0 | Same body: decode, call, encode. The `lcgf_frame *` handle is one extra load per call, against today's `rt` pointer. |
| `const fn Row::from` + `#[inline(always)]` | 0 for constant styles; run-time styles cost what Zig's `open` costs | `PANEL`-style const asserts; `cargo asm` of the styled scene shows no `Row::from` body for const styles. |
| `const fn` Style setters | 0 | SROA after inlining; `cargo asm` check. |
| Closures and guards | 0 | Monomorphized; `#[inline(always)]` on `row`, `col`, `reuse`. |
| Push variant (a / b / c, §3 T3) | (c) costs one call per row with extras, under a narrowed parent, or at overflow | Chosen by M2; erased by LTO. |
| Other builder calls (text, widgets, close, animate, end) | One direct call each | LTO inlines them. |
| `Frame::end` typestate, `Input<'k>`, `#[must_use]` | 0 | Types only. |
| Input copied into the Context at `begin` (§6.5) | One ≈200-byte copy per frame | Replaces the copy runtime.zig's shadow makes today. |
| Bounds checks in Rust hot loops (`ct.rs`) | A compare per data-dependent index | Up-front `assert!(last <= N && b.parent.len() >= last …)` at the start of `fit`, `resolve`, `place` and `finalize` removes the loop-index checks. Indices loaded from tables get a generated `const _: () = assert!(max(..) < N)` and `get_unchecked`, with a `SAFETY` comment citing that assert, **only where `cargo asm` shows `panic_bounds_check` in the loop and the bench shows a gap**. `View::push` has no checks (raw columns, clamped index). |
| Rust build profile | Today 16 codegen units, no LTO, unwind | Workspace `[profile.release] codegen-units = 1, lto = "fat", panic = "abort"`, as bench/vs/lcgf-rust uses. |
| Target CPU and lanes | Today the gate's Rust links `liblcgf_l4` against Zig's native build | The gate builds with `RUSTFLAGS="-C target-cpu=native"`; every bench line prints its lane count; pairs are compared only at equal lanes. |
| **T-LTO**: rustc `-Clinker-plugin-lto` + Zig-emitted LLVM bitcode | removes the call residue | New `zig build abi -Dlto` installs `liblcgf_l{4,8,16}.bc.a`; a cargo feature `lto` links it with clang/lld. Needs the same LLVM major: the host's rustc is LLVM 21.1.8; check the pinned Zig with `nix develop -c zig cc --version`. Otherwise the feature refuses with a message. `objdump -d` proves the calls are inlined. |
| **Seam row-template cache** (WP0.5, from the C++ plan) | removes the per-row Style decode and `Template.from` from the tables frame | Templates built once at `lcgf_ui_init`, sized into `lcgf_ui_bytes`. Gate byte-identical. |
| **`specialize`** (WP13, only if a gap remains after WP0.5) | removes the table walk | build.rs compiles a two-line Zig stub exporting `ComptimeUi(State, spec, th).frame` with `zig build-obj`. Needs Zig at build time, so opt-in. |
| A ct.rs-style Rust port of the tables frame | — | Rejected: a new hand re-implementation. |

### The benchmark that proves parity

A new `bindings/check/parity.sh`, run by `nix develop .#vs -c ci/run.sh bindings-parity`.

**Method:**
- Build once with matched flags: Zig `-Doptimize=ReleaseFast` native; Rust `target-cpu=native` with the release profile.
- Pin to one core (`taskset -c 3`).
- Interleave A/B for 9 rounds per pair, each round being the existing `--bench` loop.
- Print each side's median and min–max, the ratio Rust/Zig, lanes, CPU model and commit.

**Pairs:**
1. Tables: `lcgf-dump {toolbar,mixer,panel} comptime|seam --bench` against `lcgf-check … --bench`.
2. Runtime: new `lcgf-rt-dump <scene> 120 --bench` against `lcgf-rt-check <scene> 120 --bench` for form, list, springs, resize, text and the five idiom scenes.
3. Static: `lcgf-ct-dump <ui> 240 --bench` against `lcgf-ct-check <ui> 240 --bench` for all ten UIs.

**Pass rule:** median ratio ≤ 1.02 on a pinned bare-metal machine (this Ryzen 7 8700F qualifies). The script fails above 1.05 there and only prints on shared CI VMs (bindings.md reports 5–25% run-to-run spread there).

### Measurement order

- **M0** (before any code): the current binaries, as-is and with matched flags. Read the Zig `seam` line next to the Rust and `comptime` lines, to separate the lane/profile mismatch from the seam's own cost.
- **M1**: runtime scenes, Rust against Zig, matched flags.
- **M2**: the three push variants (a, b, c) on form, list, springs, resize and text; then again after LTO.
- **M3**: tables pairs after WP0.5, which decides whether WP13 is needed.

### Where parity is not reachable

- Tables UIs against Zig comptime through any prebuilt generic frame: it reads its tables as data. WP0.5 narrows the gap; only comptime-known tables (`specialize`, or `TablesUi` in Zig) or S2 close it.
- Debug builds and `opt-level = "s"` builds are not targets.
- Without matching LLVM majors there is no LTO, and the runtime front end keeps about one call per non-push builder call; M1 shows whether that is inside 2%.

---

## 6. `src/abi/`: the Zig API in C form (shared with the C++ plan)

### 6.1 The rule
Every exported C function is a `pub fn` of a Zig declaration reachable from `src/lcgf.zig`, named `lcgf_<type>_<method>` in snake case (`Frame.open` ↔ `lcgf_frame_open`, `Context.begin` ↔ `lcgf_context_begin`). A free function of a widget module is `lcgf_<module>_<fn>`, shortened to `lcgf_<module>` when the function has the module's name (`button.button` ↔ `lcgf_button`). Every C type is the Zig type, named `lcgf_<snake type>` (`types.Style` ↔ `lcgf_style`).

`src/abi/abi.zig` applies this mapping by comptime reflection:

| Zig | C | The generated wrapper does |
|---|---|---|
| extern struct; enum or bitpack with an integer tag | the same struct (`offsetof` asserts generated) | a pointer cast |
| any other struct (Style, TextStyle, Theme, Limits, Input, Mono, Outline, Transition, Spring, rounding.Options, Output, DrawList) | a word struct in `plan.put` order; slices inside it become `ptr` + `len` | decode/encode: what runtime.zig does by hand today |
| `[]const T` parameter | `const T *x, size_t x_len` | builds the slice |
| `[]T` result | `T *f(…, size_t *len)` | |
| `?T` (enum, u32, pointer) | sentinel `0xffffffff` or `NULL` | |
| `Id`, `Node`, `Signal`, `enum(u*)` | `uint32_t` | |
| `bool` result | `int` (runtime.zig:140's lesson) | |
| `E!T` | `int` status plus an out parameter; error names map to `lcgf_status` values in the order api.zig lists them | |
| `*Frame` receiver | `lcgf_frame *`: two pointers, extern-compatible | |
| `*Context` receiver | `lcgf_context *`: caller memory of `LCGF_CONTEXT_SIZE` / `_ALIGN`, generated from `@sizeOf` / `@alignOf` | |
| `anytype` or `comptime` parameters | not exported, except instantiations api.zig lists (`animate` and `tween` at f32; `openRow` / `leafRow` / `customRow` at `*const FlatRow`) | |

`abi.Wrap(comptime f)` generates a `callconv(.c)` wrapper per arity (0–8). Each parameter type goes through `CType`; the body is `fromC` per argument, the call, then `toC` on the result. The cost is what today's hand-written `cOpen` / `cText` cost: one call plus the decode.

### 6.2 Audit of today's src/abi (4,891 lines)

| File | Today | Verdict |
|---|---|---|
| `lcgf.h` (322) | hand header; LCGF_RT_LAYOUT checked by a test | **Collapses into a generated header**: types and prototypes from api.zig, with doc comments taken from the Zig source's `///` via `std.zig.Ast`. Only the lane macros stay hand-written (`lcgf_lanes.h`, ≈30 lines). |
| `lib.zig` (9) | calls three `exportAll`s | Stays: one `abi.exportAll(api)`. |
| `runtime.zig` (457) | its own `Runtime` shadow (ctx + frame + input + theme + font), 28 hand `cX` wrappers, `CLimits` (6 of 11 fields), the word counts, the `layout` hash, `CView` | **Collapses.** Context goes in caller memory and `lcgf_frame` is a value; the wrappers are generated; `lcgf_limits` is the words of `context.Limits`, all fields; the hash is generated over every exported type. CView moves to `view.zig`, generated. |
| `seam.zig` (750) | `CInput` (7 of Input's 16 fields), `CDraw`, `CFrame`, `cDraw`, `Status`, `ExternState`, the tables `Ui` (70–410), `SeamUi` | **CInput, CDraw, CFrame, cDraw and Status collapse** into the mechanical `lcgf_input`, `lcgf_draw_list`, `lcgf_ui_output` and generated statuses. The tables `Ui`, `SeamUi` and `ExternState` **stay** (moved to `tables_ui.zig`): ComptimeUi's frame driven by data, the no-Zig path. Their long-term merge is in 6.5. |
| `plan.zig` (954) | the word codec and layout hash (542–640), plus the dynamic tables format (`plan`, `encode`, `decode`, `emit`, `Header`) | The codec **moves** to `words.zig` (the mechanical engine). The tables format **stays** (`tables.zig`). |
| `ct.zig` (1,549) | the static tables format (`make`), its prebuilt `Ui`, exports | **Stays** (`static.zig`); exports come from api.zig. |
| `auto.zig` (221) | lane dispatcher over three export tuples | **Stays**; entries come from api.zig. |
| `zon.zig` (629) | the `.zon` reader; `ZStyle` is a hand subset of Style | **Stays**; ZStyle becomes a generic derivation of `Style` (Color → `?ZColor`). |

### 6.3 What stays seam-specific, and why
1. **Tables formats** (`tables.zig`, `static.zig`) and `zon.zig`. They are the data form of comptime arguments (`ComptimeUi(State, spec, th)`, `ct_layout`) for programs without a Zig compiler; Zig has no run-time API to mirror.
2. **`tables_ui.zig`**, the data-driven ComptimeUi frame, until 6.5.
3. **Lane-suffixed frame symbols and `auto.zig`.** Zig fixes lanes at compile time; a prebuilt library has to name or dispatch them.
4. **`view.zig`**: the inline-push view (the `Template.node_fields` columns plus the counters). It is a performance device with no Zig counterpart, since Zig inlines `open`. Its field list is generated.
5. **Handles in caller memory, `int` statuses, `ptr` + `len`.** C has no comptime layouts, no error unions and no slices.
6. **The state-struct contract** (`ExternState`, field offsets carried in the tables).

### 6.4 Target layout

| File | Holds | Est. lines |
|---|---|---|
| `abi.zig` | mapping engine: `CType`, `toC` / `fromC`, `Wrap`, `exportAll`, statuses | 280 |
| `words.zig` | word codec and layout hash (from plan.zig) | 130 |
| `api.zig` | the export list: method names per Zig type, generic instantiations, error order, seam-specific entries | 150 |
| `view.zig` | inline-push view | 60 |
| `tables.zig` | plan.zig minus the codec | 820 |
| `tables_ui.zig` | seam.zig's `Ui`, `SeamUi`, `ExternState`, tests | 600 |
| `static.zig` | ct.zig | 1,550 |
| `zon.zig` | generic ZStyle | 580 |
| `auto.zig` | dispatcher | 200 |
| `lib.zig` | root | 10 |
| generated by `tools/abi-gen` from api.zig | `lcgf.h` (+ hand `lcgf_lanes.h` ≈30), `lcgf/types.hpp`, `sys.rs`; committed, with a `zig build test` staleness check | — |

That is about 4,380 hand-written lines against 4,891 today, while the exported surface grows from 41 functions to the whole Context, Frame and widget list. Each new export is one name in api.zig.

### 6.5 Zig-side changes this needs
- **`Context.begin` copies the Input** into the context (`ctx.input = in.*`), so `Frame.in` never points at caller memory. That removes runtime.zig's shadow, and a Zig footgun. Cost: one ≈200-byte copy per frame. This is an open question for the user.
- **Name collision:** the tables UI's `lcgf_frame_u32_f32_l8` sits inside the new `lcgf_frame_*` namespace. It is renamed `lcgf_ui_frame_u32_f32_l8` (ComptimeUi ↔ `lcgf_ui`); the static frame becomes `lcgf_static_ui_frame_…`.
- **No declaration enumeration:** api.zig names each method explicitly (`@field(Frame, "open")`). It does not rely on `@typeInfo(..).decls`, which is unverified in 0.17: docs/ZIG_0_17_1.md lists only field reflection, and nothing in the repo uses it.
- **Tripwire:** a `zig build test` check that fails when a `pub fn` on any container api.zig lists appears in neither api.zig's export list nor its skip list (each skipped entry has a reason). It reads the names from the source with `std.zig.Ast`, which abi-gen already parses for doc comments. Without it, the bindings can fall silently behind the Zig API. Lands in step A2.
- **Later, optional:** ComptimeUi and tables_ui become one `TablesUi(tables)`, with tables known at comptime (Zig) or at run time (the seam). The seam frame then stops being parallel code, and comptime-known tables get comptime speed.

### 6.6 Migration order (the gate passes after every step)

| Step | Change | Verification |
|---|---|---|
| A1 | `abi.zig` and `words.zig` (codec moved; plan.zig re-exports). No exports change. | `zig build test` (a round-trip test per mapped type); gate unchanged |
| A2 | api.zig exports today's runtime surface under the new names, next to the old symbols; abi-gen emits the new header; the old lcgf.h stays; the tripwire test lands | gate unchanged; tripwire test |
| A3 | Rust and C++ switch to the generated header and externs and the new names | gate byte-identical; parity.sh unchanged |
| A4 | Delete runtime.zig and the old names; auto.zig reads api.zig | gate, including auto lanes |
| A5 | Mechanical Input, Limits, DrawList and Output replace CInput, CLimits, CDraw and CFrame (hash bump); `Context.begin` copies the Input; bindings in lockstep | gate, with inputs.py extended (time, wheel, text) |
| A6 | Renames and moves (seam.zig → tables_ui.zig, plan.zig → tables.zig, ct.zig → static.zig); lcgf-gen updated | gate |
| A7 | api.zig grows to the full Context, Frame and widget surface, in batches; each batch adds names and a gate scene | gate per batch |
| A8 | (optional) `TablesUi` shared with ComptimeUi, or S2 (open question 10) | gate; tables parity against comptime |

---

## 7. Ordered work packages

Each WP passes the full gate (`nix develop .#vs -c ci/run.sh bindings`, all sections) plus `nix develop -c zig build test fmt` and `nix develop -c ci/run.sh census-src`. From WP2 on, each also runs `bindings-parity`; no WP may raise any pair's median ratio by more than 1%. The A-steps are §6.6's, shared with the C++ plan, and land in lockstep with the C++ side.

| WP | Content | Files | Verification | Risks |
|---|---|---|---|---|
| **0** | Close the gating hole; fair baselines. Add a `styled` runtime scene (hidden and collapsed subtrees, cursor inheritance, paint_reference / paint_outset, transform + origin, text_styled, custom_row, radii clip). Add `--bench` to rt_dump / rt_check. `parity.sh`. Gate built with `target-cpu=native` and the release profile; lanes printed. Run M0 and M1. | `bindings/check/{rt_dump.zig,run.sh,parity.sh}`, `lcgf-check/src/rt_check.rs`, `bindings/rust/Cargo.toml`, `ci/jobs/bindings.sh`, new `ci/jobs/bindings-parity.sh`; C++ `rt_check.cpp` | `styled` identical in Zig, C++, Rust; M0 and M1 recorded with conditions | May expose a live `View::push` bug, to fix first. |
| **0.5** | Seam row-template cache built at `lcgf_ui_init` | `seam.zig` (`Ui.init`, the frame loop at 350–356, `layoutOf`) | Gate tables (toolbar, mixer, panel, auto lanes) byte-identical; M3 | Buffer size grows by the rows × 66 words; `BYTES` in generated code changes (lcgf-gen). |
| **1** | Soundness S1–S7 + the `paint_reference < i` clamp in `pushRow`'s extras branch | lib.rs, ct.rs, runtime.rs, tree.zig:533, seam.zig, lcgf-gen Rust emitters (main.zig:334, 896) | Gate; cargo tests (a moved `ct::Ui`, a wrong `S` → `Err`); Zig goldens; `zig build bench` rows unchanged | API break (`Input<'k>`). |
| **2 = A1–A4** | `abi.zig`, `words.zig`, `api.zig`; `tools/abi-gen` emitting `lcgf.h`, `types.hpp` and `sys.rs` (including the idiomatic `Style` / `TextStyle` with const setters and defaults); bindings switch to the generated names; delete runtime.zig and the hand mirrors in lib.rs and runtime.rs | src/abi/*, `tools/abi-gen/main.zig`, build.zig, `bindings/rust/lcgf/{build.rs,lib.rs,runtime.rs}`, C++ headers | Per A-step (§6.6); gate byte-identical; default-style word check; const-fold asm check; parity unchanged | Biggest step: split as A1, A2, A3, A4, each gate-passing. |
| **3** | Layout hash over every exported type; ct format assert (S8, S9) | words.zig, abi-gen, lcgf-gen | Gate; forged-hash test → `Err` | Old prefixes refused once (intended). |
| **4** | Push: measure (a), (b), (c) (M2); implement the winner, with generated column stores and a private `Row`; inline Close only if (c) wins | runtime.rs, view.zig, abi-gen (node_fields, slow mask), tree.zig (`Template.node_inputs`) | Gate (styled, tight, auto lanes); M2 parity ≤ +1% | Fallback: full inline push, but generated. |
| **5** | Idiomatic core: `row` / `col` closures, `Open` guard, `id!`, `Node`, `#[must_use] Response`, `Frame::end` typestate, `Output<'c>`, `Cmd` iterator, generated `Error`, prelude, additive GPU feature modules | runtime.rs, lib.rs, gpu/mod.rs, lcgf-check bins, bench/vs/lcgf-rust | Gate; `cargo test --doc` (LCGF_PREFIX); asm: no closure indirection, no bounds checks in `commands()`; parity | Public API break (open question 2). |
| **6 = A5** | Mechanical `lcgf_input`, `lcgf_limits`, `lcgf_draw_list`, `lcgf_output`; `Context.begin` copies the Input; Rust `Input<'a>` with time, wheel, text, contacts, safe_area, appearance; `Output` with status, platform, pace | src/abi, core context.zig, lib.rs, runtime.rs, inputs.py | Gate replay with text and wheel; `needs_frame` bytes identical | ABI hash bump; C++ in lockstep. |
| **7 = A6** | File moves and renames (`lcgf_ui_*`, `lcgf_static_ui_*`); lcgf-gen and the Rust generated modules updated | src/abi, tools/lcgf-gen, lib.rs | Gate | Pure moves; lcgf-gen output changes names only. |
| **8** | ct.rs: generated defaults, merged clamp, up-front asserts; `get_unchecked` only where asm and bench justify it | ct.rs, lcgf-gen (const max-index asserts) | Gate static + partial; static parity pairs | — |
| **9** | Full Style in `.zon` and `ui!` (generic ZStyle, macro passthrough) | zon.zig, lcgf-macros | `zig build test` (lcgf-gen = comptime tables); a new `styled.zon` UI in the tables loop | Static UIs must reject transforms with an error. |
| **10 = A7** | api.zig batches, each with Rust wrappers and a gate scene: (i) interact, drag, rects, set_fill, set_cursor, focus_scope, outline, animate_layout, sequence, transition, set_fill_animated, textfStyled's room form; `#[derive(Animatable)]`. (ii) timer, signals, `reuse` closure. (iii) layout split, rounding, `prepared.bind` (`Laid<'c>` typestate). (iv) widgets, ~8 per batch, with a generated `Kit`. | api.zig, runtime.rs, lcgf-macros, rt_dump.zig, rt_check.rs | Gate per batch, byte-identical; parity of existing scenes unchanged | Comptime-parameter widgets need run-time twins; reuse needs the push to handle copied rows (`xlen`). |
| **11** | The five idiom examples as `examples/*.rs` and gate scenes (app, styled, anim, list, custom) with `rt_dump.zig` twins; docs/guide/bindings.md snippets updated | lcgf/examples, rt_dump.zig, rt_check.rs, docs/guide/bindings.md (`snippets.py`) | Byte-identical against Zig; parity pairs for the five | Lands scene by scene with the batches in WP10. |
| **12** | Cross-language LTO feature (`zig build abi -Dlto`, cargo `lto`) | build.zig, build.rs, Cargo.toml | M2 with LTO; `objdump` inlining proof; gate with LTO on | LLVM skew; opt-in only. |
| **13** | `specialize` feature for tables UIs, only if M3 still shows a gap | lcgf-macros / build.rs helper, lcgf-gen (Zig stub), lib.rs | Gate tables with `specialize`; tables parity against comptime | Needs the Zig toolchain; opt-in only. |
| **14 = A8** | (optional) `TablesUi` shared by ComptimeUi and the seam, or S2 | src/widgets/base.zig, src/abi/tables_ui.zig | Gate; Zig widget goldens; tables parity | Large Zig refactor; schedule separately. |

Net effect:
- Rust: about −450 hand-written lines (mirrors, push slow path, macro whitelist, ct.rs duplicates).
- src/abi: 4,891 → ≈4,380 hand-written lines, with runtime.zig and the hand header gone. The exported surface grows from 41 functions to the full Context, Frame and widget list.
- C/C++ mirrors: about −300 lines.
- New: about +300 lines for the shared abi-gen emitter.

---

## 8. Open questions

1. **Generated files:** committed with a `zig build test` staleness check (agreed with the C++ planner), or installed into the prefix?
2. **Breaking changes:** may WP1, WP5 and WP6 break the public Rust API? It is at 0.1.0, and its only users are bench/vs and lcgf-check. May the C ABI break wholesale in A2–A6? Old names are kept only for one step.
3. **`Context.begin` copying the Input** (a Zig core API change, ≈200 bytes per frame, §6.5): acceptable? The alternative is keeping a seam-side shadow, which is one non-mechanical piece of the ABI.
4. **Parity bar:** median Rust/Zig ≤ 1.02 on a pinned bare-metal machine, failing above 1.05 there and only printing on CI VMs. Is that the bar you want, and is this Ryzen 7 8700F the reference machine?
5. **Tables UIs against Zig comptime:** if WP0.5's cache leaves a gap, choose the opt-in `specialize` feature (Zig at build time), the `TablesUi` merge (WP14), S2 (question 10), or accept the seam's speed for `ui!` / `include_ui!` UIs.
6. **LTO:** worth carrying as an opt-in feature given the LLVM-major coupling, or should parity be met without it?
7. **Widget scope:** all ~45, or a first batch (textfield, switch, radio, progress, tabs, select, scroll_area, vlist)?
8. **Styling scope:** does "full surface" include style.resolve, tokens, recipes, prepared paint and effects through api.zig, or stop at Style, Frame and Output for now? Under §6 each is a list of names, but several take comptime parameters and caller-owned pools that need run-time forms.
9. **UI renderer and accessibility:** should Rust get LCGF's quad/text renderer over `lcgf::gpu`, and the `Output.tree` queries (`lcgf_tree_*`), now or later?
10. **Spec UIs, S2 or `TablesUi`.** The C++ planner's alternative to A8 (WP14) is S2: lcgf-gen writes a spec UI as runtime-front-end code in C++ and Rust, and `tables_ui.zig` and the dynamic tables format are deleted.
    - **Precondition:** S2 holds only if a `base.Harness` probe shows the runtime front end draws byte-identically to ComptimeUi for toolbar, mixer and panel, events and focus included.
    - **What S2 removes:** the largest remaining seam-specific design, about 1,400 lines (tables_ui.zig plus the tables half of tables.zig), and the per-row style decode that WP0.5 caches.
    - **Rust side:** acceptable if the probe passes. `ui!` / `include_ui!` would expand to calls into §4's idiomatic runtime API, with constant styles folded to `const` rows. The generated `State`, `Widget` and `Event` enums and the setters stay the same. `BYTES` becomes `Context::bytes` for the UI's limits. Its speed is then the runtime front end's (§5), which removes the tables parity problem.
    - **If the probe fails:** keep `tables_ui.zig` with the WP0.5 row cache, and leave `TablesUi` (WP14) as the long-term option.

---

## 9. Decisions (2026-11-26, user: "best long-term approach, recommended approach")

| Q | Decision |
|---|---|
| 1 Generated files | Committed, with a `zig build test` staleness check. Layout hashes stay the runtime guard. |
| 2 Breaking changes | Yes. Rust (0.1.0) and the C ABI break wholesale across A2–A6; old names live for one step only. |
| 3 `Context.begin` copies the Input | Yes. The core change removes the seam shadow and the dangling-`Frame.in` footgun. |
| 4 Parity bar | Gate on instruction count (`perf stat -e instructions:u`, ratio ≤ 1.02), which is stable on VMs. Median ns is printed, and must stay ≤ 1.02 on this Ryzen 7 8700F (fail above 1.05 there); CI VMs only print it. |
| 5 Tables UIs vs comptime | WP0.5 row cache first. Then the S2 probe: if the runtime front end matches ComptimeUi byte for byte, S2 (lcgf-gen emits runtime-front-end code; delete `tables_ui.zig` and the dynamic tables format). Otherwise `TablesUi` (A8). `specialize` only if a measured gap remains after that. |
| 6 LTO | Yes, as an opt-in feature. |
| 7 Widget scope | All widgets. C-mappable ones in batches first; text widgets through exported capacities `Text(64)`, `Text(256)`, `Text(1024)`; comptime-definition widgets get run-time variants, then export mechanically. |
| 8 Styling scope | Full surface: `style.resolve`, tokens, recipes, prepared paint and effects through `api.zig`, after the Frame/Context/widget batches, adding run-time forms where they take comptime parameters. |
| 9 Renderer and a11y | Yes, later: export the software renderer and ship the quad/text WGSL through lcgf-gen for `lcgf::gpu`; export the `Output.tree` queries. |
| 10 S2 or `TablesUi` | S2 if the probe passes (see 5). |
