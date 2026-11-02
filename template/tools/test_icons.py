#!/usr/bin/env python3
"""Tests for tools/icons.py, against a stand-in sketchtool that writes files named
the way the real one does.
"""

import contextlib
import io
import os
import sys
import tempfile
import unittest
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).parent))
import icons  # noqa: E402

FAKE_SKETCHTOOL = """#!/usr/bin/env python3
import sys
from pathlib import Path

args = dict(a.split("=", 1) for a in sys.argv[3:] if "=" in a)
if args.get("--trimmed") != "NO":
    sys.exit("exported trimmed")
out = Path(args["--output"])
if sys.argv[2] == "layers":
    folder = out / " Device & Service Icon Template 3.0 "
    folder.mkdir(parents=True)
    for name in ("experience_1024", "device_sm"):
        (folder / f" {name}.png").write_text(args["--item"])
elif args["--items"] != "Finite Labs Logo":
    (out / f"{args['--items']}.png").write_text(args["--items"])
"""


class IconsTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        tool = self.root / "sketchtool"
        tool.write_text(FAKE_SKETCHTOOL)
        tool.chmod(0o755)
        self.sketch = self.root / "Driver Icons.sketch"
        self.sketch.write_text("")
        env = mock.patch.dict(os.environ, {"SKETCHTOOL": str(tool)})
        env.start()
        self.addCleanup(env.stop)

    def run_icons(self, *extra):
        out = io.StringIO()
        args = ["--sketch", str(self.sketch), "--out", str(self.root / "dist")]
        args += ["--drivers", str(self.root / "drivers"), *extra]
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(out):
            code = icons.main(args)
        return code, out.getvalue()

    def read(self, path):
        return (self.root / path).read_text()

    def test_exports_are_laid_out_like_a_driver_folder(self):
        code, out = self.run_icons()
        self.assertEqual(code, 0)
        shaped = icons.ICON_ARTBOARDS["shaped"]
        self.assertEqual(self.read("dist/www/icons/experience_1024.png"), shaped)
        self.assertEqual(self.read("dist/www/icons/device_sm.png"), shaped)
        header = "dist/www/documentation/images/header.png"
        self.assertEqual(self.read(header), "Documentation Header")
        self.assertTrue((self.root / "dist/cards/Website Card - Dark.png").is_file())
        self.assertIn("skipped Finite Labs Logo", out)

    def test_square_style_exports_the_square_artboard(self):
        self.run_icons("--style", "square")
        self.assertEqual(
            self.read("dist/www/icons/device_sm.png"), icons.ICON_ARTBOARDS["square"]
        )

    def test_only_files_a_driver_already_has_are_refreshed(self):
        has = self.root / "drivers/has_icons/www"
        (has / "icons").mkdir(parents=True)
        (has / "icons/device_sm.png").write_text("old")
        (has / "documentation/images").mkdir(parents=True)
        (has / "documentation/images/header.png").write_text("old")
        (self.root / "drivers/no_icons/www").mkdir(parents=True)
        self.run_icons()
        shaped = icons.ICON_ARTBOARDS["shaped"]
        self.assertEqual((has / "icons/device_sm.png").read_text(), shaped)
        header = (has / "documentation/images/header.png").read_text()
        self.assertEqual(header, "Documentation Header")
        self.assertFalse((has / "icons/experience_1024.png").exists())
        self.assertEqual(list((self.root / "drivers/no_icons/www").iterdir()), [])

    def test_without_sketch_it_says_so(self):
        with mock.patch.dict(os.environ, {"SKETCHTOOL": str(self.root / "missing")}):
            code, out = self.run_icons()
        self.assertEqual(code, 1)
        self.assertIn("make icons needs Sketch", out)


if __name__ == "__main__":
    unittest.main()
