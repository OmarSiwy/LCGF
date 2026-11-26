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
calls `lcgf.addMarkup`, and `app.zig` with the handlers. `cpp/` and `rust/` run the same page
from C++ and Rust (see "C++ and Rust" below).

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
  <div class="card">
    <span>Counter</span>
    <div class="row">
      <button id="dec" on:click="dec">-</button>
      <span>{count:.0}</span>
      <button id="inc" on:click="inc">+</button>
    </div>
    <label><input type="checkbox" id="step10" bind:checked="by_ten" on:change="step_changed"> Count by ten</label>
    <div class="row">
      <input type="range" id="level" bind:value="level" value="0.5">
      <span>Level {level:.2}</span>
    </div>
    <template lcgf-if="by_ten"><div class="note"><span>Steps of ten</span></div></template>
    <div class="row">
      <template lcgf-each="clicks" lcgf-max="8"><div class="dot"></div></template>
    </div>
  </div>
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
| `<select bind:value="f">` with `<option>`s | A select (`widgets_select.ct.select`); `f` is a `SelectState`, its `.selected` the chosen option's index, which `on:change` gets as a `u32`. `<option selected>` is the default, an option's `label` its caption, and `<optgroup label>` a header in the list. CSS on the `<option>`s lays out every option row and draws its text, the same for each option of a select; `background-color` fills a row that is neither highlighted nor chosen. |
| `<img src="logo.png" alt="Logo">` | A local PNG, decoded by lcgf-gen (or an SVG, drawn at build time by `draw/svg.zig` at the size it is shown, else its own), into the page's `assets` table (`widgets_image.ct.image`). Before the first frame, upload each `assets[k].image.pixels` (premultiplied RGBA8) as texture `assets[k].texture` (k + 1). CSS `width`/`height` in px, else the attributes, give its box; with one side, the other keeps the picture's shape. `object-fit` is `fill` (the default), `contain` or `cover`. `alt` names it; `alt=""` leaves it unnamed. Remote URLs and other formats are errors; an embedded image is at most 512 x 512. |
| `background-image: url(tile.png)` | The asset's texture over the box, stretched to it (as `background-size: 100% 100%`), from the same table; with a `background-color` it is an error, one quad per box. |
| `<div id="info" popover>` with `<button popovertarget="info">` | A popover (`widgets_popover`): the button opens and closes it, and its content floats below the button until a press outside it or Escape. Its state is its `bind:open` bool, else a generated `<id>_open`. The button is named by the popover and takes no `id` or `on:click` of its own. |
| `<menu id="edit" popover>` of `<li><button on:click="undo">Undo</button></li>` with `<button popovertarget="edit">` | A menu button and its menu (`widgets_menu`): the arrows move through the items, and a click or Enter chooses one, which calls its `on:click`. Its state is a generated `MenuState` field `<id>_menu`. A `<menu>` without `popover` is a list. |
| `title="Save the file"` | On a widget (a button or a control): its tooltip, shown once the pointer has rested on it for `widgets_tooltip.delay` and hidden by Escape, over a generated `Tip` field `<id>_tip`. On anything else it is an error. |
| `<dialog bind:open="f">` | A modal dialog of any content while the `bool` `f` is true (`widgets_dialog.ct.dialog`). Escape sets `f` false, Tab stays inside, and the page under it takes no input; `open` makes `f` start true. Close it from a handler with `ui.signals.set(.f, false)`. `dialog::backdrop { background-color: … }` fills the backdrop (`widgets_dialog.dim` by default); ::backdrop takes no other property. |
| `on:click="name"` | Calls `pub fn name(h: *H, ui: *Ui) void`. |
| `on:change="name"` | Calls `pub fn name(h: *H, ui: *Ui, value: T) void` with the new value. On a text field, search field or textarea, `value` is the text (`[]const u8`), reported as it is edited. |
| `on:submit="name"` | On a text field, search field or textarea: calls `pub fn name(h: *H, ui: *Ui) void` on Enter (Ctrl+Enter or Cmd+Enter in a textarea, where Enter adds a line). |
| `<template lcgf-if="f">` | `spec.when` over a `bool`. |
| `<template lcgf-else>` right after it | Both make `spec.choice` over the `bool`: the else content while `f` is false, the if content while it is true. Each template holds one element. |
| `<template lcgf-each="n" lcgf-max="N">` | `spec.list`: up to N copies, `n` (`u32`) of them live. |
| `<template lcgf-each="file in files">` | A run-time region of the comptime page, sized by its CSS; on an axis its CSS leaves to the content (no width or height), it takes the size its items take: the page measures the region without the frame's input, lays itself out again around that size in the same frame, and then builds the region with the input in its final rect, so a click lands where the frame draws it. Content whose size the input changes (a row that grows on hover) takes the new size on the next frame (`out.wake = 0`). `Page.frame(h, in, .{ .files = slice })` builds one copy per item into the region and composes it into the page's draw list. `{file.name}` reads the item, checked against your item type at the HTML location; a click handler inside gets the item's `index: u32`. Inside it, `checked="{file.done}"` (or `value="{file.level}"` on a range) shows an item field one way: the slice may be `[]const T`, and `on:change="toggled"` calls `pub fn toggled(h: *H, ui: *Ui, index: u32, value: bool) void` (the value typed by the control) without writing the item, an intent for the app to apply. A text field there takes `value="{file.name}"` the same way: `on:change` gets `(index, text: []const u8)` as it is edited and `on:submit` gets `(index)`; the region keeps one editor, for the row being edited, seeded from the item when focus moves to it. `bind:checked="file.selected"` (checkbox, switch, toggle, range) and `<template lcgf-if="file.expanded">` bind a field of the item, so per-item view state lives in your data: pass that list as a mutable slice. A page may hold several regions. On a runtime page a region is a node of the page's own `Frame`, clipped as the comptime region is; `Page(H).frame(p, ctx, h, in, data)` and `Ui.build(ui, f, data)` take the items. `lcgf-nodes`/`lcgf-texts` size it (default 256/64). |
| `<template lcgf-switch="mode">` with `<template lcgf-case="a">` | `spec.choice` over a generated enum of the cases. |
| `aria-label="Name"`, `aria-labelledby="a b"` | The node's accessible name; `aria-labelledby` joins the text of the elements with ids `a` and `b`, which must be literal. A text field, search field, textarea, number field, range or progress bar without one is named by its `<label>`'s text. A host with an accessibility bridge calls `ui.semantics(&s)` on a comptime page, or `ui.semantics(tree, &s, &strings)` on a runtime page, after each frame and before `a11y.names`. |
| `id="x"` | The widget's id. Without one, a widget takes its bound field's name, or its click handler's. |

