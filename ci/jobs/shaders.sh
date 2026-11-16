# shell: golden
# all: no
# Every shader variant (src/render/shaders/quad.zig `variants`) validated by naga and built into
# the quad pipeline on a real wgpu device (Mesa lavapipe).
zig build shaders-dump
out=zig-out/shaders; rm -rf "$out"
zig-out/bin/shaders-dump "$out"
python3 src/render/shaders/validate.py "$out"
