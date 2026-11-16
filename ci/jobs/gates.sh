# Release gates (docs/GATES.md, bench/gates/): the gate logic's self-test, which shows a regressed
# gate failing. The gates that need every comparison framework run in gates-vs (not in all).
python3 bench/gates/gates.py --self-test