Each name is `[a-z][a-z0-9_]*` and must not be a keyword of Zig, C++ or Rust. That way one page
compiles in every language.

Field types are inferred from where a field is bound, and two bindings must agree. Defaults come
from the HTML: `checked`, `value`, the checked radio. Anything else starts at zero.

A select's list and a dialog are drawn above the page. The compiler moves them last into a new
root, an unpadded column over the viewport that holds the `<body>` and then them, so they float
from the viewport's origin.

## App components

An element whose name has a hyphen (`<sfy-meter>`, anything but `lcgf-*`) is a component of
your app module (`.app` in `addMarkup`), declared in its `pub const components`. A spec
component is `pub fn @"sfy-meter"(comptime theme: lcgf.widgets_base.Theme, comptime props: Props) lcgf.spec.Spec`,
called with the page's `theme`, as in
`tools/lcgf-gen/markup/testdata/components/app.zig`.

`<sfy-meter level="{gain}" caption="Gain"></sfy-meter>` becomes
`app.components.@"sfy-meter"(theme, .{ .level = .gain, .caption = "Gain" })`, inlined into the spec:

- A literal attribute is a string, and `{f}` is the field's name, `.f`.
- Something on the page must type `f`: a control bound to it, text that shows it, or the prop
  itself, written as `{f:f32}` (`str`, `bool`, `f32` or `u32`).
- The element's content is the prop `children: []const lcgf.spec.Spec`. `spec.col` and
  `spec.row` take it as it is.
- `id="zoom"` passes `.id = .zoom`. With `on:click="zoom"`, a click on the widget the
  component gives that id calls your handler. Widgets in the content call theirs as anywhere
  else.
- Under `--runtime-vars=t-`, `pad="var(--t-space)"` passes the token's `Tokens` field name,
  `"space"`. The component gives it to `spec.tokened`, so its Spec reads the caller's table, and a
  changed table (`ui.themeChanged()`) lays it out again on the next frame (`testdata/themed`).
