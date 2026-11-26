# HTML + CSS → LCGF compiler: plan

Planning document (planner: plan-markup, 2026-11-26). Nothing was edited. Study base `main` 141d297d; the Decomposer removal is committed as 7040bdcc; tools/ was reorganized in 49a577a7. Prior art read from `git show 141d297d:…`, `docs/plans/markup-coverage/`, and the stop-point handoff `~/Downloads/LCGF-HTML-CSS-stop-handoff.md`. All file:line references are to the current tree unless prefixed `141d297d:`.

Aligned with the C ABI direction in `docs/plans/bindings-rust.md` §6: `src/abi/` becomes the Zig API in C form (`api.zig` lists exported `pub fn`s, comptime-reflected wrappers named `lcgf_<type>_<method>`, `tools/abi-gen` emits `lcgf.h`, C++ and Rust types from the Zig types; `zon.zig`'s `ZStyle` derived from `Style`).

## 0. Findings that shape the design

1. **Most of the old plan's gaps are now closed:**
   - G1 (literal text) and G2 (per-node text style): `Spec.text` and `Spec.text_style` exist (spec.zig:28-30), and ComptimeUi honours `text_style` (base.zig:668).
   - Regions: ComptimeUi builds `list`, `when` and `choice` rows (base.zig:357, 691).
   - G3 (more than one custom row): `customCapacity` counts every custom row (base.zig:813).
   - G6 (per-widget state colours) is partly closed: comptime recipes take part, variant, state and environment rules for button, checkbox, switch, slider, textfield, radio, range and spinner (recipe_comptime.zig:23-60).
   - Still open: G4. Overlays run only in `ComptimePage`, apart from the other widgets (popover.zig:342).
2. **The layout extensions are not reachable from either front end.** These tier-0 side passes exist but nothing calls them:
   - `Flex.Style`: margin, wrap, align-self, aspect and baseline (flex.zig:97-132).
   - Grid (grid.zig:31-577) and named grid areas (grid_names.zig).
   - Anchors and layers (overlay.zig:34-212).
   - Sticky positioning (scroll.zig:125) and RTL (rtl.zig:70-123).
   `Frame.arrangeWith` (frame.zig:387) runs only the plain sequence, and `Spec` has no flex or grid field. CSS margin, `flex-wrap`, `align-self`, grid and `right`/`bottom` all need front-end integration first.
3. **Only four widgets cross into C++ and Rust today.**
   - The ZON spec (zon.zig:131), `plan` (plan.zig:65) and the runtime seam (runtime.zig:317-319) carry row, col, label, text, button, checkbox and slider. That is 4 of 42 widget modules.
   - Static UIs (`ct.zig`) drop buttons as well.
   - Literal labels do not cross: `plan.walk` ignores `Spec.text` (plan.zig:405-441).
   - Per-label `TextStyle` does not cross either: one `looks.label` is used for every label (plan.zig:531).
   The settled `api.zig` + reflection direction is the route by which the other widgets' runtime functions reach C++ and Rust (§5 F5).
4. **The styling layer already holds what CSS's dynamic half needs:**
   - Per-property resolution with states, variants, parts and environment conditions: `style.resolve`, `States` (resolve.zig:39), `Rule` (resolve.zig:123), `Conditions` (environment.zig:85).
   - Two-stop gradients, a blurred shadow quad and dashed or dotted borders as quad features (features.zig:39-78).
   - Paragraph options (stack.zig:38).
   - Named colours and colour functions (svg.zig:342, color_math.zig).
   - Units (units.zig:8-147).
5. **The build system and Rust tooling can already do ephemeral generation.**
   - The pinned Zig has `Run.addDepFileOutputArg` (Run.zig:535) and `addUpdateSourceFiles` (Build.zig:941).
   - CMake already generates into the binary dir (lcgfConfig.cmake:55-77).
   - A Rust proc macro already runs `lcgf-gen` and tracks its input through `include_bytes!` (lcgf-macros/src/lib.rs:83-86).
6. **The removed compiler (committed in 7040bdcc) leaves two things worth keeping and one to avoid.**
   - Keep: the Lexbor C bridges that stamp source positions (`141d297d:tools/decomposer/{html,css}.c`) and the build-helper shape (`141d297d:tools/decomposer/integration.zig:15-48`).
   - Avoid: its cascade and emitter were Python (`styles.py`, 953 lines). A prebuilt C++/Rust toolchain cannot carry Python.
   - Side effect: `docs/plans/markup-coverage/report.py:10` imports the deleted `mapping.py`, so it is already broken.

---

## 1. Architecture

### 1.1 Where the compiler lives: the host tool `lcgf-gen`

The HTML front end becomes another input format of **`lcgf-gen`** (tools/lcgf-gen/main.zig:40). It already dispatches on input kind (`.zon`, `--wgsl`), is shipped prebuilt by `zig build abi` and writes C++ and Rust.

- New directory `tools/lcgf-gen/markup/`, written in Zig:

| File | Purpose |
|---|---|
| `lexbor.zig` | `extern` declarations for about 25 Lexbor functions, in the hand-written style of src/text/shape/harfbuzz.zig |
| `html.zig` | DOM to node table, with source positions stamped through Lexbor's `mutation.inserted` hook, ported from `141d297d:tools/decomposer/html.c` |
| `css.zig` | Stylesheet rules, selectors and declarations with byte offsets |
| `values.zig` | Typed CSS values, reusing `svg.parseColor` (svg.zig:342), `color_math` and `units` |
| `cascade.zig` | Selector matching, specificity, inheritance, custom properties |
| `ir.zig` | The page IR, §1.3 |
| `lower.zig` | Element/property tables, §2 |
| `emit_zig.zig`, `emit_cpp.zig`, `emit_rust.zig` | One emitter per language; the C++ and Rust emitters name the types `tools/abi-gen` emits (Style, TextStyle, Row, widget state types), never re-declare them |
| `to_zon.zig` | IR to `zon.ZSpec`, for the existing table backends |
| `manifest.zon` | One row per mapping decision, §2.6 |
| `testdata/` | Fixtures and expected output |

- **Why not Zig comptime parsing:**
  - C++ and Rust users have no Zig compiler (docs/guide/bindings.md:3).
  - Parsing HTML and CSS at comptime would be paid on every build; the old plan rejected it for the same reason (`141d297d:docs/plans/markup.md:783`).
- **Tiering:** the tool is outside the tiers, like `bench/`. Generated code imports only `lcgf` and the app module, exactly as hand-written code does.
- **Command line:**

```
lcgf-gen ui/app.html [--css extra.css]... --lang zig|cpp|rust|zon
         [--frontend auto|spec|tables|static|runtime] -o OUT [--depfile OUT.d]
         [--explain] [--mappings] [--check VENDORED] [--no-line-directives]
```

### 1.2 Parser: Lexbor 3.0.1 for both languages, through the HTML5 tree builder

| Option | Verdict |
|---|---|
| **Lexbor 3.0.1** (C99, Apache-2.0, lazy `build.zig.zon` dependency, built for the host with `zig cc`) | **Chosen.** Already researched, pinned and hashed (`141d297d:docs/research/markup/parsers.md`). Builds with no generated headers and 0 errors on 0.18.0-dev.1151. One dependency covers HTML5 tree construction, entities, CSS Syntax 3 and Selectors. Positions come from tokens (`begin`) and `offset.{name,value}_begin`. |
| html5ever + Lightning CSS (the lost attempt) | Rejected. Needs cargo at build time, which only the `vs` shell has (flake.nix:108-114). Breaks "Zig apps need only zig" (DEPENDENCIES.md:3). |
| superhtml (Zig) | Rejected. Fails on 0.18-dev. |
| Own parser | Rejected. HTML5 recovery and the CSS tokenizer are thousands of lines of conformance surface. |

- **Tree builder or tokenizer.** The old plan used the tokenizer only because its vocabulary was invented tags (`<col>`, `<row>`). This plan uses **standard HTML elements plus hyphenated custom elements** (`lcgf-*`, app components). The tree builder keeps custom elements as written and gives users the HTML they expect: optional end tags, implied `<tbody>`, entity decoding. Lexbor parse errors such as foster parenting become warnings with positions.
- **`<template>`** contents are an inert DocumentFragment, which the structural directives use (§3.5).
- **Dependency policy.** Re-add the row 7040bdcc removed:

  ```
  | Lexbor 3.0.1 (Apache-2.0) | Source, build.zig.zon (lazy) | lcgf-gen markup | Optional | HTML5 tree construction, CSS syntax and selectors | Host only; never linked into an application |
  ```

  `lcgf-gen` built by `zig build abi` links it statically, so C++ and Rust users get it prebuilt.

### 1.3 The IR: a markup IR, lowered to `zon.ZSpec` where possible

**Recommendation:** ZON stays the language of the C seam's tables, and the markup IR is a superset. Everything `plan`/`ct.make` can execute goes through `to_zon.zig` into the existing `zon.expand` (zon.zig:245) or `expandStatic` (zon.zig:359). That reuses `plan`, `encode`, both lcgf-gen emitters (main.zig:232, 292, 641, 761) and the B2 table gate unchanged. `--lang zon` dumps that ZON for inspection.

**What the ZON language lacks for HTML** (each item is a WP in §6 or a reason to use another frontend):

| # | Gap | Evidence | Resolution |
|---|---|---|---|
| Z1 | Widgets beyond row/col/label/text/button/checkbox/slider/list/choice/virtual_list/custom | zon.zig:131-151; plan.zig:65 `Kind` | Runtime frontend (§1.4) over the api.zig-exported widget functions (F5). Tables stay the four reference widgets. |
| Z2 | Literal text (`.label` names a field, zon.zig:135) | | `to_zon` emits `.text = .{ .format = "<escaped literal>" }` with no args (fmt.zig format, `{{` `}}` escaping). No seam change. |
| Z3 | Per-node `TextStyle` | plan.zig:531 uses `looks.label` for every label | **NEW** `ZNode.label`/`.text` take `text_style` (as abi-gen's derived TextStyle); `plan.Row` gains a text-style index into a new `text_styles` column (plan.zig:670 `Column`, version 1→2, layout hash bump). |
| Z4 | Style fields: `participation`, `cursor`, `float`/`offset`, `scroll`, `radii`, `transform`/`transform_origin`, `params`/`texture`/`uv`, `paint_reference`/`paint_outset`, `role`/`value`, accessible name | zon.zig:78-124 vs types.zig:394-454 | Closed by the settled change that derives `ZStyle` from `Style`. What remains is the accessible name, as `ZNode.*.name` (Spec.name spec.zig:43). |
| Z5 | Colours: rgb, rgba or 6 theme tokens; one theme (zon.zig:53, 168) | | The compiler resolves colours to rgba before ZON. Theme overrides are folded into styles. |
| Z6 | Field types str/bool/f32/u32/u8/color only | plan.zig:55 | Pages needing `Text(cap)`, `Hsva`, `[2]f32`, `Number` or enums use the runtime frontend. |
| Z7 | Handlers, effects, events | Events are polled (bindings.md:75-85) | Dispatch is generated code around the tables (§3.3), so ZON needs nothing. |
| Z8 | App components with code (`Spec.widget`) | plan.zig:409 `@compileError` | Runtime frontend. Draw-only components become `.custom`. |
| Z9 | Per-copy list data; unbounded lists | spec.zig:243-244 | Runtime frontend. |
| Z10 | Flex, grid, margin | Neither ZON nor Spec has them | **NEW** §5 F2/F7, then a ZStyle `flex` block (derived from `Flex.Style` the same way). |
| Z11 | Source locations in diagnostics | zon.zig:190 messages have no position | The markup front end validates before `to_zon`; ZON errors cannot occur for generated input. |

The IR itself is plain arrays, as a compiler pass over rows:

```zig
// tools/lcgf-gen/markup/ir.zig
pub const Page = struct {
    name: []const u8,
    nodes: std.MultiArrayList(Node),  // depth-first; parent index; children contiguous
    fields: []Field,                  // view state: name, type, default, first use (Loc)
    handlers: []Handler,              // name, event kind, payload type, uses (Loc)
    components: []Component,          // tag, props (name, type), kind: zig_spec | zig_widget | runtime | draw
    assets: []Asset,                  // path, intrinsic size (read from the PNG header), Loc
    fonts: []FontFace,                // @font-face: family, weight, style, path
    styles: []types.Style, text_styles: []types.TextStyle, flex: []FlexBlock, paragraphs: []Paragraph,
    variants: []Variant,              // style alternatives selected by a field (§5 F3)
    rules: []RuntimeRule,             // state- and media-dependent rules for recipes (§2.3)
};
pub const Node = struct {
    kind: Kind,                // container, label, text, heading, widget(WidgetKind), region(...), component, custom
    parent: u32, loc: Loc,     // file id, line, col
    style: u32, text_style: u32, flex: u32, variant: u32,
    bind: u32, text: Text, attrs: u32, role: types.Role, name: Text, id: u32,
};
```

### 1.4 Frontends (lowerings)

| Frontend | Languages | Code it emits | When `auto` picks it | Cost |
|---|---|---|---|---|
| `spec` | Zig | A `Spec` value of `spec.*` and `widgets_*.ct.*` builders, plus `ComptimeUi` (base.zig:340) or `ComptimePage` (popover.zig:342); runtime subtrees through `ct_interop.region` (interop.zig:28) and `compose` (interop.zig:104) | Always for Zig | Hand-written comptime page, proven by the `.text`-identity check (§6) |
| `static` | C++, Rust, Zig (parity) | IR → ZSpec → `lcgf-gen --static` (main.zig:641/761) | Only rows, cols, labels, checkboxes, sliders and regions, no buttons (bindings.md:205-208) | Folded `constexpr` tables, at or below Zig's speed (bindings.md:316-323) |
| `tables` | C++, Rust, Zig (parity) | IR → ZSpec → `lcgf-gen` widget tables plus liblcgf seam | Z1-Z9 do not apply | One seam call per frame |
| `runtime` | Zig, C++, Rust | A `build(frame, …)` function per page. Constant rows are `constexpr lcgf::Row` / `const Row` (bindings.md:167-175); widgets are one call each to the `lcgf_<type>_<method>` wrappers api.zig exports (§5 F5) | Anything else | What the same UI costs in Zig's runtime front end (bindings.md:495-504) |

`--explain` prints the choice and the first blocking construct, for example `app.html:14:5: note: runtime frontend: <input type=text> is not in the seam's widget tables`.

---

## 2. Mapping tables

Conventions:
- `spec:N` means `src/comptime/spec.zig:N`, `types:N` means `src/core/types.zig:N`, and `w/x:N` means `src/widgets/x.zig:N`.
- Every widget target gives the runtime function first and the `ct` builder second.
- **NEW** items refer to §5 by id (F1, F2, …).
- Every rejected row has an exact diagnostic, printed as `file:line:col: error: …` with the source line and a caret.

### 2.0 Authoring syntax (which attributes mean what)

| Form | Meaning | Lowering |
|---|---|---|
| `{field}` in text | Show a string field | spec `label(.field)` spec:104 / `ct.label` w/label:59 / runtime `label` w/label:51 |
| `{field:.N}`, mixed text `Gain {g:.1} dB {name}` | Format | `spec.text("Gain {.1} dB {}", .{.g,.name})` spec:164; runtime `Frame.textf` frame.zig:125. Type inferred: `:.N` means f32, plain means str unless the field's type is already fixed. |
| Literal text only | Constant label | `spec.label("…")` spec:104 (no signal mask); ZON: an argument-free format (Z2) |
| `bind:value="f"`, `bind:checked="f"`, `bind:open="f"`, `bind:selected="f"` | Two-way binding of the widget's value | The builder's `bind` argument (widget table below) |
| `attr="{f}"` on `disabled`, `hidden`, `readonly`, `required`, `class:x` | One-way bool | §2.3 / F3 |
| `on:click="name"` and the other events of §2.5 | Handler | §3.3 |
| `<template lcgf-if="f">`, `<template lcgf-else>` | Conditional | `spec.when` spec:273; with else `spec.choice` spec:286 |
| `<template lcgf-each="n" lcgf-max="16">` | Bounded repeat | `spec.list` spec:245 |
| `<template lcgf-each="item in items" lcgf-key="id">` | Repeat over app data | Runtime region (§3.5) |
| `<template lcgf-each="item in items" lcgf-window="row_h" lcgf-visible="10" bind:scroll="y">` | Virtualised | `spec.virtualList` spec:253 / `vlist` w/vlist:141,174 |
| `<template lcgf-switch="mode">` with `<template lcgf-case="compact">` | Alternatives by enum | `spec.choice` spec:286 |
| `<x-name prop="{f}">` | App component (§3.4) | |
| `id="x"` | Widget id: tag of `Events(spec).Widget` events.zig:57; runtime `Id.from("x")` types:12 | |

Identifier rules: `[a-z][a-z0-9_]*`, not a keyword of Zig, C++ or Rust. The compiler checks against the union of the three keyword lists, so one markup compiles in every language. Message: `'type' is a keyword in Rust; name the field something else`.

### 2.1 (a) HTML elements and attributes

#### Document and metadata

| HTML | Target | Notes / diagnostic |
|---|---|---|
| `<!doctype html>` | required (standards mode) | missing → `use <!doctype html>; quirks mode is not supported` |
| `<html lcgf-page="Name" lang>` | page name → generated namespace/type names; `lang` → kept for a11y export when the host supports it | |
| `<head>` | no node | |
| `<title>` | generated `pub const title` / `constexpr title` / `pub const TITLE` | the shell's window title is the app's call |
| `<meta charset>` | must be UTF-8 | other → `only UTF-8 sources are read` |
| `<meta name=viewport>`, other `<meta>` | ignored with note | |
| `<link rel=stylesheet href=local>` | CSS input, depfile entry | remote URL → `remote stylesheets are not fetched; vendor the file` |
| `<style>` | CSS input in document order | |
| `<script>` | rejected | `no JavaScript: behaviour is code in your app; name a handler with on:click="save"` |
| `<script type="application/json" id>` (data block) | ignored with note | |
| `<noscript>` | children ignored | |
| `<body>` | root container: `spec.col` spec:90 / `Frame.open` frame.zig:70; UA style `.{ .size = .{ .fill, .fill } }` | |
| `<base>` | rejected | `<base> is not supported; write paths relative to the page` |

#### Sectioning and grouping (layout container is `col`, or `row` when the computed `flex-direction` is `row`)

| HTML | Target |
|---|---|
| `div`, `span` (block-level use), `figure`, `hgroup`, `address` | `spec.col`/`row` spec:90/97; runtime `Frame.open` frame.zig:70 |
| `main` | `spec.landmark(.main, …)` spec:115 (`Role.main` types:319) |
| `nav` | `landmark(.navigation)`. If the `aria-label` contains "breadcrumb" and the children are `<a>` → `breadcrumb.trail` w/breadcrumb:32/132 |
| `header` | `landmark(.banner)` when not inside `article`/`aside`/`main`/`nav`/`section`, else `col` (HTML-AAM rule) |
| `footer` | `landmark(.content_info)` with the same ancestry rule |
| `aside` | `landmark(.complementary)` |
| `article` | `landmark(.article)` |
| `section` | `landmark(.region)` only when it has an accessible name, else `col` |
| `form` | `landmark(.form)` plus a form owner (§2.5) |
| `search` | `landmark(.search)` |
| `h1`…`h6` | `spec.heading(level, caption)` spec:123; runtime `Frame.textStyled` frame.zig:166 with `.role=.heading, .value=level`; UA font sizes in text_style (2em…0.67em resolved at build time) |
| `p` | label with `text_style.wrap = true` types:460; mixed phrasing children → **NEW F11** inline runs; until then `inline formatting inside <p> needs inline runs (F11): split the text or use one element` |
| `pre` | label, `whitespace = .preserve`, monospace font from the font table |
| `blockquote` | col (UA indent padding) |
| `br` | `\n` inside the label's text (literal) |
| `hr` | `separator.separator` w/separator:27/52, orientation from the parent axis |
| `ul`, `ol`, `menu` | col with **NEW F1** `Role.list`; `ol start/reversed/type` → markers computed at build time with `counters.format` (text/layout/counters.zig:179) |
| `li` | row: marker label + content col, **F1** `Role.list_item`; marker text: `•` / counter string; in a runtime each → `counters.format` at run time |
| `dl`/`dt`/`dd` | col / label / col (UA indent) |
| `table` / `caption` / `thead`… / `tr` / `th` / `td` (static) | **NEW F7** grid: `Grids.grid` grid.zig:176, `item` 216, `span` 278 (colspan/rowspan); roles **F1** `table`, `row`, `cell`, `column_header`, `row_header` |
| `<table lcgf-data="rows" lcgf-columns="…">` | `table.table` w/table:295/355 (sortable data grid) |
| `details` + `summary` | `accordion.open/close` w/accordion:33/50, `ct.section` 119; `open`/`bind:open` → the `expanded` bool |
| `dialog` (arbitrary content) | `popover.Popover(th, .id, .open)` w/popover:95 with `scrimStyle` 147 when `showModal` semantics (`lcgf-modal`); comptime page → `ComptimePage` popover:342 (G4 → F10) |
| `dialog` containing only text plus `<form method=dialog>` buttons | `dialog.Dialog(th,.id,.field,def)` w/dialog:71 (`Def.buttons` from the buttons) |
| `[popover]` + `popovertarget` | `Popover` w/popover:95, trigger = the target button |
| `[title]` attribute on an interactive element | `tooltip.Tooltip(th,.target,.tip)` w/tooltip:58; runtime `tooltip.show` 131 |
| `template` (without lcgf-*) | inert, ignored |
| `slot` | inside component files (§3.4) |
| `iframe`, `object`, `embed`, `audio`, `video`, `track`, `source`, `picture`, `map`/`area`, `math` | rejected: `<video> needs a media host, which LCGF does not provide` (HTML-12/13/15 in docs/plans/markup-coverage/html.md) |

#### Text-level

| HTML | Target |
|---|---|
| `span`, `strong`, `b`, `em`, `i`, `small`, `mark`, `code`, `kbd`, `samp`, `var`, `s`, `u`, `sub`, `sup`, `abbr`, `cite`, `q`, `time`, `data`, `bdi`, `bdo` used alone | a label with the element's UA text_style; `b`/`strong`/`i`/`em`/`code` select fonts through the font table (§2.2); nested in phrasing → F11 |
| `a href` | **NEW F4** `widgets/link.zig`; `href` goes to the `on:navigate` handler payload; external navigation is the app's call |
| `img src=local.png alt width height` | `image.image` w/image:144/153 with `Image{texture, uv, size}` (w/image:30); size read from the PNG at build time; app supplies `Texture` handles for `assets[]` (§3.2); `alt` → name; `alt=""` → `Participation{.semantics=false}`; `.svg` src → rasterised at build time through `draw/svg.zig` into an atlas texture (P2) |
| `img` with remote src | rejected `remote images are not fetched` |
| `svg` inline | P2: static SVG subset (draw/svg.zig) → icon texture; until then `inline <svg>: use <img src="x.svg">` |
| `canvas lcgf-draw="name"` | `ct_interop.canvas` interop:33 / `Frame.custom` frame.zig:179; data = component index (§3.4) |
| `progress value max` | `progress.progress` w/progress:77/92 (`value/max` folded when constant; field must be f32 0..1, else the generated scale) |
| `progress` with no value | `spinner.spinner` w/spinner:114/131 |
| `meter` | **NEW F12** (P2); until then `progress` with `Role.meter` |
| `output` | label with **F1** `Role.status` |
| `label for=id` / wrapping `<label>` | the control's caption (checkbox/switch/radio `text`) or `Spec.name` spec:43 / a11y `labelled_by` (a11y/tree.zig Semantics.labelled_by) |
| `fieldset` + `legend` | `card.ct.card(th, .group_box, title, children)` w/card:62; a fieldset of radios with one `name` → `radio` |

#### Form controls (§2.5 covers events)

| HTML | Runtime / comptime target | Bound field type (inferred) | Attributes |
|---|---|---|---|
| `button`, `input type=button/submit/reset` | `button` w/button:54 / `ct.button` 71; state styling → `recipe_comptime.button` recipe_comptime.zig:46 | caption field `str` or literal | `disabled="{f}"` → F3 + `inputAvailability` recipe_comptime.zig:148; `type=submit` → form submit |
| `input type=checkbox` | `checkbox` w/checkbox:106 / `ct.checkbox` 126 | `bool` (`Check` when `indeterminate` is used) | `checked` → default |
| `input type=checkbox switch` or `role=switch` | `switch` w/switch:70 / `ct.@"switch"` 97 | `bool` | |
| `button aria-pressed` | `toggle` w/toggle:63 / `ct.toggle` 82 | `bool` | |
| `input type=radio name=g` (group) | `radio` w/radio:108 / `ct.radio` 161, captions from the labels | `u32` (index) | `bind:selected` on the first radio or the fieldset |
| `input type=range` | `slider` w/slider:100 / `ct.slider` 130, `Range{lo,hi}` | `f32` | `min`/`max`/`step`/`value` |
| `<lcgf-range>` (two thumbs) | `range` w/range:137 / `ct.range` 168 | `[2]f32` | |
| `input type=number` | `number` w/number:175 / `ct.number` 197 | `number.Number` | `min`/`max`/`step` → `Range` |
| `input type=text/email/url/tel` | `textfield` w/textfield:374 / `ct.textfield` 413 | `textfield.Text(cap)` w/textfield:47, `cap` = `maxlength` or `lcgf-capacity`, default 256 | `placeholder` → hint |
| `input type=password` | textfield + **NEW F13** display masking (`text/layout/display.zig:29`) | `Text(cap)` | |
| `input type=search` | `search` w/search:132 / `ct.search` 169 | `Text(cap)` | |
| `textarea rows` | `textarea` w/textarea:245 / `ct.textarea` 304 | `Text(cap)` | |
| `input type=color` | `colorpicker` w/colorpicker:226 / `ct.colorpicker` 273 | `Hsva` | |
| `input type=date` | `datepicker.Datepicker(.id,.field)` w/datepicker:413 (overlay) | its date type | |
| `select` | `select.Select(th,.id,.field,.text,def)` w/select:65, `menu.Def` from the `<option>`s (`<optgroup>` → disabled header item) | `u32`/`u8` | |
| `select size=N` / `multiple` | `list` w/list:208 / `ct.list` 237; multiple → **NEW F14** (P2) | `u32` | |
| `input list=dl` + `datalist` | `combobox.Combobox` w/combobox:100 | `u32` + text | |
| `input type=hidden` | field only, no node | as `value` | |
| `input type=file/image`, `<form action=URL>` submission, `formaction` | rejected: `file selection needs a host file picker`; `submission to a URL: handle on:submit in your app` | | |

#### LCGF widgets without an HTML element (hyphenated custom elements)

`<lcgf-splitter>` → `splitter` w/splitter:33/162 · `<lcgf-tabs>`/`<lcgf-tab title>` → `tabs` w/tabs:35/178 · `<lcgf-toolbar>` → `toolbar.bar` w/toolbar:30/119 · `<lcgf-statusbar>` → w/statusbar:23/52 · `<lcgf-tree>` → w/tree:216/249 · `<lcgf-chip>` → w/chip:67/92 · `<lcgf-icon src>` → w/icon:33/58 · `<lcgf-spacer>` → w/spacer:22/43 · `<lcgf-menubar>` → `MenuBar` w/menubar:83 · `<lcgf-menu>` → `Menu` w/menu:94 · `<lcgf-contextmenu for>` → `ContextMenu` w/contextmenu:64 · `<lcgf-toast>` → `Toast` w/toast:57 · `<lcgf-region id>` → `ct_interop.region` interop:28.

ARIA role patterns on plain elements (`role=tablist`) are not inferred. Message: `role=tablist: use <lcgf-tabs>, whose keyboard behaviour is the widget's`.

#### Global attributes

| Attribute | Target |
|---|---|
| `id` | widget id (§2.0) and selector key |
| `class`, `style` | cascade (§2.3) |
| `class:name="{f}"` | **F3** variant bit |
| `hidden` (static) | node dropped; `hidden="{f}"` → `spec.when(.not_f)` via an inverted generated field, or F3 → `Participation.collapsed` types:391 |
| `inert` | `Participation{.hit=false}` types:385 plus focus removal (`focus.Scopes` interact/focus.zig:36) |
| `tabindex="0"` on a non-widget | F8 interactive box (`FocusStop` w/base:193) |
| `tabindex="-1"` | not in `focus_order` events.zig:257 |
| `tabindex` > 0 | rejected `positive tabindex is not supported; reorder the markup` |
| `autofocus` | initial `ui.focus` (base.zig:368 field) / runtime `focusScope` frame.zig:242 |
| `accesskey` | **NEW F15** shortcut row (P2) |
| `dir=rtl` | `Presentation.directions` row (base.zig:462) / `rtl.direction` rtl.zig:70 (runtime, F2 integration) |
| `lang` | a11y only |
| `aria-label` | `spec.named` spec:233 / `Spec.name` spec:43 |
| `aria-labelledby` | `Semantics.labelled_by` (a11y/tree.zig, Columns) |
| `aria-describedby` | **NEW F16** `described_by` column (P2) |
| `aria-hidden=true` | `Participation{.semantics=false}` |
| `aria-live=polite` | **F1** `Role.status` |
| `aria-current` | a11y `State.current` |
| `draggable`, `contenteditable`, `spellcheck`, `translate`, `enterkeyhint`, `inputmode`, `autocomplete` | warning, ignored (`contenteditable` → error: `rich editing is not supported; use <textarea>`) |
| `onclick` etc. (script attributes) | rejected: `script attributes are not run; write on:click="save"` |
| `data-*` | ignored; available to attribute selectors |

### 2.2 (b) CSS properties and values → `Style` / `TextStyle` / flex / grid / theme / tokens

All values are resolved at build time when constant. Lengths go to logical px: `px`; `pt`/`pc`/`in`/`cm`/`mm` through `units.resolve` (units.zig:75); `em`/`rem`/`%`-of-font from the statically known computed `font-size`. `vw`/`vh`/`vmin`/`cq*` are rejected in v1 (`viewport units need run-time evaluation (F3 env variant); use %`). `calc()`: constant folding at build time; a mix of % and px → rejected (`calc(100% - 20px) has no Size kind; use flex-grow`).

#### Box and layout

| CSS | Target | Rule / diagnostic |
|---|---|---|
| `display: block` (and `flex-direction: column`) | `spec.col` spec:90, `Style.dir=.y` types:400 | Block flow approximated as a column: no margin collapsing, no inline formatting (open question 6) |
| `display: flex` / `inline-flex` | `row`/`col` by `flex-direction` | |
| `flex-direction: row` / `column` | the builder | `row-reverse`/`column-reverse` → `reversed flex direction changes visual but not focus order; not supported` |
| `display: grid` | **F7** `Grids.grid` grid.zig:176 | |
| `display: none` (static) | node not emitted | under F3 → `Participation.collapsed` |
| `display: contents` | children hoisted to the parent | |
| `display: inline`, `inline-block` | inside a row: item; inside text: F11 | |
| `visibility: hidden` | `Participation.hidden` types:390 | |
| `width`, `height` | `Style.size[0/1]` types:401 | `Npx`→`.px` types:198; `N%`→`.pct(N/100)` 206; `auto`/`fit-content`/`max-content`→`.fit` 194; `min-content` → rejected (P2 via text/layout/intrinsic.zig) |
| `box-sizing: border-box` | native model | `content-box` with a px size → padding and border added at build time (exact) |
| `min-*`, `max-*` | `Style.min`/`max` types:402-403 | px only; `max-*: none` → inf; % → rejected |
| `aspect-ratio` | **F2** `Flex.Style.aspect` flex.zig:101 | |
| `padding`, `padding-*` | `Style.pad` types:405 | CSS top-right-bottom-left → LCGF left, top, right, bottom |
| `padding-inline-*`, `padding-block-*` | `pad` after the winning direction (`rtl.startEnd` rtl.zig:84 at run time for `dir=rtl`) | |
| `margin`, `margin-*` | **F2** `Flex.Style.margin` flex.zig:119 | never collapses (documented deviation) |
| `margin-*: auto` in a flex container | spacer `Size.grow(1)` inserted on that side (w/spacer:22; role none) | exact for the main axis |
| `gap`, `row-gap`, `column-gap` | `Style.gap` types:406 along `dir`; grid → `Grids.gaps` grid.zig:252; wrapping row → the same `gap` for lines (wrap.zig:94) | row-gap ≠ column-gap on a flex row → `one gap per flex container; equal row-gap and column-gap` |
| `flex-wrap: wrap` | **F2** `Flex.Style.wrap` flex.zig:122 | on a column → rejected (wrap.zig, rows only) |
| `justify-content: flex-start`/`start`/`left` / `center` / `flex-end`/`end`/`right` | `Style.main` types:408 | |
| `justify-content: space-between` / `around` / `evenly` | spacer nodes inserted at build time: between → weight 1 between items; around → ½ at the ends and 1 between; evenly → 1 everywhere | Rejected if an item grows: `space-* with a growing child has no effect in CSS; remove one`. Dynamic children → rejected in v1 |
| `align-items: start`/`center`/`end` | `Style.cross` types:410 | |
| `align-items: stretch` | each auto-sized child: `size[cross] = .fill` types:196 | |
| `align-items: baseline` | **F2** `Flex.Style.baseline` flex.zig:131 (rows) | |
| `align-self` | **F2** `Flex.Style.cross` flex.zig:114; `stretch` → `size[cross]=.fill` | |
| `align-content` | **F2** `Flex.Style.lines` flex.zig:125 | `stretch` → rejected |
| `flex-grow`, `flex: N` | `size[main] = .grow(N)` types:202 | `main` is the parent's axis |
| `flex-shrink` | `Style.shrink` types:412 + **F2** `Flex.Style.shrink` flex.zig:107 | |
| `flex-basis: Npx` | `size[main] = .px(N)` with grow and shrink kept | `flex-basis: %` → `.pct` |
| `order` | rejected | `order changes visual but not focus order; reorder the markup` |
| `grid-template-columns`/`-rows` | **F7** `Track.px` 42 / `fr` 48 / `fit` 46 / `minmax` 52 / `minmaxFr` 56 / `fitContent` 61; `repeat(n, …)` expanded at build time; `repeat(auto-fill/fit)` → `repeatAuto` grid.zig:308 at run time | |
| `grid-template-areas`, `grid-area`, named lines | **F7** `grid_names.template` 69 / `area` 61 / `item` 101 | |
| `grid-column`/`grid-row` (`a / b`, `span n`) | `Grids.item` 216, `span` 278 | |
| `grid-auto-flow` | `autoFlow` 258 (`AutoFlow` 66) | |
| `justify-items`/`align-items`/`-self` (grid) | `Grids.justify` 272 (`Justify` 71) | |
| `justify-content`/`align-content` (grid) | `Grids.distribute` 267 (`Distribution` 67, includes space-*) | |
| `subgrid` | `shareAxis` 291 | |
| `position: relative` + `top`/`left` | `Style.transform` translate types:439 | paint, hit and clip move; layout space stays, as in CSS |
| `position: absolute` + `top`/`left` | `Style.float` + `offset` types:414-415 | Containing block must be the parent; otherwise `absolute position relative to an ancestor other than the parent is not supported; make the parent position: relative` |
| `position: absolute` + `right`/`bottom`/`inset` | **NEW F17** anchors: `overlay.Anchors` overlay.zig:51, `anchor` 144 | |
| `position: fixed` | float at the root + F17 anchor to the viewport | |
| `position: sticky` + `top` | **F17** `scroll.stick` scroll.zig:125 | |
| `z-index` | **F17** `overlay.Layers` 184 / `order` 212 (floats only) | in-flow → rejected `z-index on in-flow boxes is not supported` |
| `overflow: hidden`/`clip` | `Style.clip` types:417 | |
| `overflow: auto`/`scroll` (one axis) | `scroll` w/scroll:54/168; offset is a private generated view-state field (not an app field) | |
| `overflow` on both axes | `scroll_area.open/close` w/scroll_area:57/130 (runtime frontend) | |
| `transform` (translate/scale/rotate/skew/matrix, any order) | folded to one affine `Style.transform` types:439 | 3D functions → rejected (P3 `draw/projective.zig`) |
| `transform-origin` | `Style.transform_origin` types:441 | % or keywords; px only when the box size is constant |
| `opacity` | `Style.opacity` types:435 | |
| `cursor` | `Style.cursor` types:397 (`Cursor` names map 1:1 types:336-371; `default`→arrow, `none`→hidden, `ns-resize`→resize_v, `ew-resize`→resize_h) | `url()` → rejected |
| `pointer-events: none` | `Participation{.hit=false}` types:385 | |
| `direction: rtl` | as `dir=rtl` (§2.1) | |
| `writing-mode` other than horizontal-tb | rejected (P3, layout/logical.zig:12) | |

#### Paint

| CSS | Target | Rule / diagnostic |
|---|---|---|
| `background-color`, `background: <color>` | `Style.fill` types:421 | |
| `linear-gradient(<angle>, c1, c2)` | `fill = c1`, `params = features.linear(c2, angle)` features.zig:39 | more than 2 stops, `repeating-*`, conic → P2 prepared paint (draw/decoration.zig, backgrounds.zig); until then `gradients with more than two stops need prepared paint (P2)` |
| `radial-gradient(circle at x y, c1, c2)` | `features.radial` features.zig:46 | |
| `background-image: url(local.png)` | `Style.texture` + `uv` types:426/443 through the asset table (§3.2) | `background-size`/`-repeat` → nine-slice only (`border-image` → `features.nineSlice` 64); else P2 |
| `border: Wpx solid C`, `border-width`, `border-color` (all sides equal) | `Style.border` / `border_color` types:423/422 | different sides → P2 decoration; until then `per-side borders need prepared paint (P2)` |
| `border-style: dashed`/`dotted` | `features.dashed` 73 / `dotted` 78 | combined with a gradient → `one quad feature per box: a dashed border and a gradient cannot share a box` |
| `border-radius` (1 value) | `Style.radius` types:424 | |
| `border-radius` (4 values) | `Style.radii` types:432 (TL, TR, BR, BL) | `a / b` elliptical → P2 |
| `box-shadow: x y blur [spread] color` (one, outer) | an extra preceding node: `fill = color`, `params = features.shadow(blur/2)` 55, `paint_reference` = the box, `paint_outset = spread + blur` types:447-449, offset by `transform` | `inset` or more than one → P2 decoration |
| `outline`, `outline-offset` | `Frame.outline` frame.zig:63 with `draw/outline.zig` `Outline` :9; comptime: an outline row with `paint_reference` | |
| `color` | `TextStyle.color` types:458 (inherited, resolved per text node) | |
| `accent-color` on `:root` | `Theme.accent` base.zig:103 | elsewhere → recipe `Names.accent` token |
| `color-scheme` / `prefers-color-scheme` | `theme.forAppearance` theme.zig:104 + `Conditions.dark` environment.zig:91 | |

#### Text

| CSS | Target | Rule / diagnostic |
|---|---|---|
| `font-size` | `TextStyle.px` types:457 | |
| `font-family`, `font-weight`, `font-style` | `TextStyle.font` types:459. The compiler builds a font table: each distinct (family, weight, style) gets a `Font` id; `@font-face { src: url(local.ttf) }` supplies the file; at run time `font.match.find` match.zig:54 | No matching face → `no @font-face for 'Inter' 700 italic; add one or remove the declaration` |
| `line-height`, `text-align`, `letter-spacing`, `word-spacing`, `white-space`, `text-overflow: ellipsis`, `-webkit-line-clamp`, `tab-size`, `font-feature-settings` | runtime: `Paragraph` stack.zig:38 (`alignment` 41, `line_height` 52, `letter_spacing` 50, `word_spacing` 51, `whitespace` 46, `ellipsis` 57, `max_lines` 55, `tab_size` 48, `features` 58) through `Frame.endText` frame.zig:438. Comptime: **NEW F12b** `Spec.paragraph` | Exception: `text-align` on a box whose only text is single-line → the box's `Style.cross` (exact, no paragraph) |
| `white-space: nowrap` / `normal` | `TextStyle.wrap` types:460 | |
| `text-transform` on literal text | applied at build time (Unicode case mapping in the tool) | on bound text → F13 display mapping |
| `text-decoration` | P2: text/layout/decorations.zig:59 | |
| `font-variant`, `hyphens`, `text-shadow`, `text-emphasis`, `ruby` | P3 (docs/styling/README.md lists the native operations) | |

#### Motion

| CSS | Target |
|---|---|
| `transition: <colour property> <t> <easing>` | P2: runtime `Frame.transition` / `setFillAnimated` frame.zig:314/327; comptime springs (base.zig `Springs`) |
| `@keyframes` + `animation` | P2: `Frame.sequence` frame.zig:296 (`anim/keyframes.zig`) |

`filter`, `backdrop-filter`, `mix-blend-mode`, `mask`, `clip-path` are rejected in v1 (P3, through the prepared-paint effects graph). `float`, `columns`, `shape-outside` are rejected (P3; `layout/special.zig` and `document.zig` need caller-measured inputs).

### 2.3 (c) Selectors and cascade: build time or run time

The whole cascade runs in `cascade.zig` at build time: origin (UA sheet, then author), `@layer` order, specificity, source order, `!important`, inline `style` last. The result per node is either one constant `Style`/`TextStyle` (the common case) or a constant **base** plus a **runtime rule set** keyed by state, variant or environment. The runtime rules lower onto `style.Rule` (resolve.zig:123), the existing resolver. No selector engine reaches the app.

| Selector / at-rule | Resolution | Target |
|---|---|---|
| type, `.class`, `#id`, `*`, `[attr]`, `[attr=v]`, `~=`, `^=`, `$=`, `*=`, `\|=`, `i`/`s` flags | build time, against the static DOM (attributes are static) | folded into the base style |
| descendant, `>`, `+`, `~` | build time; nodes inside `lcgf-each` match against their template position, so siblings of a template are the template's siblings | |
| `:root`, `:first-child`, `:last-child`, `:only-child`, `:nth-child(An+B [of S])`, `:nth-of-type`, `:empty`, `:not()`, `:is()`, `:where()`, `:has()` with static arguments | build time | Inside `lcgf-each` with a runtime count, `:nth-child` → rejected `:nth-child inside a repeated template depends on the run-time index`; P2 via F3 with an index field |
| `:hover`, `:active`, `:focus`, `:focus-visible`, `:focus-within`, `:checked`, `:indeterminate`, `:disabled`, `:enabled`, `:read-only`, `:required`, `:invalid`, `:open` (details/dialog), `[aria-expanded=true]`, `[aria-selected]`, `[aria-current]` on a widget | run time | `Rule.require`/`forbid` over `States` resolve.zig:39 (`hovered` 40, `held` 41, `focused` 42, `focus_visible` 43, `focus_within` 44, `disabled` 45, `selected` 46, `checked` 47, `indeterminate` 48, `expanded` 49, `read_only` 50, `invalid` 51, `required` 58, `current` 56). Comptime: `recipe_comptime.Config{ .recipe = … }` recipe_comptime.zig:27 for button/checkbox/switch/slider/textfield/radio/range/spinner; runtime: `theme_recipes` controls (recipe_controls.zig). Other widgets: **F3b** recipe adapters (P1) |
| The same state pseudo-classes on a non-widget box (`.card:hover`) | run time | **F8** interactive box + **F3** style variants indexed by its `Response` |
| `.class` toggled by `class:x="{f}"` | run time | **F3**: one `States.custom` bit (resolve.zig:59, 45 bits) per bound class, written from the field; rules `require.custom` |
| `::part(label\|icon\|indicator\|track\|fill\|thumb\|tick\|caret\|selection\|placeholder\|separator\|header\|row\|cell\|close)` | build time (constant) or recipe rule (stateful) | `Rule.part = Parts.*` resolve.zig:15-36 |
| `::placeholder`, `::selection`, `::marker` | aliases of `::part(placeholder)`, `::part(selection)`, list-marker text_style | |
| `::before`/`::after { content: "literal" }` | build time | a literal label prepended or appended (`spec.label` spec:104). `counter()`/`attr()` in content → P2 |
| `:visited`, `:target`, `:link` | rejected | `navigation state is not modelled` |
| `@media (min-/max-width, height, orientation, resolution, prefers-color-scheme, prefers-contrast, forced-colors, prefers-reduced-motion, prefers-reduced-transparency, pointer, hover)` | run time | `Rule.when = Conditions` environment.zig:85 (`width` 86, `height` 87, `scale` 88, `dark` 91, `high_contrast` 92, `forced_colors` 93, `reduced_motion` 94, `reduced_transparency` 95, `coarse_pointer` 97, `hover` 98). For layout properties on plain boxes → **F3** variants by an env bucket field the generated frame derives from `Environment.fromInput` environment.zig:28 |
| `@container (width…)` | run time | `Conditions.container_width` 89 + **F3**; container size = the box's last-frame rect (`Frame.lastRect` frame.zig:218) |
| `@supports` | build time | true exactly when the compiler maps the declaration |
| `@layer`, `@import` (local), `@font-face`, `@keyframes` (P2) | build time | |
| `@page`, `@namespace`, `@property`, `@scope`, `@counter-style` | rejected with the rule's name | |
| Custom properties `--x` and `var(--x, fallback)` | build-time substitution with cycle detection; a property redefined under state or `@media` → a recipe token (`style.token` resolve.zig:110, `tokens.Table`) | |
| `:root { --lcgf-<token>: … }` | theme: `--lcgf-text`, `-text-px`, `-panel`, `-control`, `-control-hot`, `-control-held`, `-accent`, `-radius`, `-pad`, `-gap` → `base.Theme` fields base.zig:88-109 through `theme.override` theme.zig:193; `--lcgf-color-*`/`-space-*`/`-radius-*`/`-text-*` → recipe `Names` recipe.zig:24-37 | |
| `!important` | honoured in the cascade | |
| `inherit`, `initial`, `unset`, `revert` | build time; `inherit` on inherited properties uses the static parent | |

The UA stylesheet (`tools/lcgf-gen/markup/ua.css`) is the LCGF theme rendered as CSS: headings, `p`, list indents, `body` fill = `Theme.panel`. It is not a browser's look (open question 7).

### 2.4 (d) Layout model

| CSS model | LCGF |
|---|---|
| Block flow | Column of children (`dir=.y`). Differences: no margin collapsing (F2 margins add); text and inline boxes are separate rows unless F11 inline runs are used. |
| Flexbox | `row`/`col` plus `Style.main`/`cross`/`gap`/`shrink`, `Size.grow` (fixed passes, layout.zig:1-12), plus F2 `Flex` columns run by `layout.runFlex` layout.zig:440 (`fitFlex` 69, `resolveFlex` 174, `placeFlex` 278, `wrap.wrap` wrap.zig:31). Shrink is one round (flex.zig:102-106); max-stopped growth gets two rounds with `regrow` (flex.zig:108-111). The compiler sets `regrow=true` whenever a growing sibling has a `max`. |
| Grid | F7: `grid.run` grid.zig:577; every track sized once (grid.zig:1-3). Spanning items and intrinsic min/max beyond `minmax`/`fitContent` → rejected. |
| Tables (static) | F7 grid plus roles; `border-collapse` → rejected in v1. |
| Positioning | relative → `transform`; absolute (parent CB) → `float` + `offset`; right/bottom/fixed/sticky/z-index → F17. |
| Overflow | `clip` / `scroll` widget / `scroll_area`. |
| Inline formatting | v1: one label per text run, wrap per label. F11 turns mixed phrasing into one paragraph over `text/layout/spans.zig` + `lines.zig`. |
| RTL | `rtl.mirror` rtl.zig:123 (runtime, F2); comptime `frameWithPresentation` base.zig:462. |

### 2.5 (e) Events and form controls

| Markup | Comptime source | Runtime source | Handler payload (Zig / C++ / Rust) |
|---|---|---|---|
| `on:click` on button, `a`, F8 box, menu or toolbar item | `Output.event` base.zig:436 tag = the widget | `Response.clicked` types:284 | none |
| `on:change` on any bound widget | the event after the widget wrote its field (base.zig:448-450) | `Response` plus a value compare | the new value (`f32` / `bool` / `u32` / `[]const u8`) |
| `on:input` (textfield, textarea, search, number) | the `Payload` of the widget's `Event` (events.zig:230) | the widget's `Response` | `[]const u8` / `std::string_view` / `&str` |
| `on:submit` on `form` (Enter in a single-line field of the form, or a submit button) | generated: the form owner collects the fields | same | a generated `FormData` struct of the form's named fields |
| `on:reset` | generated: restore defaults | same | none |
| `on:toggle` (details, dialog, popover) | field-change edge | same | `bool` |
| `on:remove` (lcgf-chip) | chip event | `chip` Response | none |
| `on:navigate` (`a href`) | F4 link event | F4 | `[]const u8` href |
| `on:focus` / `on:blur` | generated edge on `ui.focus` | `Response.focused` edges | none |
| `on:keydown:enter`, `:escape`, `:space`, arrows | **NEW F18** key filter over `Input` events (`keys.keyCount` w/keys:24) on the focused widget | same | none |
| Repeated (`lcgf-each`) item events | as above | as above | plus `index: u32` |
| `on:dblclick`, `contextmenu`, pointer move/drag, wheel | rejected in v1: `use an app component for pointer-level input` | | |

**Form owner (generated, no framework change):**
- Members: the controls with `name` under the `<form>`, or with `form=id`.
- Constraint validation runs in generated code and sets `States.invalid`/`required`, which CSS `:invalid` reads.
  - `required`, `minlength`/`maxlength` (bytes counted as code points), `min`/`max`/`step` (numbers and ranges).
  - `type=email`/`url`: a syntactic check with a fixed grammar.
  - `pattern` → rejected: `pattern needs a regex engine; validate in on:submit`.
- `disabled` fieldsets propagate availability (`events.Availability` events.zig:18).
- A canceled or invalid submit does not call `on:submit`; the generated `invalid_fields()` lists the failing fields.

### 2.6 The manifest and the coverage inventories

`tools/lcgf-gen/markup/manifest.zon` holds one row per (kind, name, applies_to). Each row records a status (`mapped` | `partial` | `rejected` | `planned`), a target symbol (file:line text) and the diagnostic. `lcgf-gen --mappings` prints it as TSV with the columns of `docs/plans/markup-coverage/*.tsv`. Replace `report.py:10`'s import of the deleted `mapping.destination` with a read of `lcgf-gen --mappings`. A Zig test makes every `rejected` row's message appear verbatim in `lower.zig`, and every `mapped` row have a fixture.

---

## 3. Binding contract (Zig, C++, Rust)

### 3.1 Principle

The **view state** is generated from the markup, and **application logic and data stay in the app**:

- Field types are inferred at build time from their binding sites. Any conflict is a markup diagnostic with both locations, for example `'level' is bound as bool by <input type=checkbox> at 4:3 and as f32 by <input type=range> at 9:3`. Type errors are therefore reported identically in all three languages, before any target compiler runs.

  | Binding site | Inferred type |
  |---|---|
  | checkbox | bool |
  | range | f32 |
  | text input | Text(cap) |
  | `{x}` | str |
  | `{x:.1}` | f32 |
  | `lcgf-each count` | u32 |
  | `lcgf-switch` | an enum of its cases |
  | `disabled="{x}"` | bool |

- Defaults come from HTML (`value`, `checked`, `selected`, the `<option selected>` index, `min` for numbers) and are otherwise zero or empty. Text fields start empty unless `lcgf-default="…"` is given.
- The app reads and writes state through the generated setters, which keep the dirty masks correct (signals.zig:321 `set`). Direct field writes are allowed between frames, as today (bindings.md:99-100).
- Field types in C++ and Rust are the types `tools/abi-gen` emits from the Zig types (e.g. `Text(cap)`, `Hsva`, `Number`), so the markup emitters never hand-write a layout.
- **Zig opt-in:** `<html lcgf-state="app.Mixer">` makes the page use an app struct instead. That gives access to `pub const derived`/`effects` (signals.zig:6-17). The check block verifies each field with `base.fieldError` (base.zig:147) or the widget's `bindError`, prefixed with the markup location. This works only on the `spec` and `runtime` frontends.

### 3.2 Generated surface per language (example `ui/mixer.html`)

```html
<html lcgf-page="mixer"><body><main>
  <h1>{title}</h1>
  <label><input type="checkbox" id="mute" bind:checked="muted"> Mute</label>
  <input type="range" id="volume" bind:value="volume" min="0" max="1" value="0.5" aria-label="Volume" on:change="volume_changed">
  <button id="save" on:click="save" disabled="{saving}">Save</button>
  <template lcgf-each="file in files"><button on:click="open">{file.name}</button></template>
  <x-meter level="{volume}"></x-meter>
</main></body></html>
```

**Zig** (`spec` frontend; module `mixer_ui` in the build cache):

```zig
// generated from ui/mixer.html by lcgf-gen <version>; inputs sha256 …; do not edit
const lcgf = @import("lcgf");
const app = @import("app");
pub const State = struct { title: []const u8 = "", muted: bool = false, volume: f32 = 0.5, saving: bool = false };
pub const spec = s.landmark(.main, .{ … }, .{ … }); // each call ends with  // mixer.html:L:C
pub const Ui = lcgf.widgets_base.ComptimeUi(State, spec, theme);
pub const Widget = Ui.Events.Widget;
pub const assets = [_]Asset{}; pub const fonts = [_]FontFace{};
pub fn Page(comptime H: type) type {
    comptime check(H); // @compileError("ui/mixer.html:4:71: handler 'volume_changed' must be pub fn (self: *H, ui: *Ui, value: f32) void")
    return struct {
        ui: Ui = .{}, region: lcgf.context.Context = undefined, …
        pub fn frame(p: *@This(), h: *H, in: *const lcgf.Input, files: anytype) Ui.Output { … }
    };
}
```

- Handlers are `pub fn name(h: *H, ui: *Ui, payload…) void` on the app's handler type `H`. The handler writes through `ui.signals.set(.field, v)`.
- `files` is any slice whose element has the fields the markup reads (`file.name: []const u8`). The check block uses `@hasField` with the markup location.
- Components: `app.components.@"x-meter"` (§3.4).

**C++** (`runtime` frontend, because of `lcgf-each`; header `mixer.lcgf.hpp` in `${CMAKE_CURRENT_BINARY_DIR}/lcgf_gen/`):

```cpp
namespace mixer {
struct State { std::string_view title{}; bool muted = false; float volume = 0.5f; bool saving = false; };
template <class F> concept File = requires(const F& f) { { f.name } -> std::convertible_to<std::string_view>; };
template <class H, class Ui> concept Handlers = requires(H& h, Ui& ui, float v, std::uint32_t i) {
    h.save(ui); h.volume_changed(ui, v); h.open(ui, i);
};
template <class H, class C> class Ui {
public:
    State state;
    void set_volume(float v);                       // marks dirty, as the table path's setters do
    template <std::ranges::random_access_range Files> requires File<std::ranges::range_value_t<Files>>
    const lcgf::DrawList& frame(lcgf::Context&, const lcgf::Input&, H& h, C& components, const Files& files);
};
}
```

- Each emitted statement is preceded by `#line N "ui/mixer.html"`, so `static_assert` and concept failures name the HTML (`--no-line-directives` turns it off).
- Widget calls are the abi-gen C++ wrappers of the `lcgf_<type>_<method>` exports (F5).
- On the `tables` frontend the same `Handlers` concept is used, and `frame` wraps the generated `mixer::Ui` from lcgf-gen (bindings.md:89-97) and dispatches `events()` to `h`.

**Rust** (`build.rs` → `$OUT_DIR/mixer.rs`, pulled in with `include!`):

```rust
pub mod mixer {
    pub struct State { pub title: &'static str, pub muted: bool, pub volume: f32, pub saving: bool }
    pub trait File { fn name(&self) -> &str; }
    pub trait Handlers { fn save(&mut self, ui: &mut Ui); fn volume_changed(&mut self, ui: &mut Ui, value: f32); fn open(&mut self, ui: &mut Ui, index: u32); }
    pub trait Components { fn x_meter(&mut self, f: &mut lcgf::runtime::Frame, level: f32); }
    pub struct Ui { pub state: State, /* … */ }
    impl Ui { pub fn frame<H: Handlers, C: Components, F: File>(&mut self, ctx: &mut lcgf::runtime::Context, input: &lcgf::Input, h: &mut H, c: &mut C, files: &[F]) -> lcgf::Frame<'_>; pub fn set_volume(&mut self, v: f32); }
}
```

Name mapping is identical in all three languages; the snake_case rule in §2.0 makes that possible. A missing handler becomes the target compiler's own error at the app's code:
- Zig: the check block's `@compileError` with the HTML location.
- C++: a concept failure at the `frame` call, `#line`'d to the HTML.
- Rust: `missing trait item 'volume_changed'` at the user's `impl Handlers`.

**Assets and fonts:**
- Each `<img>`/`background-image` file becomes `assets[k] = .{ .path, .size }`.
  - Zig embeds it through `assets/embed.zig` (`embed(@embedFile(...))`, the file's own doc comment).
  - C++ and Rust receive `std::span<const lcgf::Texture>` / `&[Texture]` at init. The host uploads the pixels; the paths are listed in `assets`.
- Fonts work the same way. `fonts[k]` has family, weight, style and path, and the host registers the faces in that order.

### 3.3 Event dispatch (same in every frontend)

- The generated `frame` builds and lays out, then dispatches at most one activation event (ComptimeUi's `Output.event`, base.zig:436) and the value changes of that frame, in tree order.
- Handlers run after the draw list is final, never mid-build. This is what makes the three languages' draw lists comparable byte for byte, and it matches the old plan's comptime semantics.
- A handler's writes mark the dirty masks, and the next `needsFrame` reflects them.

### 3.4 App-provided components (`<x-name …>`)

The tag (any name with a hyphen that is not `lcgf-*`) resolves to the app module's component:

| Kind (declared with `<link rel="lcgf-component" href="x-meter.html">` for markup components, or found in the app) | Zig | C++ | Rust |
|---|---|---|---|
| Markup component (`x-meter.html` with `<template lcgf-component props="level:f32">…<slot>…`) | Inlined at build time: a function returning `Spec` (spec.zig:5-9; flattening is identical to inline, spec.zig test "composition") | Inlined | Inlined |
| Code component, comptime | `pub fn @"x-meter"(comptime props: anytype) Spec`, or a namespace with `push`/`step` (`Spec.widget` spec:38; FocusStop pattern base.zig:193) | n/a | n/a |
| Code component, runtime | `pub fn @"x-meter"(f: *Frame, props: Props) void` | `void x_meter(lcgf::Frame&, Props)` on the `Components` type (concept) | `Components::x_meter(&mut self, f, …)` |
| Draw-only | `ct_interop.canvas` interop:33 (data = component index); the host draws | `.custom` ZON node (tables frontend) | same |

- Props: markup attributes, constant or `{field}`. Prop types are declared in the component file (`props="level:f32 label:str"`) or, for code components, by the app's signature; the target compiler checks the latter.
- Slots: named `<slot name>` / default; children are passed as a tuple (Zig) or inlined (markup components).

### 3.5 Static and dynamic regions

| Markup | spec (Zig) | tables/static (C++, Rust) | runtime |
|---|---|---|---|
| `lcgf-if` | `spec.when` spec:273 | `.row = .{ .when }` zon.zig:25 | `if` |
| `lcgf-if` + `lcgf-else`, `lcgf-switch` | `spec.choice` spec:286 | `.choice` zon.zig:27 | `if`/`switch` |
| `lcgf-each="n" lcgf-max="N"` | `spec.list` spec:245 (count type: generated `u32`; values above N show N) | `.list` zon.zig:26 | `for (0..@min(n,N))` |
| `lcgf-each="x in xs"` (per-item data) | an outermost runtime subtree: `interop.region(.r0, style)` + a generated runtime build function in a `Context` sized by `lcgf-nodes`/`lcgf-texts` (defaults 256/64), input through `regionInput` interop:78, merged with `compose` interop:104 | forces `runtime` | `for (xs, 0..) \|x, i\|` with `Id.from("open").with(i)` types:24 |
| virtual list | `spec.virtualList` spec:253 | `--static` only (zon.zig:29-32) | `vlist` w/vlist:141 |

The `spec` frontend falls back to `runtime` for the whole page when the root is runtime, or when G4 applies (an overlay beside other interactive widgets) until F10 lands. `--explain` prints each decision.

---

## 4. Ephemeral codegen and tooling

The shared guarantees:
- Output is deterministic: no timestamps, sorted iteration, a fixed number format.
- The header records `lcgf-gen` version + SHA-256 of all inputs.
- The tool writes a Makefile-style depfile listing every input: HTML, linked CSS, `@import`s, component files, assets (their headers are read), and font files.
- On failure the tool writes no output and exits non-zero after up to 20 diagnostics, each in GNU format `file:line:col: error: msg`, followed by the source line and a caret. That is the format Zig, gcc and clang use, so existing editor problem matchers jump to the HTML.

### 4.1 Zig (`build.zig`)

```zig
const lcgf_dep = b.dependency("lcgf", .{ .target = target, .optimize = optimize });
const ui = @import("lcgf").addMarkup(b, lcgf_dep, .{
    .html = b.path("ui/mixer.html"),
    .css = &.{b.path("ui/theme.css")},            // optional; <link> and <style> are read too
    .app = app_mod,                               // handlers, components, item types
    .emit = b.option([]const u8, "markup-emit", "Also copy the generated UI here"),
}) orelse return;                                  // null while the lazy Lexbor fetch runs
exe.root_module.addImport("mixer_ui", ui);
```

- `addMarkup` goes in lcgf's `build.zig` as `pub const addMarkup = @import("tools/lcgf-gen/markup/build.zig").addMarkup`, the same pattern as `141d297d:build.zig:6`.
  - It calls `lcgf_dep.builder.lazyDependency("lexbor")` and builds `lcgf-gen` for `b.graph.host`.
  - `addRunArtifact`, `addFileArg(html)`, `addArg("--lang"), addArg("zig")`, `addOutputFileArg("mixer_ui.zig")`, `addDepFileOutputArg("mixer_ui.d")` (Run.zig:535).
  - `createModule(.{ .root_source_file = out })` with imports `lcgf` and `app`.
  - Add `tools/lcgf-gen` to `build.zig.zon` `.paths`.
- **Dependency tracking:** the Run step caches on its file args and depfile entries. Editing the HTML or CSS reruns the tool; editing only handlers does not, because names are checked by the Zig compiler. Unchanged output keeps the downstream module cached.
- **Save during editing:** `zig build --watch` reruns on HTML save (watch includes Run inputs and depfile paths).
  - ZLS resolves `@import("mixer_ui")` through its build-runner module graph to the file in `.zig-cache/o/<hash>/`.
  - That file exists after the first `zig build`. With ZLS `enable_build_on_save`, saving the HTML regenerates it and ZLS picks up new names.
  - This must be verified in M2 on the pinned Zig and the ZLS built for it, and stated in the guide.
- **Errors in generated Zig:**
  - The check block gives messages that start with the HTML location (old probe: `bad1.zig:32:33: error: app.html:3:57: …`, `141d297d:docs/plans/markup.md:531-534`).
  - `validate.check` paths (`col > row[1] > slider[0]`) are mapped by a table in the header, and every builder call carries a `// file.html:L:C` comment.
- **Opt-in emit:**
  - `-Dmarkup-emit=src/gen` adds `b.addUpdateSourceFiles()` (Build.zig:941) `.addCopyFileToSource(out, "src/gen/mixer_ui.zig")`.
  - A vendored file is used through `.vendored = b.path("src/gen/mixer_ui.zig")`. `addMarkup` then still runs `lcgf-gen --check src/gen/mixer_ui.zig` as a build dependency, which fails with `src/gen/mixer_ui.zig is stale: regenerate with zig build -Dmarkup-emit=src/gen`. Vendored code therefore cannot go out of sync silently.
  - The standalone "export a project" command of the old plan (`141d297d:docs/plans/markup.md:588-611`) is dropped: emit plus a normal `build.zig` covers it.

### 4.2 Rust (`build.rs` + `OUT_DIR` + `include!`, recommended)

```rust
// build.rs
fn main() { lcgf_build::markup("ui/mixer.html").css("ui/theme.css").run(); }
// src/main.rs
mod ui { include!(concat!(env!("OUT_DIR"), "/mixer.rs")); }
```

- **NEW** crate `bindings/rust/lcgf-build`, about 80 lines.
  - It finds `lcgf-gen` (`$LCGF_GEN` or `$LCGF_PREFIX/bin`, as lcgf-macros does) and runs it with `--lang rust -o $OUT_DIR/mixer.rs --depfile $OUT_DIR/mixer.d`.
  - It prints `cargo::rerun-if-changed=<each depfile entry>` plus `cargo::rerun-if-env-changed=LCGF_GEN`/`LCGF_PREFIX`.
  - On tool failure it writes `mixer.rs` containing one `compile_error!("ui/mixer.html:4:71: …");` per diagnostic and exits 0. Errors then appear as ordinary rustc and rust-analyzer diagnostics at the `include!`, instead of as "build script failed" text.
  - Opt-in: `.emit_to("src/gen")` or `LCGF_MARKUP_EMIT=src/gen` copies the file; `.vendored("src/gen/mixer.rs")` runs `--check`.
- **rust-analyzer:** it runs build scripts and indexes `include!`d `OUT_DIR` files (`cargo.buildScripts.enable`, on by default), so completion and go-to-definition work on `ui::mixer::Handlers`. After an HTML edit, RA re-runs the build script on save of a tracked file, or on "Rebuild build scripts". Behaviour to be verified against the RA version in the bindings shell in M6. Generated code is readable through go-to-definition.
- **Proc-macro alternative** (`lcgf::include_html!("ui/mixer.html")`, extending lcgf-macros/src/lib.rs:59):
  - For: no `build.rs`.
  - Against: RA re-expands and spawns `lcgf-gen` on many edits; there is no `OUT_DIR` file to open; go-to-definition lands on the macro; tracking needs one `include_bytes!` per dependency (lib.rs:83-86).
  - Keep it for `.zon` (`include_ui!`), use `build.rs` for HTML.
- **Error mapping:**
  - Tool errors: `compile_error!` with HTML positions.
  - Type errors in app code land at the user's `impl` (traits), not in generated code.
  - Generated statements carry `// mixer.html:L:C` comments, since Rust has no `#line`.

### 4.3 C++ (CMake custom command into the binary dir)

```cmake
find_package(lcgf REQUIRED)
add_executable(app main.cpp)
lcgf_add_markup(app ui/mixer.html CSS ui/theme.css [FRONTEND runtime] [EMIT_DIR src/gen] [VENDORED src/gen/mixer.lcgf.hpp])
```

- **NEW** function in bindings/cpp/cmake/lcgfConfig.cmake, next to `lcgf_add_ui` (lcgfConfig.cmake:55):

```cmake
add_custom_command(OUTPUT "${_dir}/${_name}.lcgf.hpp"
  COMMAND "${LCGF_GEN}" "${_html}" ${_css_args} --lang cpp -o "${_dir}/${_name}.lcgf.hpp" --depfile "${_dir}/${_name}.d"
  DEPENDS "${_html}" "${LCGF_GEN}" DEPFILE "${_dir}/${_name}.d" VERBATIM)
```

  `DEPFILE` works with Ninja and Makefile generators on CMake ≥ 3.20, the package's minimum (lcgfConfig.cmake:12). Plus `target_sources`, `target_include_directories` and a `lcgf_markup_${_name}` custom target for fast regeneration.
- **clangd:** `CMAKE_EXPORT_COMPILE_COMMANDS=ON` gives the commands for the TUs that include the header. clangd infers the header's command from an including TU, and the include dir is in it. The header exists after the first build or after `cmake --build . -t lcgf_markup_mixer`; saving the HTML does not regenerate until the next build (`ninja` is fast because only the custom command and including TUs rerun).
- **Error mapping:**
  - Tool errors in GNU format.
  - `#line N "ui/mixer.html"` directives make `static_assert`, concept and template errors name the HTML. Debuggers also step through the HTML lines; `--no-line-directives` falls back to comments.
- **Opt-in:** `EMIT_DIR` adds a POST copy. `VENDORED` uses the given header and adds a `lcgf-gen --check` custom command as a `PRE_BUILD` dependency, which fails when stale.

---

## 5. Components and styles to add to LCGF (prioritised)

### P0: needed for the first useful subset

| Id | What | Tier, file | Design | Test |
|---|---|---|---|---|
| F1 | More `types.Role` values | 0, src/core/types.zig:304 | Add `link=8, separator=16, list=20, list_item=21, table=…, row, cell, column_header, row_header, dialog, status` with the byte values of `a11y.Role` (a11y/tree.zig:21-100, sequential), so `Style.role` reads back as the same a11y role | The existing "Role: one byte" test plus a byte-equality test against `a11y.Role` per tag |
| F2 | Flex side columns reachable from both front ends | 1, src/runtime/context.zig (`Limits.flex: bool`), frame.zig (`openFlex(id, style, flex)` / `Frame.flex(node, *const Flex.Style)`, and `arrangeWith` frame.zig:387 calling `layout.fitFlex`/`resolveFlex`/`placeFlex`/`wrap.wrap` when present); 1, src/comptime/spec.zig (`Spec.flex: ?Flex.Style`); 2, base.zig ComptimeUi carves `Flex` only when the spec has one | Zero cost when unused: no columns, the same sequence. The new Frame calls are listed in `api.zig`, so C++/Rust get them by reflection | Runtime: `.text` of a flex-free example unchanged (render-select method); Harness parity of a margin/wrap/baseline page in both front ends; `layout/check.zig` reference |
| F3 | Style variants selected by a state field | 1, spec.zig: `Spec.styles: ?[]const Style`, `Spec.style_field: ?[]const u8`; ComptimeUi push uses `styles[@field(state, f)]`; `Spec.shows` (spec.zig:51) includes `style_field`, so Signals masks dirty it; plan: `Row.style_field` (version bump) | One construct for `@media` buckets, `class:x`, container `:hover`/`:active`, `hidden="{f}"` | Signals mask test; a page switching variants matches its runtime twin (Harness) |
| F3b | Recipe adapters for the remaining widgets' state CSS | 2, theme/recipe_comptime.zig, recipe_controls.zig | Same `Config` for number, search, textarea, select, list, tabs, accordion, link | recipe_tests.zig parity pattern |
| F4 | Link widget | 2, new src/widgets/link.zig | Runtime `link(f, th, id, text) Response`; `ct.link`; role `link`; activation on click and Enter (`button.activated` w/button:45); style from `breadcrumb.linkStyle`/`linkFill` w/breadcrumb:61-70 | The five-commit widget recipe (base.zig:10-25): replay, Harness, golden |
| F5 | Every runtime widget function reachable from C++ and Rust | outside tiers: list each widget's runtime `pub fn` (§2.1 tables) in `src/abi/api.zig`; comptime reflection makes the `lcgf_<type>_<method>` wrappers (e.g. `lcgf_textfield_textfield`); `tools/abi-gen` emits their `lcgf.h` declarations and the C++/Rust types, including the widget state types (`Text(cap)` w/textfield:47, `table.State(n)`, `tree.State(n)`, `Number`, `Hsva`) | `anytype`/comptime-capacity parameters cannot be reflected: api.zig lists concrete instantiations (e.g. `Text(64)`, `Text(256)`, `Text(1024)`), and the compiler rounds `maxlength` up to the nearest listed capacity or rejects it (`maxlength 5000 exceeds the largest exported text capacity 1024`). A theme argument crosses as the reflected `Theme` type, replacing the runtime context's single `r.theme` | bindings/check: the six-scenes method extended with a widget scene in Zig, C++ and Rust, `cmp` identical |
| F6 | ZON IR additions Z3 (and the name half of Z4) | outside tiers, src/abi/zon.zig, plan.zig (text-style column, version 2), lcgf-gen emitters | Z4's style fields come free once `ZStyle` is derived from `Style`; F6 adds the `text_style` per label and `name` per node | The B2 test (zon.zig vs comptime words) over new testdata specs |

### P1

| Id | What | Tier, file | Design |
|---|---|---|---|
| F7 | Grid reachable from the front ends | 1, frame.zig / context.zig (`Limits.grids`), spec.zig `Spec.grid: ?GridDecl` (tracks, areas, gaps, flow) and `Spec.cell` | `grid.run` grid.zig:577 in place of the flex/plain sequence when grids exist; zero cost otherwise; Frame calls exported through api.zig |
| F8 | Interactive box | 2, base.zig: `ct.pressable(id, style, children)` = `FocusStop`-like `Spec.widget` (base.zig:193) with `ctResponse` (181) feeding F3; runtime: `Frame.interact` frame.zig:196 | Click and focus on any container (`on:click` on a div, `tabindex=0`, `:hover` on a box) |
| F10 | Overlays inside ComptimeUi (closes G4) | 2, base.zig + popover.zig | Allow `Popover`/`Dialog`/`Select`/`Menu`/`Tooltip` types as `Spec.widget` nodes whose `push` writes a floating layer under the root (`overlay.order` overlay.zig:212); ComptimePage's `part`/`step` hooks become that widget's `push`/`step` |
| F11 | Inline runs | 1, spec.zig `Spec.runs: ?[]const Run` (text + TextStyle + optional link id); runtime `Frame.paragraph` over text/layout/spans.zig + lines.zig | Mixed phrasing in `p`/`li`/`label`; hit ranges for links inside text |
| F12b | Paragraph style in ComptimeUi | 2, base.zig: `Spec.paragraph: ?stack.Paragraph`; an optional `TextStack` when any label has one | `line-height`, multi-line `text-align`, `letter-spacing`, ellipsis, line clamp |
| F17 | Anchors, sticky, layers in the front ends | 1, frame.zig/context.zig side tables for `overlay.Anchors` (overlay.zig:51), `scroll.Sticky` (scroll.zig:125), `overlay.Layers` (184) | right/bottom/fixed/sticky/z-index |
| F18 | Key filters for handlers | generated code over `keys.keyCount` w/keys:24 | No framework change |

### P2 / P3

- F12 `meter` widget (role meter; thresholds as variants).
- F13 password/`text-transform` display mapping in textfield (text/layout/display.zig:29).
- F14 multiple-select list.
- F15 `accesskey` shortcuts (static `shortcut` table, bindings.md:250).
- F16 `described_by` column in a11y Semantics.
- Prepared paint for multi-stop gradients, multiple or inset shadows and per-side borders (draw/decoration.zig, backgrounds.zig, via `prepared.row`/`bind`, docs/styling/README.md:73).
- Transitions/keyframes.
- `@container` per node.
- `text-decoration`.
- SVG `<img>`.
- (P3) 3D transforms, filters, floats, multicol, writing modes.

---

## 6. Milestones and work packages

Each WP is one or more commits, every commit passes `nix develop -c zig build test fmt` (CLAUDE.md), and WPs are independently verifiable. Framework WPs (F*) can run in parallel with compiler WPs once M1 lands. F5 depends on the C ABI work (`api.zig`, `tools/abi-gen`) landing first.

| M | WP | Done when (tests) |
|---|---|---|
| **M0 Inventory** | 0.1 `manifest.zon` + `--mappings`; replace report.py:10 | `report.py` runs again; every manifest row joins a row of `docs/plans/markup-coverage/*.tsv` |
| | 0.2 Fixture set `tools/lcgf-gen/markup/testdata/<name>/{page.html, page.css, twin.zig, twin.cpp, twin.rs, expected.zon}` | 12 pages: hello, mixer, counter (from examples/counter), form (from examples/form), toolbar, settings, todo (each, if, choice), table, dialog, landmarks, components, grid |
| **M1 Parser** | 1.1 Lexbor lazy dependency + `zig build lcgf-gen` for the host (re-add the DEPENDENCIES.md row) | Builds offline from `zig-pkg/`; `ci/run.sh` job `markup-parse` |
| | 1.2 `lexbor.zig` + `html.zig` (positions through the mutation hook, port of `141d297d:tools/decomposer/html.c`) | Node-table dumps for the fixtures match `.expected`; a line/col test on every element and attribute |
| | 1.3 `css.zig` (rules, selectors, declarations with offsets) | Token and offset fixtures (escaped identifiers, bad URL recovery, EOF in a block), per LANG-01 in docs/plans/markup-coverage/css-language.md |
| | 1.4 Diagnostics: GNU format, caret, up to 20 per run | One `testdata/errors/*.html` per message in §2; output compared exactly |
| **M2 Zig vertical slice** | 2.1 IR + `lower.zig` for structure, landmarks, headings, `p`, `span`, `button`, literal and `{}` text | The generated `Spec` equals `twin.zig`'s `Spec` at comptime (`expectEqualDeep`, as spec.zig tests do) |
| | 2.2 `emit_zig` + `addMarkup` + depfile + emit/vendored `--check` | An example `examples/markup/` builds from HTML; `zig build --summary all`: touching only handlers → the tool cached; editing CSS → reran; stale vendored file → build fails with the message |
| | 2.3 Check block + handler dispatch | compile-fail cases (missing handler, wrong arity, wrong field type, derived two-way binding) through `ci/jobs/ct-compile-fail.sh`, each message beginning with `file.html:L:C` |
| **M3 Cascade** | 3.1 Selectors and specificity (build-time set of §2.3) | One fixture per selector form giving the matched node set |
| | 3.2 Values: colours (svg.zig:342, color_math), lengths (units.zig), transforms folded, `calc()` folding | Value golden tests per grammar, plus an invalid case each |
| | 3.3 Property lowering of §2.2 (no F* dependency) | One fixture per property row giving the exact `Style`/`TextStyle`; each rejected row's message |
| | 3.4 Custom properties, theme tokens, UA sheet | `:root` tokens give `theme.override` (theme.zig:193); a cycle with fallback |
| **M4 Widgets and forms (Zig)** | 4.1 Every form-control row of §2.1 via `ct.*` | For each control a fixture page plus a replay (`testdata/*.replay`, as src/comptime/testdata/mixer.replay) through `Harness` (base.zig:872) against the twin: identical draw lists |
| | 4.2 Form owner, validation, `on:submit`/`reset` | Event-trace fixtures: invalid submit does not call the handler; disabled fieldset |
| | 4.3 Overlay elements via `ComptimePage` (pre-F10) and the whole-page runtime fallback | `--explain` lines; dialog/select fixtures pass Harness |
| **M5 Framework P0** | F1, F2, F3, F4 (each its own lane) | Tests in §5; render-select-style `.text` unchanged for existing examples (F2/F3 zero cost); census-src unchanged branch counts (`ci/run.sh census-src`) |
| **M6 C++/Rust via tables** | 6.1 `to_zon.zig` + F6 | `lcgf-gen page.html --lang zon` equals `expected.zon`; B2 word equality |
| | 6.2 `lcgf_add_markup` + `lcgf-build` crate | CMake and cargo consumers build; edit-HTML-rebuild check; `compile_error!` path for tool failure |
| | 6.3 Add markup fixtures to `bindings/check/run.sh` (the loop at :23) | `cmp`: Zig spec frontend vs Zig through the seam vs C++ vs Rust, byte-identical draw lists and events over `inputs.txt` |
| **M7 Runtime frontend** | 7.1 F5: widget functions in `api.zig`, wrappers and abi-gen output | The bindings gate: a widget scene identical in Zig, C++ and Rust |
| | 7.2 `emit_*` runtime for the three languages | Each fixture: Zig runtime vs Zig spec frontend (Harness) vs C++ vs Rust, byte-identical; `#line` errors name the HTML (C++ compile-fail case) |
| **M8 Dynamic and components** | 8.1 `lcgf-if/else/switch/each(max)` | Draw lists stepping count/condition changes equal the runtime twin |
| | 8.2 `each in` runtime regions (interop) | The files example equals an all-runtime page |
| | 8.3 Components: markup, Zig fn, `Spec.widget`, runtime (C++/Rust traits), draw-only | A page with a component equals the page written inline (Spec equality); Rust missing-method error is at the user's `impl` |
| **M9 Dynamic CSS** | 9.1 State pseudo-classes → recipes (+ F3b) | recipe_tests.zig pattern: real input changes state; draw parity across front ends |
| | 9.2 `@media`/`class:x`/container `:hover` → F3 | Two viewports, identical frames to a hand twin using `choice`/variants |
| **M10 Cost** | 10.1 `ci/jobs/markup-zero-cost.sh`: `.text` size + SHA-256 of generated vs `twin.*` (method `ci/jobs/render-select.sh`, probe `141d297d:docs/research/markup/zero-cost/run.sh`) for Zig spec, C++ (clang -O2) and Rust runtime | Identical for every fixture |
| | 10.2 Compile-time gate rows (bench/gates/gates.py): tool time ≤ 10% of the size's budget; generated `build-obj` within the hand page's budget | Recorded with workload and host, as CLAUDE.md requires |
| **M11 Framework P1** | F7, F8, F10, F11, F12b, F17, F18, then their mapping rows switch from `rejected` to `mapped` | Per-feature fixtures plus the bindings gate |
| **M12 Docs** | `docs/guide/markup.md` compiled by `zig build docs` (as docs/guide/*.zig) | `ci/run.sh docs` |

---

## 7. Open questions for the user

1. **Authoring syntax.** This plan uses Svelte-style `bind:value`/`on:click` and `<template lcgf-if/each>`. The alternative is `data-lcgf-*`, which stays valid HTML and previews in a browser but is wordier. Should the HTML also preview sensibly in a browser?
2. **Lexbor.** Do you re-approve Lexbor 3.0.1 as a lazy, host-only dependency (its DEPENDENCIES.md row was removed in 7040bdcc)? Should `zig build abi` ship `lcgf-gen` with it linked in?
3. **State ownership.** This plan generates the view state from the markup (types inferred, defaults from HTML) in all three languages, and lets Zig opt in to an app `State` for derived fields and effects. Do you want app-declared state in C++ and Rust as well? That would need a schema declaration in markup for the tables frontend.
4. **Frontend for C++/Rust.** The full widget set reaches C++ and Rust only through the runtime path (one call per widget to the api.zig-exported wrappers). Is that acceptable, or must the tables or static (zero-call) path cover more widgets? That would mean porting each widget's `push`/`step` to `plan` and `ct.zig`, which is much larger. Related: which `Text(cap)` capacities should api.zig export?
5. **Strictness.** Should unsupported properties and values be errors (this plan, as the Decomposer was) or warnings with a `--strict` switch?
6. **CSS deviations to accept or reject:** no margin collapsing, block flow as a column, `space-*` emulated with spacer nodes, one gap per flex container.
7. **Default look.** Should unstyled HTML look like the LCGF theme (this plan's UA sheet) or like a browser's default styles?
8. **C++ `#line` directives.** They map errors and debugger stepping to the HTML. On by default?
9. **Rust.** Is `build.rs` plus the new `lcgf-build` crate acceptable, or do you want the proc-macro so no build script is needed?
10. **Scope of the first release.** Is the P0 set plus M0 to M10 the target, with grid, overlays-in-comptime, inline runs and paragraphs (P1) following? Or should any P1 item, most likely F7 grid or F11 inline text, move into the first release?

---

## 8. Decisions (2026-11-26, recommended defaults)

| Q | Decision |
|---|---|
| 1 Syntax | `bind:`/`on:` attributes and `<template lcgf-if/each/switch>`. Browser preview is not a goal. |
| 2 Lexbor | Re-approved: Lexbor 3.0.1, lazy, host-only. `zig build abi` ships `lcgf-gen` with it linked. |
| 3 State | View state generated from the markup in all three languages; Zig may opt in to an app `State`. App-declared state for C++/Rust later. |
| 4 C++/Rust frontend | The runtime path (one call per widget) is acceptable; tables/static keep the reference widgets. Export `Text(64)`, `Text(256)`, `Text(1024)`. |
| 5 Strictness | Unsupported properties and values are errors. |
| 6 CSS deviations | Accepted: no margin collapsing, block flow as a column, `space-*` with spacer nodes, one gap per flex container. |
| 7 Default look | The LCGF theme (UA sheet), not a browser's. |
| 8 `#line` | On by default. |
| 9 Rust | `build.rs` plus `lcgf-build`. |
| 10 First release | P0 plus M0–M10. P1 (grid, overlays in comptime, inline runs, paragraphs) follows. |

**Who builds what.** The compiler itself (`tools/lcgf-gen/markup/`, M0–M4, M8–M10, then M6/M7) is built in its own worktree. The engine additions (F1–F4, F6) and the C ABI work (`api.zig`, `tools/abi-gen`, which F5 and M6/M7 need) are built on `main`; the compiler branch rebases onto them.
