#!/usr/bin/env bash
# Regenerates src/render/shaders/gen/: every shader variant (quad.zig `variants`) translated by
# naga-cli 30.0.2 to SPIR-V, MSL, HLSL and GLSL ES 3.0 (.vert and .frag, one file per stage), so back ends and
# library users need no translator. Run in the shaders dev shell from the repository root:
#
#     nix develop .#shaders -c src/render/shaders/translate.sh
#
# ci/jobs/shaders.sh runs it and fails if the committed files differ.
set -euo pipefail
zig build shaders-dump
tmp=zig-out/shaders; rm -rf "$tmp"
zig-out/bin/shaders-dump "$tmp"
gen=src/render/shaders/gen; rm -rf "$gen"; mkdir -p "$gen"
for f in "$tmp"/*.wgsl; do
    v=$(basename "$f" .wgsl)
    naga "$f" "$gen/$v.spv" "$gen/$v.metal" "$gen/$v.hlsl"
    naga --profile es300 --shader-stage vert --entry-point vs "$f" "$gen/$v.vert"
    naga --profile es300 --shader-stage frag --entry-point fs "$f" "$gen/$v.frag"
done
# The WGSL of src/render/gpu/ (shaders written against lcgf_render.gpu): every back end's
# translation, named gpu_<name>. GLSL needs one file per entry point: <name>.<entry>.<stage>.
for f in src/render/gpu/*.wgsl; do
    v=gpu_$(basename "$f" .wgsl)
    naga "$f" "$gen/$v.spv" "$gen/$v.metal" "$gen/$v.hlsl"
    python3 - "$f" <<'PY' | while read -r stage entry ext; do
import re, sys
src = re.sub(r'//[^\n]*', '', open(sys.argv[1]).read())
for stage, ext in (('vertex', 'vert'), ('fragment', 'frag'), ('compute', 'comp')):
    for m in re.finditer(r'@' + stage + r'\b[^{;]*?\bfn\s+(\w+)', src):
        print(stage, m.group(1), ext)
PY
        profile=es300; [ "$ext" = comp ] && profile=es310
        naga --profile "$profile" --shader-stage "$stage" --entry-point "$entry" "$f" "$gen/$v.$entry.$ext"
    done
done
# naga reports some errors (an unknown extension) yet exits 0: check every output exists.
for f in "$tmp"/*.wgsl; do
    v=$(basename "$f" .wgsl)
    for x in spv metal hlsl vert frag; do test -s "$gen/$v.$x" || { echo "missing $gen/$v.$x" >&2; exit 1; }; done
done
for f in src/render/gpu/*.wgsl; do
    v=gpu_$(basename "$f" .wgsl)
    for x in spv metal hlsl; do test -s "$gen/$v.$x" || { echo "missing $gen/$v.$x" >&2; exit 1; }; done
done
