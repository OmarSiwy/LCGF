# The comparison driver's fast build against its safe build, on every frame of every scene. In
# a fast build the style calls are inlined into the scenes and a node without extras takes the
# short way through push, finalize and paint; the safe build calls, and asserts on each such
# node that the short way gives what the rows give. Both must hash to the same draw list.
zig build vs-lcgf -Dcpu=x86_64_v3
for scene in form list text springs resize idle; do
    fast=$(zig-out/bin/vs-lcgf --digest --scene "$scene")
    safe=$(zig-out/bin/vs-lcgf-safe --digest --scene "$scene")
    echo "$fast"
    [ "$fast" = "$safe" ] || { echo "the safe build differs: $safe" >&2; exit 1; }
done
