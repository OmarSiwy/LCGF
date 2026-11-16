# all: no
# runner: macos
# What only macOS can show, on a macOS runner: the Metal back end on the real device (its
# job draws every render conformance scene with metal-play and compares it with its golden
# when uname is Darwin), and the AccessKit bridge's tests linked against AppKit and
# AccessKit's macOS library. Linux checks the same code by cross-compiling (ci/jobs/metal.sh).
echo "-- metal"
source ci/jobs/metal.sh
echo "-- accesskit"
zig build accesskit --summary all
