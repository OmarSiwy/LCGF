#!/bin/sh
# m2.sh <runs> <name=cmd-with-UI-and-REPS-placeholders>... ; pinned core 3, per-frame counters (R=100 minus R=0)
PERF=/nix/store/aimqccjpiwq49lvffnra8zxb8rmwjs67-perf-linux-7.0.10/bin/perf
runs=$1; shift
for r in $(seq $runs); do for ui in settings todo dash mixer; do for spec in "$@"; do
 name=${spec%%=*}; tmpl=${spec#*=}
 mk() { echo "$tmpl" | sed "s/@UI@/$ui/g; s/@R@/$1/g"; }
 c() { taskset -c 3 $PERF stat -x, -e instructions:u,cycles:u,branches:u,branch-misses:u $(mk $1) 2>&1 >/dev/null | awk -F, '/instructions|cycles|branches|branch-misses/{printf "%s ", $1}'; }
 ns=$(taskset -c 3 $(mk 50) 2>&1 | tail -1 | awk '{print $(NF-1)}')
 a=$(c 100); b=$(c 0)
 echo "$r $ui $name $ns $a| $b" | awk '{split($0,p,"|"); n=split(p[1],x," "); split(p[2],y," "); printf "%s %s %-9s ns=%s ins=%.0f cyc=%.0f br=%.0f miss=%.1f\n", x[1],x[2],x[3],x[4], (x[5]-y[1])/24000,(x[6]-y[2])/24000,(x[7]-y[3])/24000,(x[8]-y[4])/24000}'
done; done; done
