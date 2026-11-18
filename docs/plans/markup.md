# Markup front end: plan

The proposed host tool compiles HTML structure and CSS styling to ordinary Zig that calls
LCGF’s existing widgets. Application code owns typed state, handlers and effects. The same
generated module serves the normal build and the inspectable standalone project export.
The [comptime guide](../guide/comptime.md) and [API index](../api/API.md) describe the
current primitives. The [post-release TODO](../../TODO.md) tracks this design.

The original design in `9f346e5` was reconciled with `main` at `eebd5ab`. The package
and module name is now `lcgf`. Bounded lists, conditional and alternative layouts, signals,
and mixed front ends are on main. Sections 2 and 5 describe the remaining work to use
them from the widget-page generator. Section 7 compares a hand-written page with a
manually authored example of the proposed output.

**Decisions before implementation**

1. Approve lexbor 3.0.1 as a lazy host-tool dependency. The target application imports
   LCGF and its own handlers. Section 4 records the parser evidence.
2. Choose which widget API additions to ship, particularly literal labels, per-node styling
   and multiple custom rows. Each gap has a concrete fallback or diagnostic in section 2.

## 1. Grammar

A markup file is an HTML fragment read by an HTML5 *tokenizer*, not an HTML5 tree builder
(section 4 explains why). The tool builds its own tree from the tokens, so any tag name is
allowed and no tag is moved or dropped. Names are lowercased by the tokenizer, as in HTML.

```html
<ui state="App" theme="dark">
  <style> .bar { gap: 4px } </style>
  <col class="page">
    <label>{title}</label>
    <row class="bar">
      <button id="dec" on:click="counter.dec">{dec_text}</button>
      <button id="inc" on:click="counter.inc">{inc_text}</button>
      <slider id="volume" bind="volume" min="0" max="1" aria-label="Volume"/>
    </row>
    <if test="advanced"> <checkbox id="wire" bind="wireframe">{wire_text}</checkbox> </if>
    <each count="n_rows" max="16"> <label>{row_text}</label> </each>
    <each of="files" as="file"> <label>{file.name}</label> </each>
    <channel-row mute="solo" muted="soloed" level="gain"/>
  </col>
</ui>
```

### What is accepted

| Form | Meaning |
|---|---|
| `<ui state="T" theme="dark\|light" systems="ns">` | The root, once per file. `state` names the state struct in the handlers module (default `State`). `theme` picks `lcgf.theme.dark` or `light` (theme.zig:98-100). `systems` names the namespace that runs effects (default `systems`, section 5). |
| `<col>`, `<row>`, the 42 widget elements, the HTML aliases | Elements, section 2. A leaf may self-close (`<slider .../>`). A known leaf may also omit its close tag. |
| `<style>…</style>` | CSS, read before the file's `.css` (section 3). Allowed only directly under `<ui>`. |
| Text `{name}` | A binding to the state field `name`: a label's text, or a widget's caption. |
| Text `{item.name}` inside `<each of>` | A per-item field. It forces a runtime region (section 5). |
| `id="x"` | The widget id: an enum literal and a tag of `Events(spec).Widget` (spec.zig:21-23). Required on interactive elements. |
| `bind="field"` | The state field a widget shows and writes (`Spec.bind`, spec.zig:24-25). |
| `on:<event>="ns.fn"` | A handler: a declaration path in the handlers module (section 5). |
| `aria-label="…"` | The accessible name, `spec.named` (spec.zig:78). |
| `role="…"` | `Style.role` (types.zig:304): `group`, `label`, `button`, `checkbox`, `slider`, `image`, `text_input`. |
| `class`, `style="…"` | CSS classes, and inline declarations at the highest specificity. |
| Widget parameters as attributes | `min`, `max`, `step`, `rows`, `axis`, `orientation`, `variant`, … (section 2). |
| `<if test="flag">…</if>` | Live only while the bool field `flag` is true: `spec.when` (section 5). |
| `<if test="flag">…<else>…</else></if>` | With two arms, emit `spec.choice(.flag, style, .{ false_arm, true_arm })`. Each arm is one subtree. |
| `<each count="n" max="N">…</each>` | `N` copies, the first `n` of them live: `spec.list` (section 5). |
| `<each of="items" as="item">…</each>` | One copy per element of a slice field: a runtime region (section 5). |
| `<import src="channel-row.html"/>` | Makes a component available. A tag with a hyphen is a component (the custom-element rule). |
| `<component params="mute muted level">…<slot/>…</component>` | The root of a component file. Section 1.1. |
| `<!-- … -->` | Ignored. |

### 1.1 Components and slots

A component is a function that returns a `Spec`. The repository already uses this pattern
(spec.zig:5-9, comptime.md "Components are functions"). `channel-row.html` holding
`<component params="mute muted level">` becomes:

```zig
fn @"channel-row"(comptime mute: @EnumLiteral(), comptime muted: @EnumLiteral(), comptime level: @EnumLiteral(), comptime slot: anytype) s.Spec
```

A `{param}` or `bind="param"` inside the component refers to the parameter. `<slot/>` is
replaced by the caller's children, which are passed as a tuple. Its nodes flatten exactly like
the same nodes written inline (spec.zig:264, test "composition").

### What is rejected, and the message for each

Every message has the form `file:line:col: error: …`, followed by the source line and a caret.
All errors in a file are reported in one run, up to 20.

| Input | Message |
|---|---|
| `<script>` | `no JavaScript: behaviour is Zig. Name a handler with on:click="ns.fn"` |
| An unknown tag without a hyphen | `unknown element <foo>; elements are col, row, label, the widgets (docs/plans/markup.md section 2) and their HTML aliases` |
| A hyphenated tag that was never imported | `no component <channel-row>; add <import src="channel-row.html"/>` |
| A close tag that does not match | `</row> closes <col> opened at 3:5` |
| End of file with tags still open | `<col> opened here is never closed` |
| Text outside `{}` that is not whitespace | `literal text needs a state field until gap G1 is closed: write {name} and give the state a field name: []const u8 = "…"` |
| `{a + b}`, `{f(x)}`, `{a ? b : c}` | `only names go in {}: declare a derived field (State.derived) and bind it` |
| `{` with no matching `}`, or `<` inside `{}` | `unclosed {` |
| `on:click` with no `id` | `<button> handles on:click, so it needs an id` |
| An interactive element with no caption and no `aria-label` | `<slider id="volume"> needs an accessible name: aria-label="…"` |
| `on:hover`, `on:keydown`, or any event the widget does not report | `<button> has no event 'hover'; it reports click` |
| A JS-style handler, `on:click="count++"` | `a handler is a declaration path such as counter.inc` |
| A misplaced or repeated `<else>` | `else must be the single final child of an if` |
| `<if test="a > 3">` or a non-identifier test | `test names one bool field` |
| `<each>` with neither `count` nor `of`, or with both | `<each> takes count="field" max="N", or of="field" as="name"` |
| `<each count>` with no `max` | `<each count="n"> needs max: the rows are reserved at compile time` |
| A `<style>` that is not directly under `<ui>` | `<style> goes directly under <ui>; styles are flattened at build time and are not scoped` |
| A second `<ui>`, or anything outside it | `one <ui> per file` |
| `id` given twice in one file | `duplicate id 'x', first used at 3:9` (the same rule as validate.zig:75) |

