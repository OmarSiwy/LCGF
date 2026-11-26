#!/bin/sh
# zigonly.sh <runs> <label>: per-frame counters of the Zig ct pipeline ("zig" line), pinned, R=100 minus R=0.
PERF=/nix/store/aimqccjpiwq49lvffnra8zxb8rmwjs67-perf-linux-7.0.10/bin/perf
S=/tmp/claude-1000/ct-research/src; R=100
for r in $(seq $1); do for ui in settings todo dash mixer; do for mode in zig engine; do
 c() { taskset -c 3 $PERF stat -x, -e instructions:u,cycles:u,branches:u,branch-misses:u $S/zig-out/bin/lcgf-ct-dump $ui 240 --bench $mode $1 2>&1 >/dev/null | awk -F, '/instructions|cycles|branches|branch-misses/{printf "%s ", $1}'; }
 ns=$(taskset -c 3 $S/zig-out/bin/lcgf-ct-dump $ui 240 --bench $mode 50 2>&1 | awk '{print $(NF-1)}')
 a=$(c $R); b=$(c 0)
 echo "$r $ui $mode $ns $a| $b" | awk -v R=$R '{split($0,p,"|"); n=split(p[1],x," "); split(p[2],y," "); printf "%s %s %-7s ns=%s ins=%.0f cyc=%.0f br=%.0f miss=%.1f\n", x[1],x[2],x[3],x[4], (x[5]-y[1])/(R*240),(x[6]-y[2])/(R*240),(x[7]-y[3])/(R*240),(x[8]-y[4])/(R*240)}'
done; done; done
