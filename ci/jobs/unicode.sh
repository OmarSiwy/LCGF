# Unicode 16.0.0 conformance files (src/text/unicode/conformance.zig): grapheme, word and line
# break tests, BidiTest and BidiCharacterTest, and the property tables against the data files.
zig build conformance --summary all
zig build conformance -Doptimize=ReleaseFast --summary all