## 2. Element mapping

The builder names refer to the public API at `eebd5ab`: `lcgf.spec`, and `lcgf.widgets_<name>.ct`,
whose builders all return `Spec` and take the page theme `th` first. There are 42 widget
modules (`zig build docs` → `zig-out/docs/API.md` lists them), plus three that are not widgets:
`base.zig` (Theme, `ComptimeUi`), `check.zig` (test helpers) and `keys.zig` (key counting). The tables cover each widget module once, including `label`.

Some attribute values are the names of state fields. They are written without braces and
become enum literals; the type each field needs is the type the builder checks. Other values
are literals, parsed at build time.

### Containers and text

| Element | HTML aliases | Builder | Attributes |
|---|---|---|---|
| `col` | `div` (unless its computed `flex-direction` is `row`), `section`, `main`, `header`, `footer`, `nav`, `aside`, `form` | `spec.col(style, children)` spec.zig:49 (sets `dir = .y`) | CSS only |
| `row` | `div` whose computed `flex-direction` is `row` | `spec.row(style, children)` spec.zig:56 | CSS only |
| `label` | `span`, `p`, `h1`-`h6`, bare `{field}` text | `widgets_label.ct.label(th, .field)` label.zig:59 | content `{field}` (a `[]const u8` field) |

### Widgets with a `ct` builder (32)

| Element | HTML aliases | Builder (file:line) | Attributes → parameters | Field types |
|---|---|---|---|---|
| `button` | `button` | `widgets_button.ct.button(th, .id, .text)` button.zig:71 | `id`, content `{text}`; `on:click` | text `[]const u8` |
| `checkbox` | `input type=checkbox` | `widgets_checkbox.ct.checkbox(th, .id, .bind, .text)` checkbox.zig:126 | `id`, `bind`, content | `bool` or `Check` |
| `switch` | `input type=checkbox role=switch` | `widgets_switch.ct.@"switch"(th, .id, .bind, .text)` switch.zig:97 | `id`, `bind`, content | `bool` |
| `toggle` | `button aria-pressed` | `widgets_toggle.ct.toggle(th, .id, .bind, .text)` toggle.zig:82 | `id`, `bind`, content | `bool` |
| `radio` | `fieldset` of `input type=radio` | `widgets_radio.ct.radio(th, .id, .bind, .{captions})` radio.zig:161 | `id`, `bind`; children `<option>{field}</option>` | `u32`, captions `[]const u8` |
| `slider` | `input type=range` | `widgets_slider.ct.slider(th, .id, .bind, .{ .lo, .hi })` slider.zig:130 | `id`, `bind`, `min`, `max` | `f32` |
| `range` | (none) | `widgets_range.ct.range(th, .id, .bind, .{ .lo, .hi })` range.zig:168 | `id`, `bind`, `min`, `max` | `[2]f32` |
| `number` | `input type=number` | `widgets_number.ct.number(th, .id, .bind, .{ .lo, .hi, .step })` number.zig:197 | `id`, `bind`, `min`, `max`, `step`; `on:change` | `Number` |
| `textfield` | `input type=text` | `widgets_textfield.ct.textfield(th, .id, .bind, .hint)` textfield.zig:413 | `id`, `bind`, `placeholder="{hint}"`; `on:change` | `Text(cap)`, hint `[]const u8` |
| `search` | `input type=search` | `widgets_search.ct.search(th, .id, .bind, .hint)` search.zig:169 | as textfield | as textfield |
| `textarea` | `textarea` | `widgets_textarea.ct.textarea(th, .id, .bind, rows, .hint)` textarea.zig:304 | `id`, `bind`, `rows`, `placeholder`; `on:change` | `Text(cap)` |
| `chip` | (none) | `widgets_chip.ct.chip(th, .id, .text, .remove or null)` chip.zig:92 | `id`, content, `remove="{field}"`; `on:remove` | `[]const u8` |
| `list` | `select size=N` | `widgets_list.ct.list(th, .id, .selected, .{items})` list.zig:231 | `id`, `bind`; children `<option>{field}</option>` | `u32`, items `[]const u8` |
| `vlist` | (none) | `widgets_vlist.ct.vlist(th, .id, .items, .selected, .scroll, visible)` vlist.zig:174 | `id`, `items`, `bind`, `scroll`, `visible` | `[]const []const u8`, `u32`, `f32` |
| `table` | (none; see G5) | `widgets_table.ct.table(th, .id, .state, .headers, .cells, cols, rows)` table.zig:355 | `id`, `bind`, `headers`, `cells`, `cols`, `rows` | `State(cols)`, string fields |
| `tree` | (none) | `widgets_tree.ct.tree(th, .id, .state, .labels, .depths, n)` tree.zig:249 | `id`, `bind`, `labels`, `depths`, `rows` | `State(n)`, `[]const []const u8`, `[]const u8` |
| `progress` | `progress` | `widgets_progress.ct.progress(th, .value)` progress.zig:92 | `value` | `f32` |
| `spinner` | (none) | `widgets_spinner.ct.spinner(th, .busy)` spinner.zig:131 | `busy` | `bool` |
| `colorpicker` | `input type=color` | `widgets_colorpicker.ct.colorpicker(th, .id, .color)` colorpicker.zig:273 | `id`, `bind` | `Hsva` |
| `card` | `fieldset` with `legend` | `widgets_card.ct.card(th, variant, .title, children)` card.zig:62 | `variant="card\|group_box"`, `title` | `[]const u8` |
| `separator` | `hr` | `widgets_separator.ct.separator(th, orientation)` separator.zig:52 | `orientation="horizontal\|vertical"` | none |
| `spacer` | (none) | `widgets_spacer.ct.spacer(axis)` spacer.zig:43 | `axis="x\|y"` | none |
| `accordion` | `details` + `summary` | `widgets_accordion.ct.section(th, .id, .expanded, .title, children)` accordion.zig:119 | `id`, `bind` (expanded), `title` | `bool`, `[]const u8` |
| `tabs` | (none) | `widgets_tabs.ct.tabs(th, .selected, .{ .{ id, title, children }, … })` tabs.zig:178 | `bind`; children `<tab id title>…</tab>` | `u32`, `[]const u8` |
| `splitter` | (none) | `widgets_splitter.ct.splitter(th, .id, axis, .split, first, second)` splitter.zig:162 | `id`, `axis`, `bind`; two `<pane>` children | `f32` |
| `scroll` | (none; see section 3, `overflow`) | `widgets_scroll.ct.scroll(th, .id, .offset, children)` scroll.zig:168 | `id`, `bind` | `f32` |
| `toolbar` | (none) | `widgets_toolbar.ct.toolbar(th, .current, .activated, .{ .{ id, title }, … })` toolbar.zig:119 | `current`, `activated`; children `<item id title/>` | `u32` |
| `statusbar` | (none) | `widgets_statusbar.ct.statusbar(th, .{texts})` statusbar.zig:52 | children `{field}` | `[]const u8` |
| `breadcrumb` | `nav aria-label=breadcrumb` | `widgets_breadcrumb.ct.trail(th, .activated, .{ .{ id, title }, … }, .current)` breadcrumb.zig:132 | `activated`, `current`; children `<link id title/>` | `u32`, `[]const u8` |
| `icon` | (none) | `widgets_icon.ct.icon(th, ic)` icon.zig:58 | `src="ns.decl"`: an `Icon` constant in the handlers module | none |
| `image` | `img` | `widgets_image.ct.image(th, pic, opt)` image.zig:153 | `src="ns.decl"` (`Image`), `fit` etc. as `Options` | none |
| `label` | (above) | label.zig:59 | | |

