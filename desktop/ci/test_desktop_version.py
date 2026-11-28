"""Check the actual embedded version source and compile-time package override."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile
import unittest


@unittest.skipUnless(shutil.which('v'), 'V compiler unavailable')
class CompiledVersionTests(unittest.TestCase):
    def test_default_and_package_version_do_not_use_runtime_version(self):
        desktop = Path(__file__).resolve().parents[1]
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            for name in ('version.v', 'version.txt'):
                shutil.copyfile(desktop / name, root / name)
            (root / 'main.v').write_text('''module main
import os
struct Workshop {}
fn ui_text(text string) string { return if os.getenv('QA_LANG') == 'en' && text == '发布于 {0}' { 'Released on {0}' } else { text } }
fn (app &Workshop) environment_name() string { return 'remote test' }
fn (app &Workshop) environment_version_label() string { return 'vhttpd 0.9.0' }
fn main() { println(Workshop{}.workbench_about_text()) }
''')
            for override in (None, '0.1.0-dev.g123456789abc'):
                expected = override or (root / 'version.txt').read_text().strip()
                flags = ['-d', 'vhttpd_desktop_release_date=2026-11-28']
                if override:
                    flags += ['-d', 'vhttpd_desktop_version=' + override]
                executable = root / 'probe'
                result = subprocess.run(['v', '-gc', 'none', *flags, '-o', str(executable), str(root)],
                                        capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                output = subprocess.check_output([str(executable)], text=True)
                self.assertEqual(output.splitlines(), ['vhttpd desktop ' + expected, '发布于 Nov 28, 2026',
                                                     'Powered by vlang & ui2', '© Bullsoft.org'])
                english = subprocess.check_output([str(executable)], text=True, env=dict(os.environ, QA_LANG='en'))
                self.assertIn('Released on Nov 28, 2026', english)

    def test_runtime_keeps_its_own_embedded_manifest_version(self):
        repository = Path(__file__).resolve().parents[2]
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            shutil.copyfile(repository / 'v.mod', root / 'v.mod')
            shutil.copyfile(repository / 'src/version.v', root / 'version.v')
            (root / 'main.v').write_text('module main\nfn main() { println(vhttpd_version) }\n')
            executable = root / 'probe'
            subprocess.run(['v', '-gc', 'none', '-d', 'vhttpd_desktop_version=0.1.0',
                            '-o', str(executable), str(root)], check=True, capture_output=True, text=True)
            self.assertEqual(subprocess.check_output([str(executable)], text=True).strip(), '0.9.1')
