# The comptime setter is one store and one OR with a constant (plan C0154). Disassembles
# set_volume from src/comptime/setter_probe.zig and requires, besides frame-pointer setup and
# the return, exactly one store of the value and one OR of the immediate 0x15 (the probe's
# volume mask: slider 4, its row 2, root 0) into memory. x86-64 only: AT&T mnemonics.
for opt in ReleaseFast ReleaseSmall ReleaseSafe; do
    zig build ct-setter -Doptimize="$opt" -Dtarget=x86_64-linux
    objdump -d --no-show-raw-insn zig-out/ct_setter.o | sed -n '/<set_volume>:/,/^$/p' | awk -v opt="$opt" '
        /^ *[0-9a-f]+:\t/ {
            sub(/^ *[0-9a-f]+:\t/, ""); n++
            if ($0 ~ /^(push|pop) +%rbp$/ || $0 ~ /^mov +%rsp,%rbp$/ || $0 ~ /^ret/) next
            if ($0 ~ /^movss +%xmm0,(0x[0-9a-f]+)?\(%rdi\)$/) { store++; next }
            if ($0 ~ /^orb? +\$0x15,(0x[0-9a-f]+)?\(%rdi\)$/) { or_++; next }
            print opt ": unexpected instruction: " $0; bad = 1
        }
        END {
            if (n == 0) { print opt ": set_volume not found"; exit 1 }
            if (store != 1 || or_ != 1) { print opt ": " store + 0 " stores, " or_ + 0 " ORs (want 1 and 1)"; bad = 1 }
            if (bad) exit 1
            printf "%s: set_volume is 1 store + 1 OR of 0x15 (%d instructions)\n", opt, n
        }'
done
