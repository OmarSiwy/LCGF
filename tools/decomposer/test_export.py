"""Test exporting a package and building the exported module with the project's Zig."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

from export_project import export_project

FRAMEWORK = Path(__file__).resolve().parents[2]
ZIG = "zig"
PKG_DIR = None

PAGE = """const lcgf = @import("lcgf");
const State = struct { caption: []const u8 = CAPTION };
const theme: lcgf.widgets_base.Theme = .default;
pub const spec = lcgf.spec.col(.{ .size = .{ .fill, .fill } }, .{lcgf.widgets_label.ct.label(theme, .caption)});
pub const Ui = lcgf.widgets_base.ComptimeUi(State, spec, theme);
pub const Page = struct {
    ui: Ui = .{},
    pub fn frame(self: *@This(), input: *const lcgf.input.Input) Ui.Output {
        return self.ui.frame(input);
    }
};
"""


def build(directory):
    cmd = [ZIG, "build", "test", "-j2"]
    if PKG_DIR:
        cmd += ["--pkg-dir", str(PKG_DIR)]
    subprocess.run(cmd, cwd=directory, check=True)


class ExportTest(unittest.TestCase):
    def test_native_packages(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            handlers = root / "source.zig"
            handlers.write_text('pub const caption = "From Zig";\n', encoding="utf-8")
            for source in (None, handlers):
                with self.subTest(handlers=source is not None):
                    code = PAGE.replace("CAPTION", '@import("handlers").caption' if source else '"Literal"')
                    destination = root / ("with handlers" if source else "static")
                    export_project(destination, code, FRAMEWORK, source)
                    self.assertEqual((destination / "page.zig").read_text(), code)
                    if source:
                        self.assertEqual((destination / "handlers.zig").read_bytes(), source.read_bytes())
                    else:
                        self.assertFalse((destination / "handlers.zig").exists())
                    self.assertIn(os.path.relpath(FRAMEWORK, destination).replace(os.sep, "/"),
                                  (destination / "build.zig.zon").read_text())
                    build(destination)

    def test_existing_directory_and_collisions(self):
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp)
            keep = destination / "notes.txt"
            keep.write_text("existing")
            export_project(destination, PAGE.replace("CAPTION", '"Literal"'), FRAMEWORK, None)
            self.assertEqual(keep.read_text(), "existing")
            manifest = (destination / "build.zig.zon").read_bytes()
            (destination / "page.zig").write_text("edited")
            with self.assertRaises(FileExistsError):
                export_project(destination, "new code", FRAMEWORK, None)
            self.assertEqual((destination / "page.zig").read_text(), "edited")
            self.assertEqual((destination / "build.zig.zon").read_bytes(), manifest)

    def test_missing_inputs_do_not_create_project(self):
        with tempfile.TemporaryDirectory() as tmp:
            destination = Path(tmp) / "export"
            with self.assertRaises(ValueError):
                export_project(destination, PAGE.replace("CAPTION", '@import("handlers").caption'), FRAMEWORK, None)
            with self.assertRaises(FileNotFoundError):
                export_project(destination, PAGE, FRAMEWORK, Path(tmp) / "missing.zig")
            self.assertFalse(destination.exists())


if __name__ == "__main__":
    args = argparse.ArgumentParser(description=__doc__)
    args.add_argument("--framework", type=Path, default=FRAMEWORK)
    args.add_argument("--zig", default=ZIG)
    args.add_argument("--pkg-dir", type=Path)
    config = args.parse_args()
    FRAMEWORK = config.framework.resolve()
    ZIG = config.zig
    PKG_DIR = config.pkg_dir.resolve() if config.pkg_dir else None
    unittest.main(argv=[__file__])
