# Post-release work

## Comprehensive styling

Research against commit `ed94db3da27882ef1c87d0dd15a382b4df39e2c2` catalogs existing
support and proposed extensions across paint, text, layout, themes, parts, states,
motion, accessibility and optional composition. Follow the usage-first API review
based on Casey Muratori's original material before changing public signatures.

Start with semantic token identity and explicit values, shared transform/clip/paint
bounds, capability reporting, and supported paths through the existing advanced
text/layout operations. Broader decoration and optional effects follow those contracts.
The research is a proposed backlog; it does not add runtime support.

[Findings](docs/research/styling/README.md) ·
[Capability inventory](docs/research/styling/inventory.md) ·
[Implementation sequence](docs/research/styling/implementation-plan.md) ·
[API review](docs/research/styling/api-design.md)

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
