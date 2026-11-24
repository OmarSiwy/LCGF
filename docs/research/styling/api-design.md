# API design: applying Casey Muratori's work

This is a design constraint for future styling implementation, not a new public API. No production signature changes are included in this research branch. The capability inventory describes outcomes; it must not be translated mechanically into a manager, object hierarchy, or one enormous style struct.

## What was studied

The primary reference is Muratori's [Designing and Evaluating Reusable Components (2004)](https://caseymuratori.com/blog_0024), republished with the original audio synchronized to slides in 2014. His introduction identifies integration discontinuities as the central problem. The linked [lecture recording](https://www.youtube.com/watch?v=ZQ5_u8Lgvyk) could not be played or retrieved completely in this research environment; this report does not claim an end-to-end viewing or a verified transcript.

The directly readable primary material studied alongside it was:

- [The Worst API Ever Made](https://caseymuratori.com/blog_0025): write realistic caller code before selecting an implementation; examine the unnecessary work an interface forces on its users.
- [Complexity and Granularity](https://caseymuratori.com/blog_0016): preserve the smaller operations underneath useful high-level calls so unusual requirements do not force a wholesale rewrite.
- [Semantic Compression](https://caseymuratori.com/blog_0015): derive reusable operations from concrete working code and actual repeated meaning, instead of inventing an object model before solving the problem.
- [Immediate-Mode Graphical User Interfaces (2005)](https://caseymuratori.com/blog_0001): the author's original presentation introduction and API motivation. The linked recording was not fully accessible either.
- Official Handmade Hero chapter guides for [day 011](https://guide.handmadehero.org/code/day011/) and [day 474](https://guide.handmadehero.org/code/day474/): platform boundary design and practical granularity discussions. Chapter descriptions are supporting navigation, not a substitute for a complete transcript.

The five-axis vocabulary below is also recorded in the repository's existing system API-design guide and in [Chris Hecker's participant summary](https://www.chrishecker.com/API_Design). Hecker's indexed summary was available, but its live page returned a temporary-down message. The concrete LCGF recommendations are our application of these ideas, not quotations or claims that Muratori reviewed LCGF.

## Five questions for every proposed styling API

| Axis | Question for LCGF | Consequence to test in usage code |
|---|---|---|
| Granularity | Can the caller replace one operation without replacing the entire widget, frame pipeline, or renderer? | A convenience control can be expanded into the same interaction, geometry, text, and paint operations; custom text or decoration does not require reimplementing its input behavior. |
| Redundancy | Are there convenient paths for common tasks as well as flexible paths for uncommon ones? | Keep direct values, reusable recipes and standard control calls where each saves real caller work. Do not force every simple caller through the most general path. |
| Coupling | What unrelated decisions does this operation force? | Drawing a border should not require a stylesheet parser, theme manager, platform window, allocator, global registry, or a particular text shaper. |
| Retention | Which facts are retained, who owns them, and who must synchronize copies? | Borrow immutable inputs where useful; expose result rows. Optional caches have explicit lifetimes and invalidation. Avoid requiring applications to mirror an existing resource manager or semantic state. |
| Flow control | Who decides when work happens and in what order? | The application sequences style resolution, measurement, layout, paint, effects and submission, supplies time and storage, and owns the event loop. Helpers may run a common sequence without making it mandatory. |

These are tradeoff questions, not five scores to maximize independently. Low-level calls alone can be tedious. An indiscriminately retained system can manufacture synchronization work; an entirely uncached one can repeat expensive shaping. Convenience and optional retention are useful when they preserve the caller's alternatives.

## Start with callers, not a style-system object

Before adding public declarations, write the following consumer scenarios using existing functions wherever possible. Identify the exact missing operation at each point. The named steps below describe required behavior, not proposed Zig symbols.

### 1. One ordinary control with direct values

The application supplies a label, rectangle or normal layout inputs, fill, border and text values. It owns the text bytes and existing frame buffers. It can paint this control without registering a theme, acquiring style IDs, constructing a cache, or allocating heap memory inside the styling path.

First write the direct sequence. Then write the convenient control call over the same operations. The simple path should not need to understand gradients, clip chains, filters or design tokens it never uses. This scenario constrains minimum setup cost and compulsory dependencies.

### 2. A styled control with a custom part

A button has normal, hovered, pressed, selected and keyboard-focus state. Selection changes its outline; pressing changes its fill; keyboard focus adds a visible ring. Its label is a rich-text run or an application-provided icon rather than a plain string.

The caller must be able to retain the existing click/keyboard behavior and replace only the content or decoration. It must not have to copy the entire button implementation or register a virtual subclass. Per-property merging must preserve unrelated effects from simultaneous states. Local direct overrides remain available.

Use the same operation sequence once with a standard label and once with the custom content. Only after both work should a shared recipe or helper be extracted. This is the key defense against an integration discontinuity at the first unusual widget.

### 3. A theme change that preserves meaning

Two semantic roles initially have the same color. An unrelated literal happens to have that color too. Switching themes changes each role independently and leaves the literal unchanged. A child's explicit transparent value remains transparent; a separate inherited value follows its parent.

Write a direct resolution call with caller-supplied inputs, output and scratch. Then demonstrate an optional caller-owned cache producing equivalent results. The cache must not become the only supported route, and token identity must not be reconstructed from final RGBA values. Only dependencies that actually changed should invalidate their consumers.

### 4. An application with its own text and rendering pipeline

An editor already owns a font collection, shaped-run cache, texture resources and render loop. It wants LCGF's control interaction and layout, an existing HarfBuzz adapter or its own shaping integration, and an inline technical canvas.

It must be able to supply measurement/results and sequence the existing passes without mirroring all resources into an obligatory second manager. Transform, clipping, opacity and conservative bounds must apply coherently to the custom content, with explicit responsibility at the boundary. Keep the current fine-grained `Frame.finish` route while adding useful completion helpers.

### 5. A bounded embedded build and an effects-heavy desktop build

The embedded caller uses fixed buffers and a small advertised feature subset. Unsupported effects are diagnosed or receive a deliberately selected fallback. The desktop caller can request isolated groups and effects, with host-owned surface storage and explicit limits.

Both callers should reuse applicable low-level operations. The embedded caller should not carry per-node fields or dependencies for features it does not select. The desktop caller should receive resource requirements or commands it can schedule, without surrendering its frame loop to hidden callbacks or threads. Runtime capacity failure must be visible and deterministic.

## Representations and retention: provisional decisions

The following are design hypotheses to validate against those callers:

1. Keep direct typed values and explicit patches as a basic path. A reusable theme or recipe is optional input data, not a required global service.
2. Lower rich authoring data into compact layout, text and paint inputs. Use uncommon side tables or borrowed spans where the actual use justifies them. Do not expand the 32-byte `Look` or 136-byte `Quad` casually.
3. Preserve fine-grained passes. A high-level helper should make a common sequence easy and remain replaceable by a short, documented sequence of public operations.
4. Allow retained resources and caches when their cost is useful. State ownership, mutation visibility, generation rules and reference lifetime must be explicit. Do not require a handle for a value that can safely be passed directly.
5. Keep compile-time and runtime authoring aligned in semantics. Compile-time generation may reduce capacities and strip unused features; it should not silently interpret the same option differently.
6. Prefer caller-consumed result/event rows for effects and animation lifecycle. The no-runtime-callback rule comes from LCGF's own design; it is not presented as a universal prohibition from Muratori.
7. Treat a property catalog as documentation/compile-time metadata initially. A runtime registry should appear only if real caller examples demonstrate why it is necessary.

An immediate-mode API does not require discarding every internal cache. Likewise, Muratori's retention axis is not a mandate to forbid retained data. The useful question is whether retention reduces total caller work or creates duplicated facts and synchronization obligations.

## Review gate before a public API change

- Show the caller code for at least two actual uses and identify the problem the new operation removes.
- Show the ordinary one-control path and a customization path. Neither may depend on irrelevant subsystems.
- Show how to expand a new convenience into existing lower-level calls, or explain the exact new primitive needed.
- Identify every retained fact, its authoritative owner, lifetime and update rule. A direct uncached path remains usable where the operation permits it.
- State buffer capacities, borrowing rules, invalid input behavior and overflow results. Verify the no-hidden-allocation contract in the affected core path.
- Show which passes the caller may replace or reorder safely, and which dependencies constrain their order.
- Keep UI behavior, semantic accessibility state and visual styling aligned without duplicate contradictory state.
- Measure performance only after an equivalent-output implementation exists. Neither an API diagram nor the name of a design principle establishes a speedup.

The first implementation should solve the theme-identity control and the transformed/clipped labeled card described in the main report. Expand the public vocabulary as concrete examples expose missing operations. The large inventory is a research map, not permission to design every public type in advance.
