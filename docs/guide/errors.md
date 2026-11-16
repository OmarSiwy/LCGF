# Compile errors and their fixes

Much of what other GUI libraries report at run time is a compile error here: a widget id used
twice, a binding to a field that does not exist, a widget left out of a switch, a type that is
not a back end. This page lists the messages, what causes each and how to fix it.

Every message below is checked. Each one ends with the expected message of a compile-error case:
`docs/guide/errors/*.zig`, which `zig build docs` compiles and requires to fail with that
message, or `src/comptime/compile_fail/*.zig`, which `zig build ct-compile-fail` does the same
for. Those files are also the smallest program that produces each error. Names such as
`missing_field.State` are the type names the compiler prints for the case's own state struct;
in your program they are your types.

## The comptime spec (`validate.check`)

`validate.check(State, spec, options)` walks the spec once and stops at the first broken rule.
Every message about a node starts with its path: the root's kind, then each node's kind and its
position among its parent's children, counting from 0.

```text
col > slider[0]: state missing_field.State has no field 'volum'
col > label[0]: state missing_field_label.State has no field 'tilte'
```

A binding names a field the state struct does not have, usually a typo. A declaration with that
name does not count; it must be a field. Fix the enum literal (`.volume`) or add the field.

```text
col > slider[0]: slider 'volume' needs an f32 field, not bool
row > checkbox[0]: checkbox 'muted' needs a bool field, not f32
col > col[2] > row[1] > slider[3]: slider 'gain' needs an f32 field, not u8
```

A slider shows and sets an `f32`; a checkbox a `bool`. Change the field's type, or bind the
widget to a field of the right type and keep the other one in sync yourself (a derived field,
below, does that).

```text
col > row[1] > checkbox[0]: duplicate widget id 'volume', first used at col > slider[0]
```

Widget ids become the tags of the generated `Widget` enum, so each is used once. When a component
is used twice, give it the ids as parameters (`docs/guide/comptime.md`, "Components are
functions").

```text
col > row[0] > slider[1]: slider 'volume' has no accessible name; give it one with spec.named(..., "Name")
row > checkbox[0]: checkbox 'mute' has no accessible name; give it one with spec.named(..., "Name")
```

Interactive widgets need the name a screen reader says for them, and an empty name is no name.
Wrap the node: `s.named(s.slider(.volume, .volume), "Volume")`. A UI that is never shown to an
assistive technology may pass `.{ .require_names = false }`.

```text
row: needs at least 616x40 px, the viewport is 480x272
col > col[1]: content needs 128 px along y, the node is 100 px and does not clip
```

With `.viewport` set (a fixed screen), the fixed sizes must fit: the whole UI in the viewport,
and each fixed-size node's content in the node unless it clips. Shrink the content, let the node
grow (`.fit`, `.fill`), or set `.clip = true` on a node that scrolls.

```text
state must be a struct, not u32
```

The state is a struct of fields; wrap a single value in one.

## Signals: derived fields and setters

```text
derived fields of derived_cycle.State form a cycle
derived field 'gain' reads itself
```

A derived field's inputs, followed through other derived fields, must not lead back to it. Make
one of the fields in the loop a plain field that you set.

```text
derived field 'gain' needs compute: fn (*const derived_compute.State) f32
```

`compute` takes the state by `*const` pointer and returns exactly the field's type.

```text
'gain' is derived; set its inputs instead
```

`Runtime.set` and `stage` refuse a derived field: it would be overwritten by the next change to
its inputs. Set the inputs it is computed `from`.

```text
state signal_missing_field.State has no field 'volum'
```

`Signals` reports a binding to a missing field itself, for specs that did not go through
`validate.check`. Run `validate.check` first for a message with the node's path.

## Events and widgets

```text
switch must handle all possibilities
```

A switch over `Events(spec).Widget` (or a signals `Effect`) must name every tag; the note under
the error says which one is unhandled, here `'volume'`. This is the point of generating the
enum: adding a widget to the spec finds every place that has to handle it. Add the prong, or an
explicit `else` where ignoring new widgets is right.

```text
two shortcuts on key 22 with the same modifiers
```

`Events.Shortcuts` builds a perfect hash over the chords, and one chord cannot activate two
widgets. Change the key or the modifiers of one of them.

```text
label 'volume' needs a []const u8 field, not f32
```

In `ComptimeUi` a label shows a string field. Bind it to a string field of the state, or show
the number with a widget that takes it, such as a slider.

## Memory

```text
expected type '[]align(64) u8', found '*[4096]u8'
```

`Context.init` takes a buffer aligned to `mem.column_align` (64 bytes, a cache line), so every
column starts on a cache line. Declare it with the alignment:
`var buffer: [Context.requiredBytes(limits)]u8 align(lcgr.mem.column_align) = undefined;`.

## Back ends and shells

```text
not_a_shell.MyShell is not a shell: missing `wait` (src/shell/iface.zig)
not_a_back_end.MyBackEnd is not a render back end: missing `drawText` (src/render/iface.zig)
```

Shells and back ends are checked at compile time instead of implementing an interface. Add the
missing declaration; the file named in the message lists every declaration and its signature
(`docs/guide/porting.md`). The wgpu back end checks its binding the same way
(``wgpu binding is missing `NAME` ``, `src/render/wgpu/wgpu.zig`, `Binding`).

## Zig 0.18 rules that catch code written for older Zig

The project pins Zig 0.18.0-dev.1151+8dfb7a7cc; `docs/ZIG_0_17_1.md` lists everything that
changed. These are the errors met most often:

```text
expected 'bitpack', found 'packed'
```

`packed struct` and `packed union` are now `bitpack struct` and `bitpack union`.

```text
ambiguous operator precedence with operators ... << ... | ...; use parentheses to disambiguate
```

Mixing `<<` or `>>` with `|` or `&`, or `/` with `%`, needs parentheses: `(texture << 16) | material`.
The note under the error says how Zig 0.17 read the expression; the parentheses keep that meaning.

```text
function parameter shadows declaration of 'lanes'
```

No local or parameter may have the name of a declaration in the same file. Rename the local, or
give the top-level alias another name (`prototype/ui.zig` uses `W` for `simd.lanes`).

```text
extern structs cannot contain fields of type '@Vector(4, f32)'
```

Rows that cross to the GPU (`Quad`) are `extern struct`s with `[4]f32` fields; load them into
vectors in locals.

One more is a build option, not code: `-Dlanes` must be a power of two
(`src/core/simd.zig` stops with "-Dlanes must be a power of two").