### Overlay widgets (10): a type generator and `ComptimePage`

These have no `ct` namespace. A generator returns a type whose builders give the spec parts.
The page then runs as `popover.ComptimePage(State, spec, th, H)` (popover.zig:333) with that
type as its hooks `H`, instead of running as `ComptimeUi`.

| Element | Aliases | Generator (file:line) | Spec parts | Attributes |
|---|---|---|---|---|
| `popover` | (none) | `Popover(th, .id, .open)` popover.zig:86 | `.button(.text)`, `.layer(children)` | `id`, `bind` (open) |
| `tooltip` | `title` attribute | `Tooltip(th, .target, .tip)` tooltip.zig:58 | `.bubble(.text)` | `for`, `bind` |
| `menu` | (none) | `Menu(th, .id, .menu, def)` menu.zig:94 | `.button(.text)`, `.layer()` | `id`, `bind`; `<item>` children → `Def.items` |
| `menubar` | (none) | `MenuBar(th, .id, .field, def)` menubar.zig:83 | `.row()`, `.layer()` | `id`, `bind`; `<menu>` children → `BarDef` |
| `contextmenu` | (none) | `ContextMenu(th, .id, .target, .field, def)` contextmenu.zig:64 | `.layer()` | `id`, `for`, `bind` |
| `dialog` | `dialog` | `Dialog(th, .id, .field, def)` dialog.zig:71 | `.button(.text)`, `.layer(.title, .message)` | `id`, `bind`, `buttons` → `Def.buttons` |
| `toast` | (none) | `Toast(th, .id, .field, .trigger)` toast.zig:57 | `.layer(.text)` | `id`, `bind`, `trigger` |
| `select` | `select` | `Select(th, .id, .field, .text, def)` select.zig:65 | `.button()`, `.layer()` | `id`, `bind`; `<option>` → `menu.Def` |
| `combobox` | `input list=` | `Combobox(th, .id, .field, .text, def)` combobox.zig:100 | `.input()`, `.layer()` | as select |
| `datepicker` | `input type=date` | `Datepicker(.id, .field)` datepicker.zig:413 (takes no theme) | `.button()`, `.layer()` | `id`, `bind` |

### Interop and custom drawing

| Element | Construct | Notes |
|---|---|---|
| `region` | Named layout slot from `ct_interop.region(.id, style)`; custom-command marker in a widget page (G3) | Hosts a runtime subtree (section 5). Can also be written by hand, with `build="ns.fn"`, to host a runtime build function the user writes. |
| `canvas draw="ns.fn"` | runtime: `Frame.custom(id, style, data)` frame.zig:94; comptime: gap G3 | The host draws the rect in paint order (`docs/guide/custom.md`, route 2). The proposed generated host resolves the node ID to the application’s Zig callback. Device setup receives the WebGPU device and queue, and dirty nodes receive an encoder and target texture view. The renderer owns the handoff and composites in paint order. The Vulkan research branch tested this contract. A shipped host adapter and backend capability check remain prerequisites. A clean node reuses its texture. |

### Gaps: what the API cannot express today

The tool rejects each of these with a message. None is papered over in generated code.

- **G1, literal text.** A comptime label shows a state field and nothing else. `ComptimeUi`
  pushes `@field(state, n.bind.?)` (base.zig:471-475), and `checkBindings` requires a
  `[]const u8` field (base.zig:158-172). So `<button>Reset</button>` has no mapping. Proposed
  fix: an optional `Spec.text: ?[]const u8` that labels show when `bind` is null. It is
  constant, so it gets no dirty-mask bits and costs no RAM. The fix touches spec.zig plus the
  label pushes in base.zig and popover.zig. Until then the tool gives the G1 message from
  section 1.
- **G2, per-node text style.** Label text takes the page theme's `labelText(&th)`
  (base.zig:201, used at base.zig:474), and `ct.label` ignores its `th` (base.zig:296). CSS
  `color` and `font-size` therefore map only at `:root`, to `Theme.text` and `Theme.text_px`.
  Runtime inheritance exists (`theme.Inherited`, theme.zig:291) but the comptime front end has
  no equivalent.
- **G3, multiple custom rows in a widget page.** `Spec.widget.push` can already write a
  custom command. The checked-in mixed example reserves one marker and composes a runtime
  list into it. `ComptimeUi.Tables` still carves one `Customs` slot. A page with two canvases,
  or a canvas alongside a runtime region, needs a computed slot count and a reusable marker
  builder. Check both markers survive clipping, independent redraws and composition in order.
  [Mixed example](../../src/comptime/mixed.zig) · [Widget tables](../../src/widgets/base.zig)
- **G4, overlays next to widgets.** `ComptimePage` takes one hooks type and builds only rows,
  columns and labels. A checkbox or slider in it is a compile error (popover.zig:481).
  `ComptimeUi` has no overlay layer. A page that mixes an overlay with other interactive
  widgets therefore falls back to the runtime front end (section 5) unless a shared page API is introduced.
- **G5, HTML tables and per-copy list data.** `ct.table` binds header and cell *fields*, not
  markup cells, so `<table><tr><td>` is not mapped. A `spec.list` copy shows the same fields
  in every copy: "what differs per item is run-time data the caller keeps by copy index"
  (`src/comptime/spec.zig`, doc comment for `list`). So `{item.x}` in a bounded `each` cannot be comptime.
