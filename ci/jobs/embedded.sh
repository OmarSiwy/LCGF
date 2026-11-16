# The embedded profile's demo (examples/embedded/demo.zig): its test runs here, and it is linked
# freestanding for a Cortex-M7 and an RV32IMAC. No emulator is in the dev shell, so the images
# are linked, not run. Each must fit the budget: flash (every loaded section but .bss, unwind
# tables included) at most 64 KiB, LVGL's documented minimum flash class (LVGL 9.5 "Requirements"), and
# static RAM (.data and .bss) at most 48 KiB, LVGL's recommended heap. And none may contain the
# standard library's I/O, OS or debug code.
zig build embedded --summary all
for f in zig-out/bin/embedded-demo-cortex-m7 zig-out/bin/embedded-demo-rv32imac; do
    size -A "$f" | awk -v f="$f" '
        $3 > 0 && $1 !~ /bss/ { flash += $2 }
        $3 > 0 && $1 ~ /^\.(s?data|s?bss)/ { ram += $2 }
        END {
            printf "%s: flash %d bytes (budget 65536), RAM %d bytes (budget 49152)\n", f, flash, ram
            if (flash > 65536 || ram > 49152) { print "over budget"; exit 1 }
        }'
    if nm -C "$f" | grep -E " std\.(Io|debug|posix|fs|os|heap|Thread|process)\."; then
        echo "$f links the standard library's I/O, OS or debug code"
        exit 1
    fi
done
