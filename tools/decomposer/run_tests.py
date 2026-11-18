"""Run host test suites using the exact parser produced by the build graph."""
import os
from pathlib import Path
import subprocess
import sys
import unittest

if __name__ == "__main__":
    parser = str(Path(sys.argv[1]).resolve())
    directory = Path(__file__).resolve().parent
    os.environ["DECOMPOSER_PARSER"] = parser
    subprocess.run([sys.executable, directory / "test_parser.py", parser], check=True)
    subprocess.run([sys.executable, directory / "test_export.py", "--zig", sys.argv[2],
                    "--pkg-dir", str(Path(sys.argv[3]).resolve().parent)], check=True)
    loader = unittest.TestLoader()
    suite = unittest.TestSuite(loader.discover(str(directory), pattern=path.name)
                               for path in sorted(directory.glob("test_*.py"))
                               if path.name not in {"test_parser.py", "test_export.py"})
    sys.exit(not unittest.TextTestRunner(verbosity=1).run(suite).wasSuccessful())
