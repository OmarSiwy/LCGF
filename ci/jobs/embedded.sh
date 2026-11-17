# The embedded profile's demo (examples/embedded/demo.zig): its test runs here, and it is linked
# freestanding for a Cortex-M7 and an RV32IMAC. No emulator is in the dev shell, so the images
# are linked, not run. Each must fit the budget: flash (every loaded section but .bss, unwind
# tables included) at most 64 KiB, LVGL's documented minimum flash class (LVGL 9.5 "Requirements"), and
# static RAM (.data and .bss) at most 48 KiB, LVGL's recommended heap. And none may contain the
# standard library's I/O, OS or debug code.
python3 tools/embedded/budget.py --self-test
images=(zig-out/bin/embedded-demo-cortex-m7 zig-out/bin/embedded-demo-rv32imac)
for profile in -Dfixed-point=false -Dfixed-point=true -Dno-float=true; do
    zig build embedded "$profile" --summary all
    python3 tools/embedded/budget.py "${images[@]}"
    for f in "${images[@]}"; do
        if nm -C "$f" | grep -E " std\.(Io|debug|posix|fs|os|heap|Thread|process)\."; then
            echo "$f links the standard library's I/O, OS or debug code"
            exit 1
        fi
    done
done

# The prepainted fixed panel performs only integer work on the MCU.
python3 tools/embedded/no_float.py --self-test
python3 tools/embedded/no_float.py arm zig-out/asm/embedded-cortex-m7.s "${images[0]}"
python3 tools/embedded/no_float.py rv32 zig-out/asm/embedded-rv32imac.s "${images[1]}"

zig build embedded-sim --summary all