- **G6, per-widget state colours.** CSS on a widget's own node patches `Spec.style`, but
  widgets overwrite `fill` from the page theme each frame (button.zig:90). `theme.override`
  (theme.zig:193) restyles one widget only in the runtime front end, because a comptime
  widget reads `@TypeOf(ui.*).theme`. So `button.danger { background: red }` is rejected.
  `button { background }` on all buttons sets `Theme.control` instead (section 3).
- **Not in LCGF at all:** margin, gradients, shadows, fonts by name, CSS transitions, z-index.
  Section 3 lists what each is rejected with.

## 3. CSS mapping

Styles are resolved entirely at build time. The tool matches selectors against the static
tree, applies the cascade (specificity, then source order, with inline `style=""` last), and
writes the result into each node's `Style` literal. Nothing about CSS exists at run time: there
is no selector engine, no cascade and no inheritance. A runtime cascade would need per-node
style lookup each frame, which the comptime front end exists to avoid (DESIGN.md "Comptime").

Inside a runtime region (section 5) the same resolution runs on the region's template, and
each copy gets the template's resolved `Style`.

### Properties

`Style` is at types.zig:318-366. All lengths are logical px. `<n>px` and a bare number are
accepted. `em`, `rem`, `vw` and `vh` are rejected, because nothing at build time knows the
font or viewport size.

| CSS | `Style` field | Rule |
|---|---|---|
| `width`, `height` | `size[0]`, `size[1]` (types.zig:322) | `Npx` → `.px(N)`; `N%` → `.pct(N/100)`; `auto`, `fit-content` → `.fit` (types.zig:193-208) |
| `flex-grow: N`, `flex: N` | `size[main]` → `.grow(N)` | `main` is the parent's axis |
| `align-self: stretch` | `size[cross]` → `.fill` | |
| `flex-shrink: 1`, `min-width: 0` | `shrink = true` (types.zig:332) | |
| `min-width`, `min-height` | `min` (types.zig:323) | px only |
| `max-width`, `max-height` | `max` (types.zig:324) | px only; `none` → inf |
| `padding` (1 to 4 values), `padding-left` etc. | `pad` (types.zig:325-326) | **Reordered**: CSS writes top right bottom left, `pad` is left, top, right, bottom |
| `gap` | `gap` (types.zig:327) | One value, or two equal ones. `row-gap` ≠ `column-gap` is rejected (one gap, along `dir`) |
| `flex-direction: row\|column` | the builder (`row` or `col`) | On `div`, picks the builder. On `col` or `row`, a contradicting value is an error (`spec.col` forces `.y`, spec.zig:49-52) |
| `justify-content: start\|center\|end` (and `flex-*`) | `main` (types.zig:329, `Align` 245) | `space-between`, `space-around` and `space-evenly` are rejected (no such `Align`) |
| `align-items: start\|center\|end` | `cross` (types.zig:331) | `stretch` → each child's `size[cross] = .fill`; `baseline` rejected |
| `position: absolute` + `left`, `top` | `float = true`, `offset` (types.zig:334-336) | Relative to the parent's content origin. `right`/`bottom` rejected |
| `overflow: hidden` | `clip = true` (types.zig:338) | `scroll`/`auto` → error: `use <scroll>, which keeps the offset in a state field` |
| `background-color`, `background` (one colour) | `fill` (types.zig:342) | Images and gradients rejected |
| `border: Wpx solid C`, `border-width`, `border-color` | `border`, `border_color` (types.zig:343-344) | One width and colour for all sides; `solid` only |
| `border-radius` (1 value) | `radius` (types.zig:345) | |
| `border-radius` (4 values) | `radii` (types.zig:353) | Same corner order as CSS: TL, TR, BR, BL |
| `opacity` | `opacity` (types.zig:356) | Multiplies down the subtree, as CSS does |
| `transform`: `translate`, `scale`, `rotate`, `skew`, `matrix` | `transform` (types.zig:360) | Folded into one affine at build time. CSS's default origin is the centre, which matches `transform`. `transform-origin` other than `center` is rejected |
| `color`, `font-size` | G2: only on `:root` → `Theme.text`, `Theme.text_px` | Elsewhere: `color on <label> needs per-node text style (gap G2); set it on :root` |
| `--material: ns.decl` | `material`, `params` (types.zig:348-350) | The handle is a constant in the handlers module |

Colours accept `#rgb`, `#rgba`, `#rrggbb`, `#rrggbbaa`, `rgb()`/`rgba()`, `transparent` and
the CSS named colours. They become `Color.hex(0xRRGGBBAA)` (types.zig:117).

### Selectors

| Supported | Rejected |
|---|---|
| Type (`button`), class (`.bar`), id (`#volume`), `*`, descendant (`a b`), child (`a > b`), lists (`a, b`), `:root` | Attribute selectors, sibling combinators (`+`, `~`), `:nth-child` (could be resolved at build time; left until someone needs it), `::before`/`::after` (no generated content) |
| `:hover`, `:active`, `:focus`, `:checked`, only on a bare widget type selector (`button:hover`): they set page theme colours (below) | A state pseudo-class on anything narrower (`.bar button:hover`), because state colours are per page (G6) |

### Theme tokens as custom properties

The page theme is `lcgf.theme.widgets(&lcgf.theme.dark)` or `light` (theme.zig:98-100, 171).
Declarations on `:root` override its fields through `lcgf.theme.override` (theme.zig:193), at
comptime. `var(--x)` anywhere is replaced by that token's value at build time.

| Custom property | `widgets_base.Theme` field (base.zig:87-108) | Also set by |
|---|---|---|
| `--text` | `text` | `:root { color }` |
| `--text-px` | `text_px` | `:root { font-size }` |
| `--panel` | `panel` | |
| `--control` | `control` | `button { background }` |
| `--control-hot` | `control_hot` | `button:hover { background }` |
| `--control-held` | `control_held` | `button:active { background }` |
| `--accent` | `accent` | `:checked { background }`, `accent-color` |
| `--radius` | `radius` | `button { border-radius }` |
| `--pad` | `pad` | |
| `--gap` | `gap` | |
| `--space-xs`…`--space-xl`, `--radius-xs`…, `--text-xs`… | read-only: `Tokens.space`, `radius`, `text_size` scales (theme.zig:64-71) | |

### Unsupported, with the reason

| CSS | Why |
|---|---|
| `margin` | `Style` has no margin. `margin is not in LCGF: use the parent's gap or padding` |
| `display: grid`, `flex-wrap` | Grid and wrap are separate layout lanes and not in `Style` yet |
| `@media` (including `prefers-color-scheme`) | It would need a run-time cascade. Appearance switching is `theme.recolor` on the draw list (theme.zig:263), a later step |
| `transition`, `animation`, `@keyframes` | Animation is run time (`Frame.animate`, `tween`). Not a property |
| `box-shadow`, gradients, `filter` | Not in `Style`. Possible later as a material |
| `font-family`, `font-weight`, `line-height`, `text-align` | Text goes through the text protocol (docs/guide/text.md), not `Style` |
| `z-index` | Paint order is tree order; `float` and layers are the only reordering |
| `!important` | Ignored with a warning: the tool already shows each node's winning declaration (`--explain`) |
| `em`, `rem`, `vw`, `vh`, `calc()` | No font or viewport at build time |

