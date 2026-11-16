# The Direct3D 12 back end (src/render/d3d12/) and its tests, cross-compiled for x86_64-windows:
# compile only, so every `all` run keeps it building. ci/jobs/d3d12.sh runs it under Wine.
zig build d3d12
