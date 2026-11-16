# Comptime flatten tables (plan C0134) and constant column tables (C0145) live in read-only data. src/comptime/rodata_probe.zig
# exports one ro_* function per table, each reading it at a run-time row; every relocation an
# ro_* function makes must point into a .rodata* section. rw_control reads a mutable copy and
# must point into .data or .bss, so a check that cannot tell the two apart fails too.
# x86-64 only: the relocation names are ELF x86-64's. A relocation may name a section or a local
# symbol (Zig 0.18 names `.Lcomptime...` symbols); symbols are resolved to their section through
# the symbol table, and a name that maps to more than one section counts as unknown.
for opt in ReleaseSmall ReleaseFast; do
    zig build ct-rodata -Doptimize="$opt" -Dtarget=x86_64-linux
    { objdump -t zig-out/ct_rodata.o | sed -n 's/^[0-9a-f]* [^.]*\(\.[^ \t]*\)\t[0-9a-f]* \([^ ]*\).*/SYM \2 \1/p'
      objdump -dr zig-out/ct_rodata.o; } | awk -v opt="$opt" '
        $1 == "SYM" { k = ($3 ~ /^\.rodata/) ? ".rodata" : $3
                      if (($2 in where) && where[$2] != k) where[$2] = "?ambiguous"; else where[$2] = k; next }
        /^[0-9a-f]+ <.*>:$/ { fn = $2; gsub(/[<>:]/, "", fn); next }
        /R_X86_64_/ {
            sec = $3; sub(/[+-].*/, "", sec)
            if (sec in where) sec = where[sec]
            if (fn ~ /^ro_/) { n_ro[fn]++; if (sec !~ /^\.rodata/) { print opt ": " fn " reads " sec; bad = 1 } }
            if (fn == "rw_control" && sec ~ /^\.(data|bss)/) rw = 1
        }
        END {
            split("ro_parent ro_end ro_depth ro_level_order ro_level_start ro_col_pad ro_col_gap ro_col_look", want, " ")
            for (k in want) if (!n_ro[want[k]]) { print opt ": " want[k] " reads no table"; bad = 1 }
            if (!rw) { print opt ": rw_control does not read writable data"; bad = 1 }
            if (bad) exit 1
            printf "%s: %d tables in .rodata, control in writable data\n", opt, length(n_ro)
        }'
done
