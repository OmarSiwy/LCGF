# shell: golden
# all: no
# The GL ES back end (src/render/gles/) on Mesa llvmpipe: its tests run on a real GL ES driver
# through the platform's EGL (libglvnd dispatching to Mesa, surfaceless, in this shell).
zig build gles --summary all
