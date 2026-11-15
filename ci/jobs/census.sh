# Branch census (docs/CHECKS.md section 2). The CPU is fixed so codegen is the same everywhere.
# Fails when a function gains a conditional jump over tools/census/baseline.json.
python3 tools/census/census.py --self-test
(cd prototype && zig build census-obj -Dcpu=x86_64_v3)
python3 tools/census/census.py prototype/zig-out/asm_probe.o --baseline tools/census/baseline.json
