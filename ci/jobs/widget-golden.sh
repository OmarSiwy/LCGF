# shell: golden
# all: no
# Golden images of the reference widgets (tools/golden/): each frame of the widget replay
# is run through both front ends (which must agree), drawn by tools/golden/gpu.py on Mesa
# lavapipe and compared with tools/golden/ref/widgets/<frame>.png.
for ref in tools/golden/ref/widgets/*.png; do
    frame=$(basename "$ref" .png)
    out=zig-out/widgetgolden/$frame
    zig build widget-dump -- "$frame" "$PWD/$out"
    python3 tools/golden/gpu.py "$out" "$out/frame.png"
    python3 tools/golden/golden.py "$out/frame.png" "$ref"
done
