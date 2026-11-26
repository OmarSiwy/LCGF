# Engine API the markup compiler emits against

The markup compiler (tools/lcgf-gen/markup/) is the usage-first surface. It assumes the engine supports everything a page can say, and emits the calls a hand-written page would make. This file specifies the engine API those calls need. Main implements it; the compiler branch rebases onto main and moves each entry's fixtures from `markup-pending` to `markup`. Generated code does not change. If the engine's final API differs from an entry, the engine changes, unless there is a strong reason it cannot.

Same shape as §5 of docs/plans/markup-compiler.md.

**Status of an entry:**
- **landed**: exists on this branch.
- **emitted**: the compiler emits the call today. Its fixture is in `zig build markup-pending` and fails until main lands the entry.
- **specified**: the compiler rejects the construct today with the manifest's `planned` diagnostic. It will emit exactly the call below.

Every entry is tier 1 (src/comptime/spec.zig, src/runtime/frame.zig) or tier 2 (src/widgets/). Each must be zero cost when unused: no columns, the same pass sequence, unchanged `.text` for pages that do not use it (`ci/jobs/render-select.sh` method).

## Entries

| Id | Status | Declarations the generated code calls | Where | Fixture |
|---|---|---|---|---|
| E0 | landed (386e5d52) | `pub fn textStyled(comptime s: Spec, comptime text_style: types.TextStyle) Spec`: a label's text style, beside `styled` and `named`. | 1, spec.zig | hello, counter, landmarks, mixer |
| F1 | landed (engine; the compiler still rejects `<ul>`/`<ol>` until it lowers them) | `types.Role` gains `link = 8, separator = 16, list = 20, list_item = 21, table = 38, row = 40, cell = 41, column_header = 42, row_header = 43, dialog = 44, status = 56`, the byte values of `a11y.Role` (a11y/tree.zig). Emitted as `.role = .list` on `<ul>`/`<ol>`, `.list_item` on `<li>`, `.status` on `<output>`. | 0, types.zig | lists |
| F2 | landed | `pub fn flexed(comptime s: Spec, comptime flex: lcgf.flex.Flex.Style) Spec`, which sets `Spec.flex: ?Flex.Style = null`. ComptimeUi carves the `Flex` columns and runs `layout.runFlex`'s passes only when a spec node has one; a flex-free page's `.text` is unchanged. Runtime (deviation: caller-owned columns instead of `Limits.flex`, so `Context` is unchanged and costs nothing): the caller owns a `Flex` (`Flex.init` for `Limits.nodes`), writes rows with `fx.set(@backingInt(node), &style)` and ends with `Frame.endFlex(font, &fx)` / `Frame.layoutFlex(font, &fx)`, which reset the rows after layout. Not in the C ABI yet. The compiler emits `s.flexed(x, .{ .margin = .{ l, t, r, b } })` for CSS margins; next it emits `.wrap`, `.cross` (align-self), `.aspect`, `.baseline` and `.lines` (align-content) in the same struct. ComptimeUi's `Mono` has no ascent, so a text run's baseline is its bottom edge. | 1, spec.zig; 2, base.zig ComptimeUi; 1, frame.zig | flexitems |
| F3 | specified | `pub fn variants(comptime s: Spec, comptime field: @EnumLiteral(), comptime styles: []const types.Style) Spec`, which sets `Spec.styles: ?[]const Style` and `Spec.style_field: ?[]const u8`. ComptimeUi pushes `styles[@field(state, field)]`, and `Spec.shows` includes `style_field`, so the signal masks dirty the node. For `class:x="{f}"`, `hidden="{f}"` (Participation.collapsed) and `@media` buckets, it is driven by a generated field. | 1, spec.zig; 2, base.zig | variants |
| F3b | specified | `recipe_comptime.Config`, as button/checkbox use it today (recipe_comptime.zig:27), for number, search, textarea, select, list, tabs, accordion and link. The compiler lowers `:hover`/`:active`/`:focus-visible`/`:checked`/`:disabled` rules on a widget to `.recipe = …`. | 2, theme/recipe_comptime.zig | states |
| F4 | landed (engine; the compiler still rejects `<a>` until it lowers it) | `widgets_link`: runtime `pub fn link(f: *Frame, th: *const Theme, id: Id, text: []const u8) Response`, comptime `ct.link(comptime th: Theme, comptime id: @EnumLiteral(), comptime text: anytype) Spec` with role `link`; `text` is a literal or a string field. It activates on click and Enter (not Space). Its look is the breadcrumb link's (`linkStyle`, `linkFill`, `linkText`). For `<a href>`, with `on:navigate` receiving the href. | 2, new widgets/link.zig | links |
| T1 | landed | `widgets_textfield.ct.textfield`, `widgets_search.ct.search` and `widgets_textarea.ct.textarea` take `comptime hint: anytype`, a string literal or an enum literal naming a field, as `ct.label`'s `text` does (`textfield.hintSpec`; `hintError` checks a field). The compiler emits `textfield.ct.textfield(theme, .name, .name, "Name")`, with state `name: lcgf.widgets_textfield.Text(256)`. | 2, textfield.zig, search.zig, textarea.zig | form |
| T2 | landed | `spec.heading(level, caption)` accepts a `Spec` from `spec.text(...)`, so `<h1>Gain {g:.1} dB</h1>` is one heading: `s.heading(1, s.text("Gain {.1} dB", .{.g}))`. | 1, spec.zig | headings |
| T3 | landed | `widgets_button.ct.buttonStyled(comptime th: Theme, comptime id: @EnumLiteral(), comptime text: anytype, comptime text_style: types.TextStyle) Spec`, the caption drawn in `text_style`; runtime twin `buttonStyled(f, th, id, str, ts)`. CSS `color`/`font-size` on a `<button>` lowers to it (the compiler drops it with the planned diagnostic until it emits the call). | 2, button.zig | counter |
| T4 | landed; the compiler lowers `lcgf-if`/`lcgf-else` with it | `spec.choice(selector, style, alternatives)` takes a `bool` selector as well as an enum or integer: false selects the first alternative, true the second, so `lcgf-if`/`lcgf-else` lowers to `s.choice(.cond, .{}, .{ otherwise, then })`. | 1, validate.zig, spec.zig | todo |
| F7 | specified | `pub fn grid(comptime style: Style, comptime decl: lcgf.grid.Decl, comptime children: anytype) Spec` and `pub fn cell(comptime s: Spec, comptime area: lcgf.grid.Item) Spec` (Spec fields `grid`, `cell`). ComptimeUi runs `grid.run` (grid.zig:577) in place of the plain sequence when a node has a grid. Runtime: `Frame.openGrid(id, style, decl)`, `Frame.cell(node, item)`. | 1, spec.zig, frame.zig; 2, base.zig | grid |
| F8 | specified | `widgets_base.ct.pressable(comptime id: @EnumLiteral(), comptime style: Style, comptime children: anytype) Spec`, a focusable container whose click is its event (`on:click` on a `<div>`, `tabindex=0`, `:hover` on a box via F3). | 2, base.zig | pressable |
| F10 | landed for select and dialog (this branch) | `select.ct.select(th, .id, .field, opts)` in the flow and `select.ct.list(th, .id, .field, opts)` last in the root, `opts: select.Options` (captions, `<optgroup>` headers); the field is a `SelectState`, and the list is a `spec.when` over it (`SelectState.visible`). `dialog.ct.dialog(th, .id, .open, children)` last in the root: a backdrop and a modal panel around any content, a `spec.when` over the bool; Escape closes it, Tab stays inside. Runtime twins: `select.button` and `select.listGrouped` with `select.positional(n)`, `dialog.begin`/`end`. The compiler moves both last into a new root over the viewport (`Lowerer.hoistOverlays`). Menu, Popover and Tooltip still run in `ComptimePage` only. | 1, dynamic.zig, validate.zig; 2, base.zig, dialog.zig, select.zig | overlays |
| F11 | specified | `pub fn runs(comptime style: Style, comptime parts: anytype) Spec`, with parts `run("text", text_style)`, `run(.field, text_style)` and `link(...)`, for mixed phrasing in `<p>`/`<li>`/`<label>`. | 1, spec.zig, frame.zig | paragraphs |
| F12b | specified | `pub fn paragraph(comptime s: Spec, comptime p: lcgf.text_stack.Paragraph) Spec` (Spec field `paragraph`), for line-height, multi-line text-align, letter- and word-spacing, ellipsis and line clamp. | 1, spec.zig; 2, base.zig | paragraphs |
| F17 | specified | `pub fn anchored(comptime s: Spec, comptime a: lcgf.overlay.Anchor) Spec`, `sticky(s, top: f32)` and `layer(s, order: i16)`, for right/bottom/inset/fixed, `position: sticky` and z-index on floats. | 1, spec.zig, frame.zig | positioned |
| F18 | specified | No framework change. The generated `Page.frame` filters the focused widget's `Input.events` for `on:keydown:enter`/`:escape`/`:space` and arrows. | generated code | keys |

