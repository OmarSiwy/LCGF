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

The [Decomposer](tools/decomposer/README.md) emits native widget specifications, typed Zig
writers and independently buildable page packages. Its [standards inventory](tools/decomposer/catalog.md)
records supported subsets and the native work needed for each indexed gap.

- Extend the native inline formatting, list, table and grid layouts, with accessibility
  and generated-page tests for each mapping.
- Map additional form controls and events to explicit Zig writers. Preserve the zero-byte
  document state for read-only bindings.
- Expose native bounded choices, lists and runtime regions in markup with typed data and
  concrete capacity limits.
- Support custom drawing through a named Zig callback on a capable host. Compute the
  custom-row budget from the actual page.
- Compare exported and build-generated pages against the same input replay and rendered output.

The [original markup proposal](docs/plans/markup.md) inventories 42 widget modules and six
framework gaps. Its dedicated widget dialect and component syntax are design proposals.