- CSS sets only a component's margins. `aria-label` names it.

Inside `<template lcgf-each="net in nets">`, a component is the runtime form,
`pub fn @"sfy-net"(f: *lcgf.frame.Frame, theme: *const lcgf.widgets_base.Theme, props: anytype) lcgf.types.Response`,
called once per item with `.id` made unique by the item's index and `{net.name}` as the item's value. Its
on:click reads `Response.clicked` and gets the index.

There a component with content is a namespace with `pub fn open(f, theme, props)`, which
builds what goes before the content (and returns the `Response` when on:click reads it), and
`pub fn close(f: *lcgf.frame.Frame, theme: *const lcgf.widgets_base.Theme) void`, which builds
what goes after it. The content is built between the two, as anywhere in the region:
`<sfy-chip mark="#"><span>{net.name}</span></sfy-chip>` in `testdata/components`.

A component used in both places declares both forms under one name, as a namespace:
`pub const @"sfy-tool" = struct { pub fn spec(…) Spec; pub fn frame(f, …) Response; }`.
The page calls `spec`, and a region calls `frame`. The check requires the form each use needs.

Before the spec is built, the generated `checkComponents` checks each component and each prop
against the app's declaration: whether it is present, its type, and props without a default
that the markup does not pass. Each message starts at the HTML:

    page.html:18:5: <sfy-tool> is used inside lcgf-each, so its namespace needs `pub fn frame(f: *lcgf.frame.Frame, th: *const lcgf.widgets_base.Theme, props: anytype) …`

On a runtime page (see Frontends) every component is the runtime form, as inside
`lcgf-each`: `frame`, or `open` and `close` around content. `{f}` passes the field's value and
`var(--t-space)` the token's value, so `level` is an `f32` there where the spec form takes
`@EnumLiteral()`. A component used on both kinds of page declares the forms each needs under one
name (`testdata/components/app.zig`). A margin there is a flex rule on the root the
component builds first, as `spec.flexed` gives it on a comptime page.

## Frontends

By default the page is a comptime page (`ComptimeUi`).

`<html lcgf-frontend="runtime">`, or `--frontend runtime` (`.frontend = "runtime"` in
`addMarkup`), emits it instead as a runtime page:
- `Ui.build(ui, frame)`, made of `Frame`, widget and component calls, and `Ui.dispatch(ui, h)`;
- `Page(H).frame(p, ctx, h, input)`, in your `Context`, sized by the generated `limits`.

CSS on a button, link, toggle, checkbox, switch, range, text control (text, password, search,
number, textarea), progress bar, separator, radio group, select (its button), dialog (its panel) or details
(the section, and its summary the header) restyles it there through the widget's `…Face` function, as `spec.styled`
restyles the comptime one. A focused text control still takes the accent border; unfocused it
shows the CSS border colour, in both frontends. A box-shadow or an outline on one of them
works there too: its column of floating nodes is built around the restyled widget. Margins and
the other flex item rules on a widget or a component go on the row it pushes first, its root.
A margin, gradient, box-shadow or outline on a `<summary>` is an error.
Text CSS (color, font, line-height, …) on a `<button>` draws its caption, in both frontends; a
button does not inherit its parent's, as in a browser. On any other control, or on the
`<label>` that wraps one, text CSS is an error: the control draws its text in the theme's style.

A page with `lcgf-each` regions takes the items in both, as `Ui.build(ui, frame, data)` and
`Page(H).frame(p, ctx, h, input, data)`.

Both keep the same `State` and handlers, because `ui.signals` is the same store in both.
Every fixture draws identical frames in the two frontends. A comptime page snaps a region's
rect and lays its content out on the pixel grid from that corner; the runtime page rounds a
region's content the same way (`lcgf.layout.snapSubtree` in its `Ui.end`), so the two agree
when a region's origin falls between pixels.

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

## C++ and Rust

A page in the subset the C seam's tables carry also builds from C++ and Rust. `lcgf-gen` lowers
it to the `.zon` spec those bindings read (docs/guide/bindings.md) and generates from that, so
the output is what the `.zon` file would give:

```sh
lcgf-gen ui/page.html --lang zon                  # the lowered spec, for inspection
lcgf-gen ui/page.html --lang cpp -o page.lcgf.hpp --depfile page.d
```

