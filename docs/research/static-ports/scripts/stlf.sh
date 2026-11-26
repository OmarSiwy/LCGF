#!/bin/sh
PERF=/nix/store/aimqccjpiwq49lvffnra8zxb8rmwjs67-perf-linux-7.0.10/bin/perf
ev=ls_bad_status2.stli_other:u,ls_stlf:u,de_no_dispatch_per_slot.backend_stalls:u,cycles:u
run() { # n ui reps
  if [ $1 = zig ]; then set -- src/zig-out/bin/lcgf-ct-dump $2 240 --bench zig $3; else set -- env LCGF_REPS=$3 work/rust/release/lcgf-ct-check $2 240 --bench; fi
  taskset -c 3 $PERF stat -x, -e $ev "$@" 2>&1 >/dev/null | awk -F, 'NF>3{printf "%s ", $1}'
}
for ui in mixer settings todo dash; do for n in zig rust; do
  a=$(run $n $ui 100); b=$(run $n $ui 0)
  echo "$ui $n $a | $b" | awk '{printf "%-9s %-5s stli=%.1f stlf=%.1f backend_stall_slots=%.0f cyc=%.0f\n",$1,$2,($3-$8)/24000,($4-$9)/24000,($5-$10)/24000,($6-$11)/24000}'
done; done
