# Text layout's display order (src/text/layout/conformance.zig): every BidiCharacterTest line
# broken, placed and reordered by src/text/layout/lines.zig, its glyphs in the file's order.
zig build text-conformance --summary all
zig build text-conformance -Doptimize=ReleaseFast --summary all
