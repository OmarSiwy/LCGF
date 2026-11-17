"""Reject floating-point instructions and runtime helpers in the fixed-panel MCU build."""
import argparse
import re
import subprocess
from pathlib import Path

# ARM's EABI names encode the source and destination of conversions, e.g.
# __aeabi_ui2f and __aeabi_d2iz. Ordered comparisons also have __aeabi_cd* wrappers.
ARM_HELPER = re.compile(r"__aeabi_(?:[df]\w*|c[fd]cmp\w*|c[fd]rcmp\w*|u?[il]2[fd])$")
# Compiler-rt / libgcc binary floating modes: half, bfloat, single, double and extended.
MODE = r"(?:hf|bf|sf|df|xf|tf|kf)"
FLOAT_HELPER = re.compile(r"__(?:add|sub|mul|div|neg|powi|cmp|unord|eq|ne|lt|le|gt|ge|trunc|extend|float|fix)\w*" + MODE + r"\w*$")
GNU_HALF = re.compile(r"__gnu_(?:f2h|h2f)_(?:ieee|alternative)$")
OP = re.compile(r"^\s+([a-z][a-z\d.]*)\s*(?:\s|$)")
ARM_FP_COPROCESSOR = re.compile(r"\bp(?:10|11)\b", re.IGNORECASE)


def float_op(arch, op, line):
    if arch == "arm":
        # Thumb Cortex-M7 has VFP and no integer NEON. Older assemblers also
        # spell the FPA/VFP operations with f-prefixed aliases or p10/p11.
        return op.startswith(("v", "f")) or (
            op.startswith(("mrc", "mcr", "mrrc", "mcrr", "cdp", "ldc", "stc"))
            and ARM_FP_COPROCESSOR.search(line) is not None
        )
    # RV32 integer fences share their initial letter with floating instructions.
    # Strip the compressed prefix so c.flw, c.fldsp and their stores are included.
    mnemonic = op.removeprefix("c.")
    return (mnemonic.startswith("f") and mnemonic.split(".")[0] != "fence") or mnemonic.startswith(("vf", "vmf"))


def check(arch, assembly, symbols):
    findings = []
    instructions = 0
    for line in assembly.splitlines():
        match = OP.match(line)
        if match:
            instructions += 1
            if float_op(arch, match[1], line):
                findings.append(line.strip())
    if instructions == 0:
        raise ValueError(f"no {arch} assembly instructions found")
    names = [line.split()[-1] for line in symbols.splitlines() if line.strip()]
    if not names:
        raise ValueError("nm found no symbols")
    findings.extend(n for n in names if ARM_HELPER.search(n) or FLOAT_HELPER.search(n) or GNU_HALF.search(n))
    return findings


def self_test():
    symbols = "00000001 t __aeabi_uidiv\n00000002 t __muldi3"
    assert not check("arm", "\tadds r0, r1\n\t.fpu fpv5-d16\n", symbols)
    assert not check("rv32", "\tadd a0, a0, a1\n\tfence.i\n\tfence rw, rw\n", symbols)
    for name in ("__aeabi_i2f", "__aeabi_ul2d", "__aeabi_d2f", "__aeabi_f2iz",
                 "__aeabi_cdcmple", "__aeabi_cfrcmple", "__addsf3", "__floatunsidf",
                 "__truncdfhf2", "__gnu_h2f_ieee"):
        assert check("arm", "\tmov r0, r1", f"00000020 T {name}") == [name]
    for arch, op in (("arm", "vcvt.f32.s32 s0, s0"), ("arm", "mrc p10, 0, r0, c0, c0, 0"),
                     ("rv32", "fsgnjx.s fa0, fa0, fa1"), ("rv32", "fabs.s fa0, fa1"),
                     ("rv32", "c.flw fa0, 0(a0)"), ("rv32", "vfadd.vv v0, v1, v2")):
        assert check(arch, "\t" + op, symbols) == [op]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--self-test", action="store_true")
    parser.add_argument("arch", nargs="?", choices=("arm", "rv32"))
    parser.add_argument("asm", nargs="?", type=Path)
    parser.add_argument("elf", nargs="?", type=Path)
    args = parser.parse_args()
    if args.self_test:
        self_test()
        return
    if not (args.arch and args.asm and args.elf):
        parser.error("expected arch, emitted assembly and linked ELF")
    symbols = subprocess.check_output(["nm", str(args.elf)], text=True)
    findings = check(args.arch, args.asm.read_text(), symbols)
    if findings:
        raise SystemExit(f"{args.elf} contains floating-point work:\n" + "\n".join(findings))


if __name__ == "__main__":
    main()
