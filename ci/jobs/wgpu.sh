# shell: golden
# all: no
# The wgpu-native back end (src/render/wgpu/) on Mesa lavapipe: wgpu-native v29 from
# build.zig.zon, its headers translated by build.zig, tests drawing and reading pixels back.
zig build wgpu --summary all