## 4. Parser choice

Full table, sources and probe output: `docs/research/markup/parsers.md`. The probe program is
`docs/research/markup/lexbor-probe/probe.c`.

| Candidate | Language, licence | Builds with `zig build` alone? | Verdict |
|---|---|---|---|
| **lexbor 3.0.1** | C99, Apache-2.0 | Yes. 190 `.c` files (63k lines) for HTML + CSS, no generated headers, no system libraries. Flags: `-DLEXBOR_STATIC -D_POSIX_C_SOURCE=199309L -I source`. Compiled with 0 errors on 0.18.0-dev.1151 | **Chosen, for both HTML and CSS** |
| libxml2 2.15 | C, MIT | Needs generated config headers (the allyourcodebase port uses `addConfigHeader`) | HTML5 tokenizer, but no HTML5 tree building and no CSS. Line numbers only, capped at 65,535 |
| gumbo (codeberg fork 0.14.1) | C99, Apache-2.0 | Yes, by hand (upstream uses meson) | HTML only. Best per-node positions. Its tree builder has the problem below |
| NetSurf libcss + libhubbub | C, MIT | No: libcss generates its property parsers with a perl/Makefile step | Ruled out |
| katana | C, MIT | Yes | Archived in 2021 |
| html5ever, lightningcss, Servo cssparser/Stylo | Rust | No: needs cargo, which only the `vs` shell has | Ruled out by the dependency rule |
| superhtml 0.7.1 (Zig) | Zig, MIT | **No**: fails on 0.18-dev (`packed` is now `bitpack`) | Best Zig-native option. Revisit if it tracks 0.18 |
| rem (Zig) | Zig, GPL-3.0 | | Licence rules it out |
| zss (Zig) | Zig, CC0 | Pinned to 0.15.2 | CSS support is partial |

Pin, checked with `zig fetch`:

```zig
.lexbor = .{
    .url = "https://github.com/lexbor/lexbor/archive/refs/tags/v3.0.1.tar.gz",
    .hash = "N-V-__8AABbVvAJ6W3IAOXu1CuKXDihBIiJuvDPd8NDcYyWf",
    .lazy = true,
},
```

**HTML tokenizer.** The probe showed that HTML5 tree
construction silently deletes `<col>` and `</col>` (in the "in body" insertion mode `col` is
ignored) and adds `<html><head><body>`. Any spec-compliant tree builder does this, including
gumbo and html5ever, and does similar things to `table`, `select`, `p`, `li` and `option`. The
tokenizer keeps every tag and attribute: `on:click` arrives as an ordinary attribute, and
`{count}` as text. Each token carries a `begin` pointer, so line and column come for free. The
tool builds its own tree from the tokens (a stack, about 100 lines). This is also why the
grammar can use any tag name.

Consequences:
- The tool scans text tokens for `{…}` itself, offsetting positions from the token's start.
- The tokenizer does not switch to raw-text mode for `<style>` on its own; the tree builder
  normally does that. The tokenizer-only probe calls `lxb_html_tokenizer_set_state_by_tag` at the
  opening style token. The raw text `/* <row> &amp; */ .bar { gap: 4px }` stayed a single
  text token, followed by the closing style token and a normal self-closing column.
- Text entities are decoded by the tree builder, not the tokenizer. The tool decodes the
  five XML entities and rejects others.

**CSS: lexbor's CSS module**, from the same tarball and the same `build.zig`. It implements CSS
Syntax 3. The stylesheet parse returns selector lists and declarations with byte offsets for
prelude, name and value. Properties lexbor does not know (`gap`, `background`) are kept with
their raw value as `_custom` declarations, not dropped. The tool parses values itself from the
tokens, so lexbor's property table does not limit what section 3 accepts.

**Parser selection.** It is the only candidate that is maintained (3.0.1, pushed
2026-11-15), covers both languages, carries positions, and builds with `zig cc` alone. Because
it is C, Zig's dev-cycle syntax changes cannot break it, which is what happened to superhtml on
0.18-dev. Bindings follow the HarfBuzz adapter's style: hand-written `extern` declarations for
the dozen functions used, not `addTranslateC` (DEPENDENCIES.md, "C header translation").

## 5. Comptime or runtime: inference rules

The tool classifies every element bottom-up into one of three classes. The first rule that
applies wins.

1. **Runtime (R)**: the element is
   - an `<each of="…">` (one copy per slice element, length unknown at compile time);
   - an `<each count>` whose template uses `{item.…}` (G5: copies cannot differ in comptime);
   - any element inside an R element.
2. **Bounded (B)**: an `<if test="flag">` → `spec.when(.flag, subtree)`, an
   if/else → `spec.choice(.flag, style, .{ false_arm, true_arm })`, or an
   `<each count="n" max="N">` → `spec.list(.n, N, style, template)`. Their rows are all reserved at compile time. A dead row
   takes no space, is not drawn and is not hit (`src/comptime/dynamic.zig`), so they
   stay in the comptime spec.
3. **Static (S)**: everything else.

For each outermost R subtree, generate a runtime build function and a custom marker in
the widget host. The mixed example shows the marker's `Spec.widget.push` hook.
`ct_interop.region` alone creates a named column for layout. `compose` requires a draw
list with the corresponding custom command. Use the G3 marker for a widget host.
Whole-page fallback: the page compiles to the runtime front end alone when the root is R, or
when G4 applies (an overlay next to other interactive widgets). `--explain` prints each R or B
decision and each fallback with its markup location, such as
`app.html:9:5: note: runtime region: <each of="files"> has no max`.

Examples:

```html
<each count="n_rows" max="16"><label>{row_text}</label></each>
```
B: `s.list(.n_rows, 16, .{}, label(th, .row_text))`. 16 copies are reserved and `n_rows` (an
integer) picks how many are live.

```html
<if test="advanced"><checkbox id="wire" bind="wireframe">{wire_text}</checkbox></if>
```
B: `s.when(.advanced, checkbox(th, .wire, .wireframe, .wire_text))`.

```html
<each of="files" as="file"><button id="open" on:click="files.open">{file.name}</button></each>
```
R: a region `files_0` in the spec, plus a generated function:

```zig
fn region_files_0(f: *lcgf.frame.Frame, th: *const w.Theme, rt: anytype) void {
    for (rt.state.files, 0..) |file, i| {
        if (lcgf.widgets_button.button(f, th, Id.from("open").with(@intCast(i)), file.name).clicked)
            h.files.open(rt, @intCast(i)); // app.html:12:40
    }
}
```

