# Writing a UI in HTML and CSS

`lcgf-gen` compiles an HTML page and its CSS into the Zig a hand-written comptime page would
be. The generated file contains:

- a `Spec` built from `lcgf.spec` and the widgets' `ct` builders;
- the view `State`, with one field per binding;
- the `theme`;
- `ComptimeUi`;
- `Page(H)`, which calls your handlers.

Nothing of HTML or CSS remains at run time. `ci/run.sh markup-zero-cost` checks that each
fixture's generated page compiles to the same machine code as the same page written by hand.

The example is `examples/markup/`: `ui/counter.html`, `ui/counter.css`, a `build.zig` that
calls `lcgf.addMarkup`, and `app.zig` with the handlers.

## Build

In `build.zig`, call `lcgf.addMarkup(b, lcgf_dep, .{ .html = b.path("ui/page.html") })`
and import the module it returns. It returns null while Zig fetches the parser, Lexbor; return
from `build` then.

- `.css = &.{…}` adds stylesheets after the page's own `<link>` and `<style>`.
- `.app = module` gives the page an `app` import.
- `.emit = "src/gen"` also copies the generated file into your sources.
- `.vendored = b.path("src/gen/page_ui.zig")` builds from that copy. The build fails with
  `… is stale: regenerate with zig build -Dmarkup-emit=src/gen` when the copy no longer
  matches the HTML.

The tool writes a depfile, so editing the HTML, a stylesheet or an `@import`ed file reruns it.
Editing only your handlers does not.

To run the tool by hand:

```sh
zig build lcgf-gen                     # zig-out/bin/lcgf-gen, with the HTML front end
lcgf-gen ui/page.html --lang zig -o page_ui.zig --depfile page_ui.d
lcgf-gen --mappings                    # what every element, attribute and property maps to
```

## The page

```html
<!doctype html>
<html lcgf-page="counter">
<head>
  <title>Counter</title>
  <link rel="stylesheet" href="counter.css">
</head>
<body>
  <main>
    <h1>Counter</h1>
    <div class="row">
      <button id="dec" on:click="dec">-</button>
      <span class="count">{count:.0}</span>
      <button id="inc" on:click="inc">+</button>
    </div>
    <label><input type="checkbox" id="step10" bind:checked="by_ten" on:change="step_changed"> Count by ten</label>
  </main>
</body>
</html>
```

| Markup | Meaning |
|---|---|
| `{field}` in text | Shows a string field. |
| `{field:.N}` | Shows an `f32` field with N decimals (0 to 6). Mixed text becomes `spec.text("… {.1} …", .{ .field })`. |
| `{{`, `}}` | A literal brace. |
| `bind:checked="f"` | Two-way `bool` binding (checkbox, `switch`, `aria-pressed` button). |
| `bind:value="f"` | Two-way binding: `f32` for range, `Number` for number, `Text(256)` for text controls. |
| `bind:selected="f"` | A radio group's `u32` index. |
| `on:click="name"` | Calls `pub fn name(h: *H, ui: *Ui) void`. |
| `on:change="name"` | Calls `pub fn name(h: *H, ui: *Ui, value: T) void` with the new value. |
| `on:submit="name"` | On a text field, search field or textarea: calls `pub fn name(h: *H, ui: *Ui) void` on Enter (Ctrl+Enter or Cmd+Enter in a textarea, where Enter adds a line). |
| `<template lcgf-if="f">` | `spec.when` over a `bool`. |
| `<template lcgf-each="n" lcgf-max="N">` | `spec.list`: up to N copies, `n` (`u32`) of them live. |
| `<template lcgf-each="file in files">` | A run-time region of the comptime page, sized by its CSS; on an axis its CSS leaves to the content (no width or height), it takes the size its items took on the previous frame, and a change asks for one more frame (`out.wake = 0`). `Page.frame(h, in, .{ .files = slice })` builds one copy per item into the region and composes it into the page's draw list. `{file.name}` reads the item, checked against your item type at the HTML location; a click handler inside gets the item's `index: u32`. Inside it, `checked="{file.done}"` (or `value="{file.level}"` on a range) shows an item field one way: the slice may be `[]const T`, and `on:change="toggled"` calls `pub fn toggled(h: *H, ui: *Ui, index: u32, value: bool) void` (the value typed by the control) without writing the item, an intent for the app to apply. A text field there takes `value="{file.name}"` the same way: `on:change` gets `(index, text: []const u8)` as it is edited and `on:submit` gets `(index)`; the region keeps one editor, for the row being edited, seeded from the item when focus moves to it. `bind:checked="file.selected"` (checkbox, switch, toggle, range) and `<template lcgf-if="file.expanded">` bind a field of the item, so per-item view state lives in your data: pass that list as a mutable slice. A page may hold several regions; comptime pages only, for now. `lcgf-nodes`/`lcgf-texts` size it (default 256/64). |
| `<template lcgf-switch="mode">` with `<template lcgf-case="a">` | `spec.choice` over a generated enum of the cases. |
| `id="x"` | The widget's id. Without one, a widget takes its bound field's name, or its click handler's. |

Each name is `[a-z][a-z0-9_]*` and must not be a keyword of Zig, C++ or Rust. That way one page
compiles in every language.

Field types are inferred from where a field is bound, and two bindings must agree. Defaults come
from the HTML: `checked`, `value`, the checked radio. Anything else starts at zero.

## App components