```cmake
lcgf_add_ui(app ui/counter.html)       # counter.lcgf.hpp; the depfile reruns it on HTML or CSS edits
```

```rust
lcgf::include_ui!("ui/counter.html");  // a tool error is a compile_error! naming the HTML line
```

The subset:

- Containers such as `<div>`, as rows and columns. Their CSS may set what the seam's styles
  hold: size, minimum and maximum size, padding, gap, alignment, background, border, radius,
  opacity and clipping. The cascade, classes and custom properties resolve at build time, as
  for Zig.
- Text: a literal, `{field}` or a format such as `Level {level:.2}`, in the theme's text style.
- `<button>` with a literal or `{field}` caption, `<input type=checkbox>` with `bind:checked`,
  `<input type=range>` (0 to 1) with `bind:value`.
- `<template lcgf-if="f">` over one element, and `<template lcgf-each="n" lcgf-max="N">`.
- State fields of type string, bool, f32 and u32. A literal caption becomes a string field
  named `<id>_text`, because the seam's buttons and checkboxes show a field.

Anything else is an error at its HTML location, for example:

    page.html:6:5: error: <input type=text> is not in the seam's widget tables (C++/Rust); use the Zig frontend

The errors cover headings, landmarks such as `<main>`, other form controls, `lcgf-else`,
`lcgf-switch`, `lcgf-each="x in xs"`, components, accessible names, text styles (`color` and
`font-size` on text), CSS on a button, checkbox or text node, margins, theme overrides
(`--lcgf-*`) and run-time tokens.

C++ and Rust have no handler type. The app polls the frame's events
(`ui.events().clicked(counter::Widget::inc)`, `frame.events.clicked(counter::Widget::Inc)`) and
writes state through the generated setters. The seam's widgets behave like the reference
widgets, not the Zig frontend's widgets, in two ways. Tab skips buttons. A slider reports its
event on each change while it is held, not when it is released. Draw lists are the same:
`bindings/check/run.sh` replays the example page in Zig's spec frontend, in Zig through the
seam, in C++ and in Rust, and compares them.

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

Backgrounds: a colour, `url(local.png)`, or a gradient. A two-colour `linear-gradient` or
`radial-gradient(circle …)` is a quad feature (`features.linear`, `features.radial`). One with
more colours, or with stops away from the ends, becomes a 256-texel ramp row in the asset
table (`features.rampPixels`, uploaded with the images) drawn by `features.linearRamp` or
`features.radialRamp`. Stop positions are percentages; a radial gradient without a radius
takes the farthest corner of a box with a px size. Ellipses and conic gradients are errors.
`display: grid` is `spec.grid` over the grid passes (layout/grid.zig). Tracks take px, em, rem,
`fr`, `auto`, `minmax()`, `fit-content()` and `repeat(n, …)`; `grid-template-areas`,
`grid-area: name`, `grid-column`/`grid-row` (`N`, `N / M`, `span K`), `grid-auto-rows`,
`grid-auto-flow`, both gaps and the `justify-`/`align-` items, self and content keywords are
lowered. Rows past the template are added for the children that need them. Not yet:
`repeat(auto-fill)`, named lines, `%` tracks and a line on one axis only. Flex rules
(margins, wrap, align-self) apply around and inside grids. A control directly in a cell needs a `<div>` around it on runtime pages.

Positioning: `relative` is a translate (`right` and `bottom` move the other way). `absolute`
floats the box at its parent's content box: `top`/`left` are its offset, `right`/`bottom`
anchor it to that edge (`spec.anchored`), and `left: 0; right: 0` with no width makes it as
wide as the parent (`top`/`bottom` alike). `fixed` anchors the box to the viewport. `sticky`
with `top` holds the box that far below the top of the viewport (`spec.sticky`); scroll
containers are not lowered yet. Fixed and sticky boxes paint above the in-flow ones, and
`z-index` N from 0 to 254 on a positioned box paints it and its subtree above that, in layer
N + 1 (`spec.layer`); absolute and relative boxes with `z-index: auto` keep tree order. Clicks
go to the widget painted on top.