The generated `frame` lays out the comptime UI and reads the region's rect. It then runs a
`Context` over `interop.regionInput(in, rect)` (interop.zig:62), calls the build function, and
merges the two draw lists with `interop.compose` (interop.zig:88). The region's `Context`
buffer is sized by `Limits` given on the element (`<each of … nodes="256" texts="64">`) or by
defaults. Exceeding them is the runtime front end's usual `Output.status`, not a crash
(runtime.md "Memory").

`ComptimeUi` does not yet build `Spec.region` rows (ct-dynamic wired them into the comptime
`Layout`, src/comptime/layout.zig) or reserve multiple custom slots (G3). These widget-page integrations are listed in
section 9.

### Types, bounds and generated storage

Application state comes from the declared Zig type. For example,
`<each count="n_rows" max="16">` bound to `App.n_rows: u32` keeps that field as `u32`,
and a slider bound to `App.volume: f32` keeps its floating-point value. A slider wired
to a `u8` field yields a diagnostic at the binding that names both types. The HTML
parser can read literal tokens with arbitrary precision and the emitted Zig checks
their range against the actual builder parameter. This also covers signed minima,
out-of-range integers and non-finite dimensions.

For generated storage, derive the representation from the full range including any
sentinel. Reuse `Flat(spec).Index`, which holds `0…node_count`. Eight flattened nodes
therefore use `u4` indexes. A generator-owned counter that must represent `0…16`
uses `std.math.IntFittingRange(0, 16)` (`u5`), while a zero-based index for 16 items
uses `u4` if it has a separate validity flag. A run-time slice retains its Zig length
type. Check conversions to a widget's fixed-width count or ID before emitting a row.
A bounded view honours `spec.list`'s documented clamp to its maximum. Its backing state
keeps the original count. `--explain` should show the bound, any sentinel, generated
type and storage owner so the user can audit the decision. Verify the 15/16 and 255/256
boundaries and an overflowing literal in the lowering fixtures. [Flattening](../../src/comptime/flatten.zig) · [List semantics](../../src/comptime/spec.zig)

### Bindings and signals

The generated spec carries every binding as `Spec.bind`. `Signals(State, spec)`
(signals.zig:24) then derives at compile time, for every field, a constant layout mask and
paint mask of the nodes it affects. A label's text can change its size, so its field dirties
layout for the label and its ancestors. A slider keeps its size, so it only repaints
(comptime.md "What the compiler resolves").

- **Setter cost.** `rt.set(.field, v)` (signals.zig:304) is one store, plus one OR with a
  constant mask per pass whose mask is non-zero, with no subscriber list. The masks are one
  integer up to 32 nodes, and one OR per touched `u32` word past that. Then come the derived
  fields that read the field, recomputed in topological order, and an OR into the pending
  effects when an effect watches it. `stage` and `commit` (signals.zig:318, 329) batch several
  sets so each derived field is computed once. Markup adds nothing to this path.
- **Derived fields** stay in Zig: `pub const derived = .{ .gain = .{ .from = .{ .volume, .muted },
  .compute = gainOf } }` on the state struct (signals.zig:11-17). Markup binds `{gain}` like
  any field. `bind="gain"` on a writing widget is an error, because a derived field cannot be
  set (signals.zig:306). The tool's check block (below) reports it at the markup line:
  `'gain' is derived; a two-way binding needs a plain field`.
- **Effects and systems.** `pub const effects = .{ .save = .{ .volume } }` on the state. The
  generated `frame` drains them: `while (ui.signals.takeEffect()) |e| switch (e) { inline else
  => |t| @field(h.systems, @tagName(t))(&ui.signals) }` (signals.zig:355). Because the switch
  is exhaustive, an effect with no system is a compile error. The check block names it:
  `effect 'save' of App has no system: add pub fn save(rt: anytype) void to systems`.

### Handlers

A handler is a public function in the handlers module, reached by the path in `on:…`:

```zig
pub const counter = struct {
    pub fn dec(rt: anytype) void { rt.set(.count, rt.state.count - 1); }
};
```

- Signature: `fn (rt: anytype) void`, where `rt` is `*Ui.Signals.Runtime`. Writing through `rt`
  is what marks nodes dirty; a handler that wrote `rt.state` directly would skip that. Widgets
  whose `Event` carries a payload (`number`, `textfield`, `search`, `textarea`; `Payload`, see
  base.zig:50-53) take a second parameter: `fn (rt: anytype, value: anytype) void`. Handlers in
  a runtime region take the copy index: `fn (rt: anytype, index: u32) void`.
- `anytype` because the handlers module cannot name `Ui`, which is defined in the generated
  module that imports it. The check block verifies the arity instead.
- Events: `on:click` (button, toolbar and breadcrumb items, the overlay triggers), `on:change`
  (every widget with a bound value; it runs after the widget has written its field, as
  `ComptimeUi.frame` does for checkboxes and sliders, base.zig:396-411), `on:remove` (chip).

### The check block: typos are errors at the markup's file and line

The generated file opens with one `comptime` block. It references every name the markup uses,
each with the markup location it came from:

```zig
comptime {
    need(h, "counter.dec", 1, "app.html:3:16");
    field(h.App, "title", []const u8, "app.html:2:11");
    bindable(h.App, "volume", f32, "app.html:5:9"); // exists, has the type, is not derived
    effects(h.App, h.systems, "app.html:1:2");
}
```

`need` walks the path with `@hasDecl` and checks that the end is a function of the right arity.
For widget types, `field` reuses each widget's own `bindError(State, name)`. Eleven widgets
have one: label, checkbox, slider, range, number, radio, toggle, switch, textfield, search,
textarea. The overlays use their `check*` functions (e.g. dialog.zig:58). So the rules are the
widgets' rules, with the markup location prefixed. Probe (`docs/research/markup/zero-cost/`,
a misspelt handler and a misspelt field):

```
bad1.zig:32:33: error: app.html:3:57: no declaration 'counter.icn' in the handlers module
bad2.zig:42:34: error: app.html:2:11: state handlers.App has no field 'titel'
```

The widget's own check can also fire, with its message carrying no location. The markup line
comes first in the output, so the reader sees it.

## 6. The tool and the build

### Where the code lives

`tools/markup/` is a host program, outside the tiers, like `tools/bench/`. Neither the core nor
the generated code imports it. The generated file imports only `lcgf` and the handlers module,
the same imports a hand-written page has. Files:

| File | What |
|---|---|
| `main.zig` | Arguments, reading files, writing the output and the dep file, printing errors |
| `lexbor.zig` | `extern` declarations for the tokenizer and stylesheet functions used |
| `html.zig` | Tokens → node table (SoA: tag, parent, first attribute, source offset), `{}` scanning, grammar errors |
| `css.zig` | Stylesheet → rules (selector, specificity, declarations, offsets); value parsing for section 3's properties |
| `cascade.zig` | Selector matching over the node table; the winning declaration per property per node; theme tokens |
| `lower.zig` | Classification (section 5), element table (section 2), Zig emission |
| `testdata/` | Markup pages, their expected `.zig`, and one file per error message |

