"""Account linked MCU sections using ELF allocation flags; addresses may start at zero."""
import re
import subprocess
import sys

FLASH_LIMIT = 64 * 1024
RAM_LIMIT = 48 * 1024
SECTION = re.compile(
    r"^\s*\[\s*\d+\]\s+(\S+)\s+(\w+)\s+[\da-fA-F]+\s+[\da-fA-F]+\s+"
    r"([\da-fA-F]+)\s+[\da-fA-F]+\s+([A-Z]*)\s+\d+\s+\d+\s+\d+\s*$"
)


def footprint(table):
    flash = ram = 0
    for line in table.splitlines():
        match = SECTION.match(line)
        if not match:
            continue
        _, kind, size, flags = match.groups()
        if "A" in flags:
            n = int(size, 16)
            if kind != "NOBITS":
                flash += n
            if "W" in flags:
                ram += n
    if flash == 0:
        raise ValueError("ELF has no allocated, file-backed sections")
    return flash, ram


def within(flash, ram):
    return flash <= FLASH_LIMIT and ram <= RAM_LIMIT


def self_test():
    # Addresses start at zero on some boards. Unnamed/custom writable sections
    # must count, initialized RAM needs a flash image, and debug stays on the host.
    table = """
    [ 1] .text PROGBITS 00000000 000100 000010 00 AX  0 0 4
    [ 2] .rodata PROGBITS 00000010 000110 000020 00 A  0 0 4
    [ 3] .board.values PROGBITS 00008000 000130 000004 00 WA 0 0 4
    [ 4] .board.pixels NOBITS 00008004 000134 000100 00 WA 0 0 4
    [ 5] .debug_info PROGBITS 00000000 000134 ffffff 00    0 0 1
    """
    assert footprint(table) == (52, 260)
    assert within(FLASH_LIMIT, RAM_LIMIT)
    assert not within(FLASH_LIMIT + 1, RAM_LIMIT)
    assert not within(FLASH_LIMIT, RAM_LIMIT + 1)


def main(args):
    if args == ["--self-test"]:
        self_test()
        return 0
    if not args:
        raise SystemExit("usage: budget.py --self-test | ELF...")
    ok = True
    for path in args:
        sections = subprocess.check_output(["readelf", "-SW", path], text=True)
        flash, ram = footprint(sections)
        print(f"{path}: flash {flash}/{FLASH_LIMIT} bytes, static RAM {ram}/{RAM_LIMIT} bytes")
        ok &= within(flash, ram)
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
