# Path golden images: src/draw/paths_golden.zig draws the scenes of src/draw/testdata/paths/,
# check.py compares them with the independent references make.py drew (tools/golden/golden.py).
out=zig-out/paths-golden; mkdir -p "$out"
zig build paths-golden -- "$PWD/$out/images.bin"
python3 src/draw/testdata/paths/check.py "$out/images.bin" "$out"