### The build step

lcgf's `build.zig` gains one public function. Application build files reach it through
`@import("lcgf")`, as Zig lets a build script call its dependency's build functions
(`std.Build.dependencyFromBuildZig`, lib/std/Build.zig:2149):

```zig
// the application's build.zig
const lcgf = @import("lcgf");
const ui = lcgf.addMarkup(b, .{
    .source = b.path("ui/app.html"),
    .style = b.path("ui/app.css"), // optional; <style> blocks are read too
    .handlers = app_mod,           // State, handlers, systems, icons
});
exe.root_module.addImport("app_ui", ui); // const ui = @import("app_ui"); ui.frame(&page, &in)
```

`addMarkup` follows the `ucd-gen` step that already exists (build.zig:22-31):
- `addRunArtifact` of the tool, built for `b.graph.host`, linking lexbor from the lazy
  dependency (as HarfBuzz is built, build.zig:362-369);
- `addFileArg` for the source and the style;
- `addOutputFileArg("app_ui.zig")`;
- `addDepFileOutputArg2` (lib/std/Build/Step/Run.zig:547), into which the tool writes every
  imported component, so editing a component reruns it;
- `createModule` over the output, with imports `lcgf` and `handlers`.

Open point for M1: whether a lazy dependency of lcgf can be fetched from inside `addMarkup`,
which runs in the application's build. The fallback is lcgf's `build()` declaring the tool
artifact behind `b.lazyDependency("lexbor", …)`, with `addMarkup` taking it via
`dep.artifact("lcgf-markup")`.

### Standalone Zig export

Provide a proposed host command `lcgf-markup export --project APP --out-dir DIR`.
The application supplies its entry module, handler module, source dependencies, assets
and LCGF package pin through the same build configuration as `addMarkup`. A markup
fragment alone cannot describe an application's entry point or native link options.
Diagnose any missing build inputs by name.

The user-selected directory contains `build.zig`, `build.zig.zon`, the application entry
point, the generated UI module, and the Zig handlers, components, assets and package
dependencies it needs to build. Preserve the package's minimum Zig version, target options,
asset layout and dependency hashes. Copy project-local dependencies or relocate them
inside the export. Verify that every referenced path resolves after moving the export
away from the source checkout. Write into a new or empty directory and report collisions
before writing. The source project and Zig cache stay independently usable.

Plain `zig build` in the exported directory consumes the exact generated module bytes
used by the normal build. Neither HTML/CSS inputs nor the parser are prerequisites for
the exported build. Keep source locations in the generated code as project-relative
comments. The acceptance fixture exports an app with a CSS class, imported component,
a typed Zig handler and a custom-draw binding. Copy the output to a fresh location,
build there with pinned dependencies, replay a click, and compare its UI draw list to
the original. Check a second export for deterministic contents and verify the target
dependency graph has no markup compiler or lexbor.

### Errors map back to markup lines

- **Tool errors** (grammar, CSS, mapping) are printed by the tool as `app.html:3:9: error: …`
  with the line and a caret, and the run step fails. `zig build` shows the tool's stderr.
- **Zig errors in the names** come from the check block (section 5) with the markup location
  in the message.
- **`validate.check` errors** carry a spec path such as `col > row[1] > slider[0]`
  (validate.zig:18-20). The generated file's header has a table from each spec path to its
  markup location, and each builder call ends with a `// app.html:L:C` comment. If that proves
  too indirect, the next step is an optional `Spec.src` that `validate` prefixes. It is not
  proposed now.

### Incremental rebuilds

The run step is cached on the bytes of its inputs and arguments. Editing the markup or CSS
reruns the tool (milliseconds; to be measured in M12) and recompiles the generated module.
Editing only the handlers does not rerun the tool: names are resolved by the Zig compiler, not
the tool. The output is deterministic (no timestamps, no hash-map order), so unchanged markup
gives an identical file and a cache hit downstream. Zig's incremental compilation (ct-budget's
"edit-rebuild time" commit) applies to the generated file as to any other.

## 7. Proof of zero cost

**Method.** This is the render selector's method (ci/jobs/render-select.sh): two objects built
ReleaseFast and stripped, compared by the size and SHA-256 of `.text` only, with the job's own
`text()` function. Here the two objects are a page written by hand and the same page as the
tool emits it, with the check block, the handler dispatch and the source comments.

**Probe, done** (`docs/research/markup/zero-cost/`: `hand.zig`, `gen.zig`, `handlers.zig`,
`run.sh`; on 0.18.0-dev.1151):

```
hand: 20972 22b29a10efe6585e0421a06f8f0e7064a8f4ddd8ec262b59e012d94999f5ebf7
gen: 20972 22b29a10efe6585e0421a06f8f0e7064a8f4ddd8ec262b59e012d94999f5ebf7
```

The check block is comptime-only and emits nothing. The dispatch switch is the switch a person
writes. So markup costs nothing as long as the tool emits the hand-written form. Two tests keep
it that way:
1. **Spec equality**, in `zig build test`: for each `tools/markup/testdata` page, its committed
   hand-written twin's `Spec` equals the generated one, compared at comptime with
   `expectEqualDeep` as spec.zig:274-277 does.
2. **Identical `.text`**, a CI job `ci/jobs/markup-zero-cost.sh`: `run.sh` generalised over the
   testdata pages. It fails on the first page whose two hashes differ.

**Compile-time budget.** The gate (bench/gates/gates.py:216-266) times
`zig build-obj -fno-emit-bin` of a generated spec (a column of rows of nine labels, sizes 100,
1,000 and 10,000), with an empty cache, median of 5. Its recorded budgets are 0.094, 0.146 and
0.53 s (bench/gates/recorded.json:133-137). The markup gate adds two rows per size:

| Measure | Budget |
|---|---|
| Tool run time (parse, cascade, emit) for the same page as markup | at most 10% of that size's compile-time budget: 9 ms, 15 ms, 53 ms |
| `zig build-obj -fno-emit-bin` of the generated file | the hand-written page's budget, within the gate's tolerance (50%) |

The second should come out equal, because it is the same code. Anything above is the check
block, which runs one `@hasDecl` walk per name. Measuring it per size is part of M12. Measure the tool's elapsed time in the compile-time gate when a buildable tool exists.

## 8. Later: a runtime interpreter for hot reload

In development builds the same markup could be interpreted by the runtime front end, so that
editing the HTML or CSS changes the running app without recompiling.

