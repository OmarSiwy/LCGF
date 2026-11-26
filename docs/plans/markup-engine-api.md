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
| F1 | specified | `types.Role` gains `link = 8, separator = 16, list = 20, list_item = 21, table, row, cell, column_header, row_header, dialog, status`, with the byte values of `a11y.Role` (a11y/tree.zig). Emitted as `.role = .list` on `<ul>`/`<ol>`, `.list_item` on `<li>`, `.status` on `<output>`. | 0, types.zig | lists |
| F2 | emitted | `pub fn flexed(comptime s: Spec, comptime flex: lcgf.flex.Style) Spec`, which sets the new field `Spec.flex: ?flex.Style = null`. ComptimeUi carves the `Flex` columns only when a spec node has one. Runtime: `Frame.flex(f: *Frame, node: Node, flex: *const flex.Style) void`, with `Frame.arrangeWith` running `layout.fitFlex`/`resolveFlex`/`placeFlex`/`wrap.wrap` when any node has one. The compiler emits `s.flexed(x, .{ .margin = .{ l, t, r, b } })` for CSS margins; next it emits `.wrap`, `.cross` (align-self), `.aspect`, `.baseline` and `.lines` (align-content) in the same struct. | 1, spec.zig; 2, base.zig ComptimeUi; 1, frame.zig, context.zig | flexitems |
| F3 | specified | `pub fn variants(comptime s: Spec, comptime field: @EnumLiteral(), comptime styles: []const types.Style) Spec`, which sets `Spec.styles: ?[]const Style` and `Spec.style_field: ?[]const u8`. ComptimeUi pushes `styles[@field(state, field)]`, and `Spec.shows` includes `style_field`, so the signal masks dirty the node. For `class:x="{f}"`, `hidden="{f}"` (Participation.collapsed) and `@media` buckets, it is driven by a generated field. | 1, spec.zig; 2, base.zig | variants |
| F3b | specified | `recipe_comptime.Config`, as button/checkbox use it today (recipe_comptime.zig:27), for number, search, textarea, select, list, tabs, accordion and link. The compiler lowers `:hover`/`:active`/`:focus-visible`/`:checked`/`:disabled` rules on a widget to `.recipe = …`. | 2, theme/recipe_comptime.zig | states |
| F4 | specified | `widgets_link`: runtime `pub fn link(f: *Frame, th: *const Theme, id: Id, text: []const u8) Response`, comptime `ct.link(comptime th: Theme, comptime id: @EnumLiteral(), comptime text: anytype) Spec` with role `link`. It activates on click and Enter. For `<a href>`, with `on:navigate` receiving the href. | 2, new widgets/link.zig | links |
| T1 | specified | `widgets_textfield.ct.textfield`, `widgets_search.ct.search` and `widgets_textarea.ct.textarea` take `comptime hint: anytype`, a string literal or an enum literal naming a field, as `ct.label`'s `text` does. Today `hint` must be a field (`@EnumLiteral()`), so `placeholder="Name"` cannot be written. The compiler emits `textfield.ct.textfield(theme, .name, .name, "Name")`, with state `name: lcgf.widgets_textfield.Text(256)`. | 2, textfield.zig, search.zig, textarea.zig | form |
| T2 | specified | `spec.heading(level, caption)` accepts a `Spec` from `spec.text(...)`, so `<h1>Gain {g:.1} dB</h1>` is one heading: `s.heading(1, s.text("Gain {.1} dB", .{.g}))`. | 1, spec.zig | headings |
| T3 | specified | `widgets_button.ct.button` takes an optional caption text style: `ct.buttonStyled(th, id, text, text_style)`, or `spec.textStyled` reaching the caption label. Today CSS `color`/`font-size` on a `<button>` cannot reach its caption; the compiler drops it with the planned diagnostic. | 2, button.zig | counter |
| F7 | specified | `pub fn grid(comptime style: Style, comptime decl: lcgf.grid.Decl, comptime children: anytype) Spec` and `pub fn cell(comptime s: Spec, comptime area: lcgf.grid.Item) Spec` (Spec fields `grid`, `cell`). ComptimeUi runs `grid.run` (grid.zig:577) in place of the plain sequence when a node has a grid. Runtime: `Frame.openGrid(id, style, decl)`, `Frame.cell(node, item)`. | 1, spec.zig, frame.zig; 2, base.zig | grid |
| F8 | specified | `widgets_base.ct.pressable(comptime id: @EnumLiteral(), comptime style: Style, comptime children: anytype) Spec`, a focusable container whose click is its event (`on:click` on a `<div>`, `tabindex=0`, `:hover` on a box via F3). | 2, base.zig | pressable |
| F10 | specified | `Popover`, `Dialog`, `Select`, `Menu` and `Tooltip` usable as `Spec.widget` nodes inside ComptimeUi, each pushing a floating layer under the root. The compiler emits `dialog.ct.dialog(theme, .id, .open, def)` and `select.ct.select(theme, .id, .field, def)`. | 2, base.zig, popover.zig, dialog.zig, select.zig | dialog |
| F11 | specified | `pub fn runs(comptime style: Style, comptime parts: anytype) Spec`, with parts `run("text", text_style)`, `run(.field, text_style)` and `link(...)`, for mixed phrasing in `<p>`/`<li>`/`<label>`. | 1, spec.zig, frame.zig | paragraphs |
| F12b | specified | `pub fn paragraph(comptime s: Spec, comptime p: lcgf.text_stack.Paragraph) Spec` (Spec field `paragraph`), for line-height, multi-line text-align, letter- and word-spacing, ellipsis and line clamp. | 1, spec.zig; 2, base.zig | paragraphs |
| F17 | specified | `pub fn anchored(comptime s: Spec, comptime a: lcgf.overlay.Anchor) Spec`, `sticky(s, top: f32)` and `layer(s, order: i16)`, for right/bottom/inset/fixed, `position: sticky` and z-index on floats. | 1, spec.zig, frame.zig | positioned |
| F18 | specified | No framework change. The generated `Page.frame` filters the focused widget's `Input.events` for `on:keydown:enter`/`:escape`/`:space` and arrows. | generated code | keys |

| R1 | specified | The runtime widget functions take an optional style, as `s.styled` restyles a comptime widget: `button.buttonStyled(f, th, id, text, style) Response`, and the same for every control. The runtime frontend emits it for a widget whose CSS changes its look; today that page fails with the planned diagnostic `runtime-widget-style`. | 2, every widget's runtime function | runtime |
| R2 | specified | An accessible name on a built node: `Frame.name(f: *Frame, node: Node, name: []const u8) void`, and `ComptimeUi` writing `Spec.name` into the same column. Today neither frontend carries `aria-label` into the tree, so the runtime emitter omits it. | 1, frame.zig; 2, base.zig | landmarks |

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
