# System font discovery for the fallback chain on Linux (src/text/fallback/fontconfig.zig):
# renders the mixed-script sample from fontconfig's fonts, then checks that every font found is
# the one fontconfig's own fc-match gives for that character: the first TrueType font of its
# sorted sans-serif list whose charset has it.
# libfontconfig is opened at run time; point the loader at the one fc-list uses (on NixOS it is
# in no default search path).
lib=$(ldd "$(command -v fc-list)" | awk '/libfontconfig/ {print $3}')
export LD_LIBRARY_PATH="$(dirname "$lib")${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
out=$(zig build fallback-system 2>&1) || { echo "$out"; exit 1; }
found=$(echo "$out" | grep '^U+')
echo "$found"
[ "$(echo "$found" | wc -l)" -eq 4 ]
echo "$found" | while read -r cp file index; do
    want=$(fc-match -s "sans-serif:charset=${cp#U+}" -f '%{fontformat}\t%{file}\n' | awk -F'\t' '$1 == "TrueType" && !n++ {print $2}')
    [ "$file" = "$want" ] || { echo "$cp: found $file, fc-match gives $want"; exit 1; }
done
# The window layer's text service (src/app/text.zig) with the system's default faces, and a
# face found for each character of its sample they lack: every glyph drawn, none .notdef.
zig build app-text-system
