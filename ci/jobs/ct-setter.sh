# The comptime setter is one store and one OR with a constant (plans C0154, C0155, C0157).
# Disassembles src/comptime/setter_probe.zig and requires each setter to be, besides
# frame-pointer setup, the return and alignment padding after it, exactly one store of the
# value through %rdi and the listed ORs of immediates into memory, in order:
#   set_volume  integer mask u8: one OR of 0x15 (the probe's volume mask: slider 4, row 2, root)
#   stage_volume  the batched setter of the same field: the same as set_volume
#   set_far     [4]u32 array mask: one OR per touched word, 0x1 (root) and 0x8 (row 99)
# x86-64 only: AT&T mnemonics.
setter() { # <object> <opt> <function> <immediates...>
    local obj=$1 opt=$2 fn=$3; shift 3
    # By address and size from the symbol table: identical functions may share one body, and
    # objdump labels it with only one of their names.
    local addr size
    read -r addr size < <(objdump -t "$obj" | awk -v fn="$fn" '$NF == fn && $3 == "F" { print $1, $5 }')
    objdump -d --no-show-raw-insn --start-address=$((16#${addr:-0})) --stop-address=$((16#${addr:-0} + 16#${size:-0})) "$obj" | awk -v opt="$opt" -v fn="$fn" -v want="$*" '
        /^ *[0-9a-f]+:\t/ {
            sub(/^ *[0-9a-f]+:\t/, "")
            if (done) next # padding after ret
            n++
            if ($0 ~ /^(push|pop) +%rbp$/ || $0 ~ /^mov +%rsp,%rbp$/) next
            if ($0 ~ /^ret/) { done = 1; next }
            if ($0 ~ /^(mov[a-z]*) +%[a-z0-9]+,(0x[0-9a-f]+)?\(%rdi\)$/) { store++; next }
            if ($0 ~ /^or[bwlq]? +\$0x[0-9a-f]+,(0x[0-9a-f]+)?\(%rdi\)$/) {
                imm = $0; sub(/^or[bwlq]? +\$/, "", imm); sub(/,.*/, "", imm)
                got = got (got == "" ? "" : " ") imm; next
            }
            print opt ": " fn ": unexpected instruction: " $0; bad = 1
        }
        END {
            if (n == 0) { print opt ": " fn " not found"; exit 1 }
            if (store != 1 || got != want) { print opt ": " fn ": " store + 0 " stores, ORs [" got "] (want 1 store, ORs [" want "])"; bad = 1 }
            if (bad) exit 1
            printf "%s: %s is 1 store + ORs of %s (%d instructions)\n", opt, fn, want, n
        }'
}
for opt in ReleaseFast ReleaseSmall ReleaseSafe; do
    zig build ct-setter -Doptimize="$opt" -Dtarget=x86_64-linux
    setter zig-out/ct_setter.o "$opt" set_volume 0x15
    setter zig-out/ct_setter.o "$opt" stage_volume 0x15
    setter zig-out/ct_setter.o "$opt" set_far 0x1 0x8
done
