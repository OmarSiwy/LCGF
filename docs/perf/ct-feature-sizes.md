# Comptime renderer feature sizes

`ci/run.sh ct-feature-sizes` links three stripped x86-64 Linux shared libraries with the baseline CPU and ReleaseSmall. Each exports the same paint function, stock WGSL pointer and atlas pointer. The paint function takes a draw list at runtime, so the compiler retains the software renderer paths selected by the spec.

| Spec | ELF bytes | .text bytes | .rodata bytes |
| --- | ---: | ---: | ---: |
| Plain solid rectangles | 14,048 | 6,489 | 5,088 |
| Rounded panel with a border and the caption “Settings” | 19,416 | 9,604 | 6,813 |
| Custom widget, every renderer feature available | 71,384 | 47,855 | 20,088 |

Measured with Zig `0.18.0-dev.1151+8dfb7a7cc`. The caption fixture packs the seven distinct byte cells in “Settings” into 112 coverage bytes. The full fixture includes all 256 cells of the same atlas (4,096 bytes). The shader and atlas are part of the read-only-data measurement. CI checks that each specialized library has less code, read-only data and total file size than the full library.
