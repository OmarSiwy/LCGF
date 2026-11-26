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
| `<template lcgf-if="f">` | `spec.when` over a `bool`. |
| `<template lcgf-each="n" lcgf-max="N">` | `spec.list`: up to N copies, `n` (`u32`) of them live. |
| `<template lcgf-switch="mode">` with `<template lcgf-case="a">` | `spec.choice` over a generated enum of the cases. |
| `id="x"` | The widget's id. Without one, a widget takes its bound field's name, or its click handler's. |

Each name is `[a-z][a-z0-9_]*` and must not be a keyword of Zig, C++ or Rust. That way one page
compiles in every language.

Field types are inferred from where a field is bound, and two bindings must agree. Defaults come
from the HTML: `checked`, `value`, the checked radio. Anything else starts at zero.

## Frontends

By default the page is a comptime page (`ComptimeUi`).

`<html lcgf-frontend="runtime">`, or `--frontend runtime` (`.frontend = "runtime"` in
`addMarkup`), emits it instead as a runtime page:
- `Ui.build(ui, frame)`, made of `Frame` and widget calls, and `Ui.dispatch(ui, h)`;
- `Page(H).frame(p, ctx, h, input)`, in your `Context`, sized by the generated `limits`.

Both keep the same `State`, `spec` and handlers, because `ui.signals` is the same store in both.
Every fixture draws identical frames in the two frontends.

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
