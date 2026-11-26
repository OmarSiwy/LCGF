#!/bin/sh
# Usage: measure.sh <runs> <uis...>. Pinned to core 3. Prints one line per (run, ui, impl):
# ns/frame (best of 50 reps x 240 frames, harness timer) and perf counters per frame
# (difference between reps=R and reps=0, divided by R*240).
PERF=/nix/store/aimqccjpiwq49lvffnra8zxb8rmwjs67-perf-linux-7.0.10/bin/perf
S=/tmp/claude-1000/ct-research/src; W=/tmp/claude-1000/ct-research/work
R=100
runs=$1; shift
cmd() { # impl reps
  case $1 in
    zig) echo "$S/zig-out/bin/lcgf-ct-dump $ui 240 --bench zig $2";;
    engine) echo "$S/zig-out/bin/lcgf-ct-dump $ui 240 --bench engine $2";;
    cpp) echo "env LCGF_REPS=$2 $W/cpp/lcgf-cpp-ct-check $ui 240 --bench";;
    cppsm) echo "env LCGF_REPS=$2 $W/cpp/lcgf-cpp-ct-check $ui 240 --bench seam";;
    rust) echo "env LCGF_REPS=$2 $W/rust/release/lcgf-ct-check $ui 240 --bench";;
    rustsm) echo "env LCGF_REPS=$2 $W/rust/release/lcgf-ct-check $ui 240 --bench seam";;
  esac
}
cnt() { taskset -c 3 $PERF stat -x, -e instructions:u,cycles:u,branches:u,branch-misses:u $(cmd $1 $2) 2>&1 >/dev/null | awk -F, '/instructions|cycles|branches|branch-misses/{printf "%s ", $1}'; }
for r in $(seq $runs); do
  for ui in "$@"; do
    for impl in zig engine cpp cppsm rust rustsm; do
      ns=$(taskset -c 3 $(cmd $impl 50) 2>&1 | awk '{print $(NF-1)}')
      a=$(cnt $impl $R); b=$(cnt $impl 0)
      echo "$r $ui $impl $ns $a| $b" | awk -v R=$R '{split($0,p,"|"); n=split(p[1],x," "); split(p[2],y," "); printf "%s %s %-7s ns=%s ins=%.0f cyc=%.0f br=%.0f miss=%.1f\n", x[1],x[2],x[3],x[4], (x[5]-y[1])/(R*240),(x[6]-y[2])/(R*240),(x[7]-y[3])/(R*240),(x[8]-y[4])/(R*240)}'
    done
  done
done
