# Post-release work

## HTML and CSS to Zig

The proposed build-time tool translates markup to the framework's existing Zig widget
builders. It uses Zig declarations for application state, event handlers and effects.
Individual HTML aliases and direct widget names share one mapping. CSS selectors resolve
to widget styles and theme values during generation.

- Classify fixed widget trees, bounded choices and lists, and runtime regions. Preserve
  application field types. Select generated index and count widths from known bounds.
- Support custom drawing through a named Zig callback receiving WebGPU handles on a
  capable host. Compute the custom-row budget from the actual page.
- Export a relocatable Zig project into a user-selected directory. Compile and replay
  that project independently and compare it to the source application's generated UI.

The plan covers 42 widget modules, six API gaps, design decisions and acceptance
fixtures. [Markup design](docs/plans/markup.md)
