# The styling gallery (examples/styling): the one program that draws with the styling modules
# end to end. It must render the image docs/styling/ shows (tools/golden/golden.py: no pixel off
# by more than 2), and the token authoring regressions must pass. The gallery had stopped
# running on main with no job to say so.
mkdir -p zig-out
zig build styling-check styling-gallery -Dgallery-output="$PWD/zig-out/styling-gallery.png"
python3 tools/golden/golden.py zig-out/styling-gallery.png docs/styling/gallery.png
