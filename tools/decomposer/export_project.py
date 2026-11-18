"""Export an already generated page as an independent, editable native Zig package."""

import os
from pathlib import Path
import secrets
import tempfile
import zlib


TEMPLATES = Path(__file__).with_name("export_templates")
HANDLERS_IMPORT = """    const handlers = b.createModule(.{
        .root_source_file = b.path("handlers.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "lcgf", .module = lcgf }},
    });
    page.addImport("handlers", handlers);
"""


def zig_string(value: str) -> str:
    escaped = []
    for c in value:
        if c in ('"', '\\'):
            escaped.append('\\' + c)
        elif ord(c) < 32 or ord(c) == 127:
            escaped.append(f'\\x{ord(c):02x}')
        else:
            escaped.append(c)
    return '"' + ''.join(escaped) + '"'


def export_project(destination: Path, code: str, framework: Path, handlers: Path | None) -> None:
    """Create the project files without replacing any existing destination entry."""
    framework = Path(framework).resolve(strict=True)
    if not all((framework / name).is_file() for name in ("build.zig", "build.zig.zon", "src/lcgf.zig")):
        raise ValueError(f"expected an LCGF package in {framework}")
    destination = Path(destination).expanduser()
    if destination.is_symlink() and not destination.is_dir():
        raise FileExistsError(f"invalid export destination symlink: {destination}")
    destination = destination.resolve()
    files = {"page.zig": code.encode("utf-8")}
    if handlers is not None:
        files["handlers.zig"] = Path(handlers).read_bytes()
    elif '@import("handlers")' in code:
        raise ValueError("this page imports handlers; supply its Zig source with --handlers")

    build = (TEMPLATES / "build.zig").read_text(encoding="utf-8")
    files["build.zig"] = build.replace("    // OPTIONAL_HANDLERS\n", HANDLERS_IMPORT if handlers is not None else "").encode()
    for name in ("test.zig", "README.md"):
        files[name] = (TEMPLATES / name).read_bytes()

    if handlers is not None:
        files["README.md"] += (
            b"\nThe supplied Zig module is copied to `handlers.zig`. It can import `lcgf`. "
            b"If it uses local modules or embedded assets, keep those files at the relative "
            b"paths referenced by your handler.\n"
        )

    # Every exported package is independently editable and has its own Zig identity.
    package = "native_page"
    fingerprint = (zlib.crc32(package.encode()) << 32) | secrets.randbits(32)
    relative = Path(os.path.relpath(framework, destination)).as_posix()
    paths = ", ".join(zig_string(p) for p in sorted([*files, "build.zig.zon"]))
    files["build.zig.zon"] = f""".{{
    .name = .{package},
    .version = "0.0.0",
    .fingerprint = 0x{fingerprint:016x},
    .minimum_zig_version = "0.18.0-dev.1151+8dfb7a7cc",
    .dependencies = .{{ .lcgf = .{{ .path = {zig_string(relative)} }} }},
    .paths = .{{ {paths} }},
}}
""".encode("utf-8")

    destination.parent.mkdir(parents=True, exist_ok=True)
    if not destination.exists():
        # Publish the complete package in one rename when creating a new project.
        with tempfile.TemporaryDirectory(prefix=".decomposer-export-", dir=destination.parent) as tmp:
            staged = Path(tmp) / "project"
            staged.mkdir()
            for name, data in files.items():
                (staged / name).write_bytes(data)
            try:
                staged.rename(destination)
                return
            except OSError:
                if not destination.is_dir():
                    raise

    if not destination.is_dir():
        raise NotADirectoryError(destination)
    # Existing projects may have unrelated files. Create each new entry
    # exclusively, and only undo entries created by this call after a failure.
    for name in files:
        if os.path.lexists(destination / name):
            raise FileExistsError(f"export destination already contains {destination / name}")
    installed = []
    try:
        for name, data in files.items():
            target = destination / name
            with target.open("xb") as output:
                installed.append((target, os.fstat(output.fileno())))
                output.write(data)
    except BaseException:
        for target, before in reversed(installed):
            try:
                if os.path.samestat(target.lstat(), before):
                    target.unlink()
            except FileNotFoundError:
                pass
        raise
