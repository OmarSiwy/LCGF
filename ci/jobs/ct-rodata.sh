# Comptime flatten tables live in read-only data (plan C0134). src/comptime/rodata_probe.zig
# exports one ro_* function per table, each reading it at a run-time row; every relocation an
# ro_* function makes must point into a .rodata* section. rw_control reads a mutable copy and
# must point into .data or .bss, so a check that cannot tell the two apart fails too.
# x86-64 only: the relocation names are ELF x86-64's.
for opt in ReleaseSmall ReleaseFast; do
    zig build ct-rodata -Doptimize="$opt" -Dtarget=x86_64-linux
    objdump -dr zig-out/ct_rodata.o | awk -v opt="$opt" '
        /^[0-9a-f]+ <.*>:$/ { fn = $2; gsub(/[<>:]/, "", fn); next }
        /R_X86_64_/ {
            sec = $3; sub(/[+-].*/, "", sec)
            if (fn ~ /^ro_/) { n_ro[fn]++; if (sec !~ /^\.rodata/) { print opt ": " fn " reads " sec; bad = 1 } }
            if (fn == "rw_control" && sec ~ /^\.(data|bss)/) rw = 1
        }
        END {
            split("ro_parent ro_end ro_depth ro_level_order ro_level_start", want, " ")
            for (k in want) if (!n_ro[want[k]]) { print opt ": " want[k] " reads no table"; bad = 1 }
            if (!rw) { print opt ": rw_control does not read writable data"; bad = 1 }
            if (bad) exit 1
            printf "%s: %d tables in .rodata, control in writable data\n", opt, length(n_ro)
        }'
done
