#!/bin/sh
# Select the Vulkan ICD before running. The control detects an inactive validation layer.
set -eu
probe=${1:?usage: validate.sh path/to/custom-draw-projection}
export VK_INSTANCE_LAYERS=VK_LAYER_KHRONOS_validation VK_LAYER_VALIDATE_SYNC=1
logs=$(mktemp -d)
trap 'rm -rf "$logs"' EXIT
for mode in check projection nohandoff; do
    if ! "$probe" "$mode" > "$logs/$mode" 2>&1; then
        cat "$logs/$mode" >&2
        exit 1
    fi
done
for mode in check projection; do
    cat "$logs/$mode"
    if grep -Eiq 'Validation Error|VUID-|SYNC-HAZARD' "$logs/$mode"; then exit 1; fi
done
grep -q 'frames=6 redraws=5 px_different=0' "$logs/check"
grep -q 'frames=2000 redraws=2000' "$logs/projection"
# Validation layers 1.4.363 report the stale layout as VUID-vkCmdDraw-imageLayout-00344;
# older ones as VUID-VkDescriptorImageInfo-imageLayout-00344.
grep -Eq 'VUID-vkCmdDraw-None-08114|VUID-[A-Za-z]+-imageLayout-00344|SYNC-HAZARD' "$logs/nohandoff"
echo 'Validation detected the deliberately omitted image handoff.'
