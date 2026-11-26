#!/bin/sh
# Instruction-count parity of the runtime front end: each scene of bindings/check/run.sh's
# runtime section built in C++ and Rust against the same scene built in Zig, per frame.
#
#   bindings/check/parity.sh <prefix> <work> [rounds]
#
# <prefix> holds lcgf-rt-dump (zig build abi), <work> the gate's C++ and Rust builds
# (cpp/lcgf-cpp-rt-check, rust/release/lcgf-rt-check). A frame's cost is
# (count at $HI frames - count at $LO frames) / ($HI - $LO), so start-up cancels; each tool
# runs `rounds` times (default 5), interleaved, and the median is kept. It prints
# instructions:u and cycles:u per frame and the ratio to Zig, and fails when an instruction
# ratio is above $LCGF_PARITY_MAX (default 1.05). Cycles are printed only: they move with the
# machine. Without perf, or without user-space counters (a VM), it says so and passes.
# Each frame includes the dump's copy of the draw list, the same bytes in every language.
#
# Written exceptions, a scene's own bar (still a bar: a regression past it fails):
# - canvas 1.07: an 8,600-instruction frame, where the C++ and Rust frame's fixed calls
#   (lcgf_context_begin, lcgf_frame_view, lcgf_frame_end, the canvas options built per node)
#   weigh 5-6% (C++ 1.055 on main a49dc73c, before abi-gen). Removing them is A5's (Input and
#   Output in C form) and A7's work.
set -eu
prefix=$1 work=$2 rounds=${3:-5}
hi=${LCGF_PARITY_HI:-1200} lo=${LCGF_PARITY_LO:-200} max=${LCGF_PARITY_MAX:-1.05}
pin=${LCGF_PARITY_PIN:-}
perf=${PERF:-perf}
if ! command -v "$perf" >/dev/null || ! "$perf" stat -x, -e instructions:u true 2>&1 >/dev/null | grep -q '^[0-9]'; then
    echo "skip parity: no user-space instruction counter (perf stat -e instructions:u)"
    exit 0
fi
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# count <event> <frames> <cmd...>: the event's user-space count for one run.
count() {
    ev=$1 n=$2; shift 2
    $pin "$perf" stat -x, -e "$ev" -o "$tmp/stat" "$@" "$n" "$tmp/out.bin" >/dev/null
    grep -v '^#' "$tmp/stat" | grep -m1 . | cut -d, -f1
}

median() { sort -n | awk '{a[NR]=$1} END {print a[int((NR+1)/2)]}'; }

fail=0
printf '%-8s %-5s %12s %12s %8s %8s\n' scene lang insns/frame cycles/frame insns× cycles×
for scene in form list text springs resize idle kit canvas; do
    for lang in zig cpp rust; do : >"$tmp/$lang.i"; : >"$tmp/$lang.c"; done
    r=0
    while [ $r -lt "$rounds" ]; do
        for lang in zig cpp rust; do
            case $lang in
            zig) set -- "$prefix/bin/lcgf-rt-dump" "$scene" ;;
            cpp) set -- "$work/cpp/lcgf-cpp-rt-check" "$scene" ;;
            rust) [ -x "$work/rust/release/lcgf-rt-check" ] || continue
                set -- "$work/rust/release/lcgf-rt-check" "$scene" ;;
            esac
            for ev in instructions:u cycles:u; do
                a=$(count $ev "$hi" "$@") b=$(count $ev "$lo" "$@")
                echo $(( (a - b) / (hi - lo) )) >>"$tmp/$lang.$(echo $ev | cut -c1)"
            done
        done
        r=$((r + 1))
    done
    zi=$(median <"$tmp/zig.i") zc=$(median <"$tmp/zig.c")
    for lang in zig cpp rust; do
        [ -s "$tmp/$lang.i" ] || continue
        i=$(median <"$tmp/$lang.i") c=$(median <"$tmp/$lang.c")
        ri=$(awk -v a="$i" -v b="$zi" 'BEGIN {printf "%.3f", a / b}')
        rc=$(awk -v a="$c" -v b="$zc" 'BEGIN {printf "%.3f", a / b}')
        printf '%-8s %-5s %12d %12d %8s %8s\n' "$scene" "$lang" "$i" "$c" "$ri" "$rc"
        m=$max
        case $scene in canvas) m=1.07 ;; esac
        if awk -v r="$ri" -v m="$m" 'BEGIN {exit !(r > m)}'; then fail=1; echo "parity: $scene $lang $ri > $m" >&2; fi
    done
done
if [ $fail = 1 ]; then
    echo "parity: an instruction ratio is above $max" >&2
    exit 1
fi
echo "ok   runtime parity: every scene within ${max}x of Zig's instructions per frame (canvas 1.07), C++ and Rust"