| R1 | landed | The runtime widget functions take the root's style, as `s.styled` restyles a comptime widget: `button.buttonFace(f, th, id, text, ts, face: Style) Response`, `toggle.toggleFace(f, th, id, value, text, face)`, `checkbox.checkboxFace(…, face)`, `switch.switchFace(…, face)`, `slider.sliderFace(f, th, id, value, lo, hi, face)`, `textfield.textfieldFace`/`passwordFace(…, hint, face)`, `search.searchFace`, `number.numberFace(…, range, face)`, `textarea.textareaFace(…, rows, hint, face)`, `link.linkFace(f, th, id, text, face)`, `progress.progressFace(f, th, value, face)` (its comptime push now builds the track from the spec's style too), `separator.separatorFace(f, face)`, `radio.radioFace(…, captions, face)`; the text controls' comptime push now builds its root from the spec's style too (it ignored `s.styled`), and focus sets the border in both (`textfield.focusFace`); the plain functions pass the theme's style. State still sets what it sets in both frontends (a button's fill, a checkbox's value). The runtime frontend emits them for a widget whose CSS changes its look. Every control the comptime page restyles now has one. | 2, the widgets' runtime functions | faces |
| R2 | landed (this branch) | `ComptimeUi.semantics(ui, s: *a11y.Semantics)` writes each live `Spec.name` into `Semantics.label`, its bytes added to the frame's strings (`spec.stringCapacity` counts them). Deviation: no `Frame.name`. The runtime page names its nodes the way an app's `semantics(t, s, str)` already does (src/shell/example.zig): the generated `Ui` records the row of each named node while it builds (`ui.named`) and `Ui.semantics(t, s, str)` writes them, so `Frame` and `Context` are unchanged. `Harness`'s `Semantic.run` calls both. Names come from `aria-label`, `aria-labelledby` (the referenced elements' literal text, joined) and, on a control that draws no caption (text, search, textarea, number, range, progress), from its `<label>`'s text. The runtime frontend refuses a name inside an `lcgf-each lcgf-max` template, where a copy would need one row per copy. | 2, base.zig; 1, spec.zig | landmarks, form, mixer, settings |