A `<table>` is a grid of `fit` columns, one per cell of its widest row. Each `<tr>` is a row
grid that shares the table's columns (`grid.Decl.subgrid`), so the cells line up and the row
keeps its node. The roles are `table`, `row`, `cell` and `column_header` (`row_header` for
`<th scope="row">`); `colspan` spans columns. `<thead>`, `<tbody>` and `<tfoot>` hand their
rows to the table. Rows are static: `rowspan`, `<caption>`, `<col>` and a template among the
rows are errors.

Lengths are folded to px: `em` and `rem` from the resolved font size, `in`, `cm`, `mm`, `pt` and
`pc` at 96 px per inch.

### Fonts

Each `@font-face` is one row of the page's font table, `pub const fonts` (`lcgf.font_match.Face`):
family, weight, style and a vendored file, `src: url("inter-bold.ttf")`, relative to the sheet
and written relative to the page. Remote and `local()` sources are errors, and the file is a
depfile entry. Row k is font k + 1; font 0 is the theme's.

`font-family`, `font-weight` and `font-style` are resolved at build time with
`font_match.find`, the CSS Fonts 4 order, into `TextStyle.font`. The first family in the list
that has a face wins; a generic family (`sans-serif`, `monospace`, …) is the theme's font, and a
list where neither is found is an error. The UA sheet makes `<b>` and `<strong>` bold, `<i>` and
`<em>` italic and `<code>` and `<pre>` monospace, so a page without `@font-face` is unchanged.
The host loads `fonts[k].path` as the shaper or atlas of font `fonts[k].entry.font`
(`testdata/fonts`).

### Paragraph styles

`line-height` (`normal`, a number, a length or a percentage), `letter-spacing`,
`word-spacing` and `text-overflow: ellipsis` become the label's `spec.paragraph`
(`text_stack.Paragraph`). Both frontends measure those labels with
`protocol.MonoParagraphs`, and the host draws them with its `quads`; a page without them
measures with plain `Mono` and carries no paragraph rows (`testdata/paragraphs`). A host with
real fonts ends a runtime page with `f.endTextStyled(stack, ascent, ui.styled(), rows, rects)`
instead of `ui.end`, and the same styles, decorations and inline runs go through its shaper.
Styled labels work inside `lcgf-each` too: on a comptime page each region keeps its own rows
and ends its frame with `endParagraphs` (`testdata/files`).

`text-decoration` (`underline`, `overline`, `line-through`, a colour) applies to the text inside
the element, adding up with its ancestors' (`none` removes none), as in CSS. It becomes
`spec.decorated` (`text_decorations.Style`), and both frontends paint it after the run's text
as solid quads, one per line (`MonoParagraphs.decorate`). The UA sheet underlines `<u>` and
`<ins>` and strikes `<s>` and `<del>` (`testdata/decorations`).

### Inline runs

A `<p>` of text and phrasing elements (`span`, `strong`, `b`, `em`, `i`, `code`, `small`,
`mark`, …, nested or not) is one paragraph: one label whose text is all of it, white space
collapsed across the elements, with a style run (`spec.spans`, `protocol.Span`) at every change
of size, colour or font. It wraps as one paragraph, each byte in its run's size and colour
(`MonoParagraphs`), and a line is as tall as its largest size (`testdata/inline`). A
`text-decoration` on part of it (`<u>`, `<s>`, a styled span) draws under that part only
(`Span.decoration`). The paragraph has one paragraph style, set on the `<p>`: spacing that
changes inside it is an error, and so is bound text, whose length is only known at run time
while the runs' byte offsets are fixed at build time. Other elements inside it are errors too.

## What is not lowered

Anything the compiler does not lower is an error at its source line, in GNU format, at most 20
per run. Nothing is silently dropped. That includes a declaration that wins the cascade on an element whose
lowering never reads it (`select { width: 200px }`, a property of an element that has no box of
its own): the error names the element. The flex container properties (`flex-direction`,
`justify-content`, …) on a box that is not `display: flex` do nothing, as in CSS.

`lcgf-gen --mappings` lists every decision with its status:

- **mapped**: lowered today.
- **pending**: lowered onto engine API that docs/plans/markup-engine-api.md specifies and the
  engine has not landed yet. Margins are one.
- **planned**: not lowered yet, for example `:hover`, `@media` and `<select>`.
- **rejected**: not modelled by design:
  - scripts and `on*` attributes, where you write `on:click="name"` instead;
  - remote stylesheets;
  - quirks mode;
  - media elements;
  - `order` and reversed flex directions, which change the visual order but not the focus
    order.
