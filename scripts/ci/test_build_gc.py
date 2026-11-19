#!/usr/bin/env python3
"""Exercise real Make build entry points without compiling the whole server."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]


class BuildGCTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="vhttpd-build-gc-")
        self.addCleanup(self.temp.cleanup)
        self.work = Path(self.temp.name)
        self.source = self.work / "source"
        self.source.mkdir()
        (self.source / "main.v").write_text("module main\nfn main() {}\n")
        self.stage = self.work / "stage"
        self.args_file = self.work / "compiler-args.json"
        bin_dir = self.work / "bin"
        bin_dir.mkdir()
        # Even with pkg-config installed but GC unavailable, the build must
        # select Boehm and let the compiler diagnose missing libraries.
        pkg = bin_dir / "pkg-config"
        pkg.write_text("#!/bin/sh\nexit 1\n")
        pkg.chmod(0o755)
        compiler = bin_dir / "v"
        compiler.write_text(
            f"#!{sys.executable}\nimport json, os, sys\n"
            "with open(os.environ['GC_TEST_ARGS'], 'w') as f: "
            "json.dump(sys.argv[1:], f)\n"
            "from pathlib import Path\n"
            "args = sys.argv[1:]\n"
            "target = Path(args[args.index('-o') + 1])\n"
            "gc = os.environ.get('GC_TEST_ACTUAL_GC', 'boehm')\n"
            "info = json.dumps({'gc': gc, 'gc_enabled': gc == 'boehm'})\n"
            "target.write_text('#!' + sys.executable + '\\nprint(' + repr(info) + ')\\n')\n"
            "target.chmod(0o755)\n"
        )
        compiler.chmod(0o755)
        self.env = os.environ.copy()
        for name in ("VPHP_V_GC", "V_GC_FLAG", "MAKEFLAGS", "MFLAGS", "MAKEOVERRIDES"):
            self.env.pop(name, None)
        self.env.update(PATH=str(bin_dir) + os.pathsep + self.env["PATH"],
                        GC_TEST_ARGS=str(self.args_file))

    def build(self, target, *settings):
        return subprocess.run(
            ["make", "--no-print-directory", "-C", str(ROOT), *([target] if target else []),
             f"SRC_DIR={self.source}", f"BUILD_STAGE_ROOT={self.stage}",
             f"VJS_QUICKJS_PATH={self.work}", f"VHTTPD_BIN={self.work / 'vhttpd'}",
             *settings], env=self.env, text=True, capture_output=True,
        )

    def test_default_and_legacy_auto_always_enable_gc(self):
        for target in ("", "build", "prod", "vhttpd", "build-prod", "build-db"):
            for settings in ((), ("VPHP_V_GC=auto",), ("VPHP_V_GC=",)):
                with self.subTest(target=target, settings=settings):
                    result = self.build(target, *settings)
                    self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                    args = json.loads(self.args_file.read_text())
                    self.assertEqual(args[args.index("-gc") + 1], "boehm")

    def test_no_gc_is_rejected_before_staging_or_compilation(self):
        self.stage.mkdir()
        marker = self.stage / "preserve-existing-stage"
        marker.write_text("unchanged")
        for target in ("", "build", "prod", "vhttpd", "build-prod", "build-db"):
            with self.subTest(target=target):
                result = self.build(target, "VPHP_V_GC=none")
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("require Boehm GC", result.stderr)
                self.assertFalse(self.args_file.exists())
                self.assertEqual(marker.read_text(), "unchanged")

    def test_environment_cannot_accidentally_disable_gc(self):
        self.env["VPHP_V_GC"] = "none"
        result = self.build("build")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("require Boehm GC", result.stderr)

    def test_raw_gc_flag_cannot_override_runtime_policy(self):
        result = self.build("build", "V_GC_FLAG=-gc none")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        args = json.loads(self.args_file.read_text())
        self.assertEqual(args[args.index("-gc") + 1], "boehm")

    def test_compiler_silently_omitting_gc_is_rejected(self):
        self.env['GC_TEST_ACTUAL_GC'] = 'none'
        result = self.build('prod')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('actual runtime does not have enabled Boehm GC', result.stderr)
        args = json.loads(self.args_file.read_text())
        self.assertEqual(args[args.index('-gc') + 1], 'boehm')


if __name__ == "__main__":
    unittest.main()