| T-RT | landed (this branch) | `lcgf.theme_table.ThemeTable(Tokens)`: `values: Tokens`, `generation: u32`, `set(t, comptime token, value)` (bumps the generation), `changedSince(t, seen) bool`. Tier 2, src/theme/table.zig. Under `--runtime-vars=t-`, the runtime frontend emits `pub const Tokens` (one field per `--t-*` the page reads, defaulting to its CSS value), `ThemeTable` and `default_tokens`. `Ui` gets `tokens: *const ThemeTable` and `themeChanged()`, and the style fields `ui.tokens.values.<name>` (pad, gap, size, min, max, border, radius, fill, border colour, text size and colour). | 2, theme/table.zig | tokens |
| T-CT | landed (this branch) | `spec.tokened(s, uses: []const spec.TokenUse) Spec` sets `Spec.tokens`, where `TokenUse = struct { target: TokenTarget, token: []const u8 }` names a field of `Tokens`. `TokenTarget` covers pad (four sides), gap, width, height, min, max, border, radius, fill, border_color, text_px and text_color. `widgets_base.ComptimeUiTokens(State, spec, theme, Tokens)` has `tokens: *const ThemeTable(Tokens)` (default `default_tokens`) and `themeChanged()`. Its push writes a container's or label's token fields from the table (`spec.applyTokens`), and every frame pushes every row, so a changed table lays out on the next frame. `ComptimeUi` is `ComptimeUiTokens(…, void)`: no field and no code, so token-free pages compile byte for byte as before. | 1, spec.zig; 2, base.zig | tokens |

