#!/usr/bin/env python3
"""Exercise pinned SDK acquisition and rejection of unpublished source changes."""
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]

class PinnedVjsxTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='vhttpd-sdk-lock-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.origin = self.root / 'origin'
        self.origin.mkdir()
        self.git(self.origin, 'init', '-q')
        (self.origin / 'context.v').write_text('module vjsx\n')
        self.git(self.origin, 'add', 'context.v')
        self.git(self.origin, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture')
        self.sha = self.git(self.origin, 'rev-parse', 'HEAD').strip()
        scripts = self.root / 'scripts'
        (scripts / 'ci').mkdir(parents=True)
        shutil.copy2(ROOT / 'scripts/ensure-vjsx.sh', scripts / 'ensure-vjsx.sh')
        (scripts / 'ci/toolchain.env').write_text(f'VJSX_REPO={self.origin}\nVJSX_COMMIT={self.sha}\n')
        self.env = dict(os.environ)
        self.env.pop('VJSX_DIR', None)
        self.sdk = self.root / '.deps/vjsx'

    def git(self, where, *args):
        return subprocess.check_output(['git', '-C', str(where), *args], text=True, stderr=subprocess.DEVNULL)

    def ensure(self):
        return subprocess.run(['bash', str(self.root / 'scripts/ensure-vjsx.sh')], env=self.env, capture_output=True, text=True)

    def test_fresh_and_repeated_builds_use_exact_commit(self):
        for _ in range(2):
            result = self.ensure()
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout.strip(), str(self.sdk))
            self.assertEqual(self.git(self.sdk, 'rev-parse', 'HEAD').strip(), self.sha)

    def test_tracked_and_untracked_source_changes_are_rejected_without_reset(self):
        self.assertEqual(self.ensure().returncode, 0)
        source = self.sdk / 'context.v'
        source.write_text('unpublished changes')
        self.assertNotEqual(self.ensure().returncode, 0)
        self.assertEqual(source.read_text(), 'unpublished changes')
        source.write_text('module vjsx\n')
        (self.sdk / 'new_host.v').write_text('module vjsx\n')
        self.assertNotEqual(self.ensure().returncode, 0)
        self.assertTrue((self.sdk / 'new_host.v').exists())

    def test_wrong_revision_is_rejected_without_checkout(self):
        self.assertEqual(self.ensure().returncode, 0)
        self.git(self.sdk, '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '--allow-empty', '-qm', 'different revision')
        changed = self.git(self.sdk, 'rev-parse', 'HEAD').strip()
        self.assertNotEqual(self.ensure().returncode, 0)
        self.assertEqual(self.git(self.sdk, 'rev-parse', 'HEAD').strip(), changed)

class ToolchainLockTest(unittest.TestCase):
    def test_desktop_and_runtime_share_published_language_sources(self):
        def load(path):
            return dict(line.split('=', 1) for line in path.read_text().splitlines() if line and not line.startswith('#'))
        runtime = load(ROOT / 'scripts/ci/toolchain.env')
        desktop = load(ROOT / 'desktop/ci/toolchain.env')
        for key in ['V_REPO', 'V_COMMIT', 'VJSX_REPO', 'VJSX_COMMIT', 'VC_REPO', 'VC_COMMIT']:
            self.assertEqual(runtime[key], desktop[key], key)
        self.assertEqual(runtime['TCC_MACOS_ARM64_COMMIT'], desktop['TCC_COMMIT'])

if __name__ == '__main__':
    unittest.main()