What it takes:
- **Parsing at run time.** `html.zig`, `css.zig` and `cascade.zig` would be shared with the tool
  and built into a dev-only module that links lexbor. It sits outside the tiers, like
  `src/assets/`, because it reads files through the host's `std.Io` (ARCHITECTURE.md
  "outside"). Its output is the same node table, with each node's resolved `Style`.
- **An interpreter.** One function walks the node table each frame. It calls `Frame.open`,
  `leaf`, `text` and `close` (frame.zig:52-94), and each element's *runtime* widget function
  (the same modules: `button` button.zig:54, `slider` slider.zig:100, `textfield`
  textfield.zig:318, …). `<if>` and `<each>` become plain control flow, which the runtime
  front end handles directly.
- **Names at run time.** Bindings and handlers are compiled in, not parsed. A generated table
  maps each state field name to a getter and setter, written with `inline for` over the
  state's fields, and each handler path to a function pointer. Markup that names something
  new still needs a rebuild; the interpreter says so and keeps the last good tree.
- **Reload.** The host polls the file's mtime (or the shell's file watcher, when there is
  one) and reparses on change. Measure the parse and reload time separately from frame time.
- **Agreement.** `widgets_base.Harness` already runs one page through both front ends and fails
  when their draw lists differ (`sameDraw`, base.zig:573-592). The interpreter gets the same
  test against the generated comptime page.
- **Release builds** contain none of it: `addMarkup(.{ .hot = true })` only in Debug.

Cost to build: about four commits (section 9, lane `markup-dev`), after the tool exists.

## 9. Milestones

These proposed entries use the historical planning format. They are not
added: the plan is not edited here. Four lanes. Two are small prerequisites in existing
families (`ct-*`, `w-*`). `markup` is the tool, `markup-dev` is section 8. Commit titles
follow the repository's `area: verb …` style. Every commit builds and passes
(CONTRIBUTING.md).

```python
# P03: what markup needs from the comptime front end (also useful without markup).
lane("P03", "ct-markup", ["ct-dynamic", "ct-interop"], K("Spec"), "E1", "literal labels need no state field", [
    ("comptime: add Spec.text for literal label text", {}),
    # Done when: a label with .text and no .bind flattens, has no bits in any field's mask,
    # and validate.check accepts it; compile-fail case for a label with neither.
])

# P10: what markup needs from ComptimeUi (src/widgets/base.zig).
lane("P10", "w-markup", ["ct-markup", "ct-dynamic", "ct-interop"], W("ComptimeUi"), "E1", "Harness pages pass with literal text, regions and custom rows", [
    ("widgets: show Spec.text in ComptimeUi and ComptimePage labels", {}),
    # Done when: a Harness page with literal labels draws the same as its runtime twin.
    ("widgets: build list, when and choice rows in ComptimeUi", {}),
    # Done when: a Harness page with spec.list, spec.when and spec.choice, stepped through count and
    # condition changes, draws the same as the runtime page that builds only the live rows.
    ("widgets: size and emit custom rows for multiple regions and canvases", {}),
    # Done when: a comptime page hosting a runtime region, merged with interop.compose,
    # draws the same as the all-runtime page; a canvas node reaches the draw list as custom.
])

# P16: the tool.
lane("P16", "markup", ["w-markup"], R("MARKUP", "docs/plans/markup.md"), "E1", "markup pages build through lcgf.addMarkup with byte-identical .text", [
    ("markup: build lexbor from a lazy build.zig.zon dependency", {}),
    # Done when: (owner has approved the dependency) `zig build markup-probe` tokenizes
    # docs/research/markup/lexbor-probe/sample.html with line:col on every token; RAWTEXT
    # <style> handling confirmed; DEPENDENCIES.md has the row.
    ("markup: build the node table from the tokenizer", {}),
    # Done when: testdata pages give the expected node tables; every grammar error in
    # section 1 has a testdata file whose output is the exact message and location.
    ("markup: lower static pages to a Spec", {}),
    # Done when: for every element in section 2's tables a testdata page's generated .zig
    # compiles and its Spec equals the hand-written twin at comptime.
    ("markup: check names at their markup lines", {}),
    # Done when: compile-fail cases (missing handler, wrong arity, missing field, wrong type,
    # derived two-way binding, effect with no system) fail with the markup location,
    # run like ci/jobs/ct-compile-fail.sh.
    ("markup: dispatch events to handlers and effects to systems", {}),
    # Done when: a replayed page (testdata/*.replay) calls each handler once per click and
    # each system once per effect.
    ("markup: resolve CSS onto nodes at build time", {}),
    # Done when: each property and selector in section 3 has a test giving the exact Style;
    # each unsupported one is rejected with its message; :root tokens give theme.override.
    ("markup: add components and slots", {}),
    # Done when: a page using a component has the same Spec as the page written inline.
    ("markup: infer bounded regions from if and each", {}),
    # Done when: --explain prints the B decisions; generated when/list pages pass Harness.
    ("markup: host runtime regions for unbounded each", {}),
    # Done when: the files example (section 5) draws the same as an all-runtime page.
    ("markup: add lcgf.addMarkup with a dep file", {}),
    # Done when: an example app in examples/ builds from markup; touching only the handlers
    # module does not rerun the tool (zig build --summary all); editing a component does.
    ("markup: export a standalone buildable Zig project", {}),
    # Done when: relocate the export, build, replay and compare as described in section 6.
    ("markup: prove zero cost in CI", {}),
    # Done when: ci/jobs/markup-zero-cost.sh gives identical .text for every testdata page.
    ("bench: add markup rows to the compile-time gate", {}),
    # Done when: gates.py compile-time records tool and generated-compile time at 100, 1,000
    # and 10,000 nodes, within section 7's budgets.
    ("docs: write the markup guide", {}),
    # Done when: docs/guide/markup.md's examples are compiled by zig build docs.
])

# P16, later: hot reload (section 8).
lane("P16", "markup-dev", ["markup"], R("MARKUP", "section 8"), "", "an edited page reloads in a running Debug app", [
    ("markup: share the parser and cascade as a dev module", {}),
    ("markup: interpret the node table in the runtime front end", {}),
    # Done when: every testdata page, interpreted, passes Harness against its generated page.
    ("markup: reload on file change in Debug builds", {}),
    ("markup: generate name tables for bindings and handlers", {}),
])
```

The proposed entries use `MARKUP` to refer to this design. Waves and
prerequisites come from `generate.py` as usual.

Not planned, and why:
- **A comptime parser.** The brief says a tool for now. lexbor in a host program is fast, and
  comptime parsing would cost compile time at every build.
- **Per-copy list data (G5).** It would change `spec.list`'s design. Runtime regions cover it.
- **Per-widget theme state colours (G6) and per-node text style (G2).** These are comptime
  front-end design questions for the `ct-*` and `theme` lanes. Markup rejects them clearly
  until then.
