# Post-release work

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