An element whose name has a hyphen (`<sfy-meter>`, anything but `lcgf-*`) is a component of
your app module (`.app` in `addMarkup`), declared in its `pub const components`. A spec
component is `pub fn @"sfy-meter"(comptime props: Props) lcgf.spec.Spec`, as in
`tools/lcgf-gen/markup/testdata/components/app.zig`.

`<sfy-meter level="{gain}" caption="Gain"></sfy-meter>` becomes
`app.components.@"sfy-meter"(.{ .level = .gain, .caption = "Gain" })`, inlined into the spec:

- A literal attribute is a string, and `{f}` is the field's name, `.f`.
- Something on the page must type `f`: a control bound to it, text that shows it, or the prop
  itself, written as `{f:f32}` (`str`, `bool`, `f32` or `u32`).
- The element's content is the prop `children: []const lcgf.spec.Spec`. `spec.col` and
  `spec.row` take it as it is.
- `id="zoom"` passes `.id = .zoom`. With `on:click="zoom"`, a click on the widget the
  component gives that id calls your handler. Widgets in the content call theirs as anywhere
  else.
- CSS sets only a component's margins. `aria-label` names it.

Inside `<template lcgf-each="net in nets">`, a component is the runtime form,
`pub fn @"sfy-net"(f: *lcgf.frame.Frame, props: anytype) lcgf.types.Response`, called once per
item with `.id` made unique by the item's index and `{net.name}` as the item's value. Its
on:click reads `Response.clicked` and gets the index. It takes no content yet.

Before the spec is built, the generated `checkComponents` checks each component and each prop
against the app's declaration: whether it is present, its type, and props without a default
that the markup does not pass. Each message starts at the HTML:

    page.html:14:5: component <sfy-tool> is missing from app.components: add `pub fn @"sfy-tool"(comptime props: anytype) lcgf.spec.Spec`

Components are lowered on comptime pages only so far.

## Frontends

By default the page is a comptime page (`ComptimeUi`).

`<html lcgf-frontend="runtime">`, or `--frontend runtime` (`.frontend = "runtime"` in
`addMarkup`), emits it instead as a runtime page:
- `Ui.build(ui, frame)`, made of `Frame` and widget calls, and `Ui.dispatch(ui, h)`;
- `Page(H).frame(p, ctx, h, input)`, in your `Context`, sized by the generated `limits`.

Both keep the same `State`, `spec` and handlers, because `ui.signals` is the same store in both.
Every fixture draws identical frames in the two frontends.

### Run-time theme tokens

With `--runtime-vars=t-` (`.runtime_vars = "t-"` in `addMarkup`), each `var(--t-name)` the page
reads becomes a token instead of being folded at build time. A token is one length or one
colour (hex or a name); its default is the CSS value.

The page then exports `Tokens`, with those defaults, and `ThemeTable`
(`lcgf.theme_table.ThemeTable(Tokens)`). Point `ui.tokens` at your table.

`table.set(.name, value)` bumps the table's generation. `ui.themeChanged()` is then true, and
the next frame lays the page out with the new values. Pages that use no token compile to the
same code as without the option (`ci/run.sh markup-zero-cost`). Both frontends read them: a
comptime page is `ComptimeUiTokens(State, spec, theme, Tokens)` over `spec.tokened` nodes.

## Handlers

Your handler type needs one `pub fn` per name the page uses. `Page(H).frame(h, input)` builds,
lays out and draws. Once the draw list is final, it calls the handlers of that frame's events in
tree order.

A handler writes state through `ui.signals.set(.field, value)`, which keeps the dirty masks
right.

A missing handler or a wrong signature is a compile error that starts at the HTML:

    page.html:10:32: handler 'inc' is missing: add `pub fn inc(h: *App, ui: *Ui) void`

## CSS

The whole cascade runs at build time:

- origins, `@layer`, specificity, `!important`, inline `style`;
- custom properties with `var()` fallbacks;
- type, class, id and attribute selectors;
- the four combinators;
- `:root`, `:first-child`, `:nth-child()`, `:not()`, `:is()`, `:where()` and `:has()`.

Every value is resolved to the framework's own `Style` and `TextStyle`. The user-agent sheet is
the LCGF theme, not a browser's look: unstyled HTML looks like an LCGF page.

The theme is set with tokens on `:root`, and the generated `theme` carries them:
`--lcgf-text`, `-text-px`, `-panel`, `-control`, `-control-hot`, `-control-held`, `-accent`,
`-radius`, `-pad` and `-gap`.

Layout is flexbox on LCGF's passes. Block flow is a column, and these deviations are deliberate:

- Margins do not collapse.
- Boxes size to their content unless `width`, `flex-grow` or `align-items: stretch` says
  otherwise.
- A flex container has one gap.

Lengths are folded to px: `em` and `rem` from the resolved font size, `in`, `cm`, `mm`, `pt` and
`pc` at 96 px per inch.

## What is not lowered

Anything the compiler does not lower is an error at its source line, in GNU format, at most 20
per run. Nothing is silently dropped.

`lcgf-gen --mappings` lists every decision with its status:

- **mapped**: lowered today.
- **pending**: lowered onto engine API that docs/plans/markup-engine-api.md specifies and the
  engine has not landed yet. Margins are one.
- **planned**: not lowered yet, for example `:hover`, `@media`, grid and `<select>`.
- **rejected**: not modelled by design:
  - scripts and `on*` attributes, where you write `on:click="name"` instead;
  - remote stylesheets;
  - quirks mode;
  - media elements;
  - `order` and reversed flex directions, which change the visual order but not the focus
    order.
