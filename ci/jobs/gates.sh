# Release gates (docs/GATES.md, bench/gates/): the gate logic's self-test, which shows a regressed
# gate failing. The gates that need every comparison framework run in gates-vs (not in all).
python3 bench/gates/gates.py --self-test
# Binary size per example against bench/gates/recorded.json. Target and CPU are fixed so the
# bytes are the same on every machine.
mkdir -p zig-out/gates
zig build size -Dtarget=x86_64-linux -Dcpu=x86_64_v3 > zig-out/gates/size.txt
python3 bench/gates/gates.py size zig-out/gates/size.txt
