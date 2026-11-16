# Sizes of the web examples' wasm modules, ReleaseSmall (src/render/web/size.py): bytes, gzip
# and the code and data sections. layout.wasm is the "layout alone" probe to set against Clay's
# README (about 15 kB). Prints only; no budget yet.
zig build web
python3 src/render/web/size.py zig-out/web/*.wasm