### Run-time regions in comptime pages (M8.2)

These need no engine change:
- `<template lcgf-each="x in xs">` is `ct_interop.region(.each_xs, style)` in the Spec.
- `Page.frame(h, in, data)` builds `data.xs` into a second runtime `Context`, owned by the
  Page, through `ct_interop.regionInput`, and merges it with `ct_interop.compose` into a draw
  list the Page owns.
- The item fields are checked with `@hasField`, and the error carries the HTML location.

Requests, by usage:
- **E1 (landed, this branch):** `ct_interop.fitRegion(id, style)` and `setFit(ui, id, size)`. On a `fit` axis the region takes the size its owner last measured (kept in `ComptimeUi.keep`). The page builds its fit regions after the first layout, measures each content in its own viewport, and when a size changed lays the page out again in the same frame with `ComptimeUi.rebuild(in)` (build, layout and paint from the state, applying no input a second time; the frame's event stays the first layout's), so no frame shows the old size and none asks for another (`wake`). Pages without fit regions do not call it.
- **E3 (landed):** `layout.snapSubtree(t, node)` after finalize moves a subtree onto the grid
  from its root's snapped corner and finalizes it again. The comptime page snaps a region's
  rect and lays its content out at (0, 0) in it; the runtime page lays the same content out in
  place and calls this on each region's node in `Ui.end`, so a region at a fractional origin
  rounds alike in both (`testdata/components`). `Frame.layoutParagraphs` and
  `layoutFlexParagraphs` are the layout halves of the paragraph `end`s, for this step.
- **E2:** `compose` into several regions in one pass. Today the page composes them one after another into two draw lists it alternates between, so each region copies the commands before it; one pass would copy them once (a performance request, not a usage one).

### App components (M8.3)

- **Landed:** `spec.col`/`spec.row` take a slice of specs as well as a tuple, so a component
  passes its `children: []const Spec` prop on as it is. A component takes the page's `theme`
  first; a `var(--t-*)` prop is the token's field name, for `spec.tokened` (no engine change:
  `ComptimeUiTokens` already pushes token fields of every node). One name may hold both
  forms as a namespace with `spec` and `frame`; the call site picks by context. A runtime
  component with content (inside an lcgf-each) is a namespace with `open` and `close`; the
  generated code builds the content between the two calls, so no slot is a callback.
  The runtime frontend calls the runtime forms throughout; its `spec`, which only `Signals`
  reads, holds a plain column with the component's content in its place.

### What the runtime frontend emits

There is no engine change for these:
- `pub const Ui = struct { signals: lcgf.signals.Signals(State, spec).Runtime, … }`. It is the comptime page's own state store, so handlers (`ui.signals.set(.f, v)`) are the same code in both frontends.
- `Ui.build(ui, f: *Frame)`, made of `Frame.open`/`close`/`textStyled`/`textfStyled` and the widgets' runtime functions.
- `Ui.dispatch(ui, h)`.
- `Page(H).frame(p, ctx, h, in)`.

## What the compiler needs from main, and when

- **F2 first.** It is emitted already, and `flexitems` waits on it.
- **T1 next.** Without it, no text control can be written in HTML (the `form` fixture).
- **F1 and F4.** They unlock lists and links, the most common HTML after text.
- **The rest, in the plan's P1 order.**

When an entry lands, check it with `zig build markup-pending`. Each of its fixtures then moves to `markup`: delete its `waits_for` in manifest.zon, and switch its rows to `mapped`.
