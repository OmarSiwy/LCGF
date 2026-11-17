# Release gates (docs/GATES.md, bench/gates/): the gate logic's self-test, which shows a regressed
# gate failing. The gates that need every comparison framework run in gates-vs (not in all).
python3 bench/gates/gates.py --self-test
# Binary size per example against bench/gates/recorded.json. Target and CPU are fixed so the
# bytes are the same on every machine.
mkdir -p zig-out/gates
zig build size -Dtarget=x86_64-linux -Dcpu=x86_64_v3 > zig-out/gates/size.txt
python3 bench/gates/gates.py size zig-out/gates/size.txt
# Idle (target D5): frames built while nothing changes, and wake-ups once idle, of the
# benchmark's idle scene (the LCGF row of the comparison).
zig build vs-lcgf
{ zig-out/bin/vs-lcgf --scene idle; python3 tools/bench/probe.py -- zig-out/bin/vs-lcgf --idle --scene idle; } > zig-out/gates/idle.txt
cat zig-out/gates/idle.txt
python3 bench/gates/gates.py idle zig-out/gates/idle.txt
# Input-to-photon latency of the example in the headless shell (bench/gates/latency.zig).
zig build gates-latency > zig-out/gates/latency.txt
python3 bench/gates/gates.py latency zig-out/gates/latency.txt
# Compile time of the comptime front end for specs of 100, 1,000 and 10,000 nodes.
python3 bench/gates/gates.py compile-time
# Branches in hot loops: the census jobs gate the census object; this checks every probe is in it.
python3 bench/gates/gates.py census
# The published table (bench/gates/README.md) is the recorded one.
python3 bench/gates/gates.py table
