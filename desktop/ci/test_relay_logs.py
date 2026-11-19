#!/usr/bin/env python3
"""Verify Linux log ownership and bounds using a disposable process."""
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

source = Path(__file__).resolve().parents[1] / 'host/remote_scripts/relay_logs.py'
spec = importlib.util.spec_from_file_location('relay_logs', source)
logs = importlib.util.module_from_spec(spec)
spec.loader.exec_module(logs)

@unittest.skipUnless(sys.platform == 'linux', 'requires Linux /proc')
class LogTests(unittest.TestCase):
    def test_live_log_file_is_bounded_and_not_confused_with_other_instance(self):
        with tempfile.TemporaryDirectory() as directory:
            previous = os.environ.get('HOME')
            os.environ['HOME'] = directory
            process = None
            try:
                root = Path(directory)
                project = root / '.local/share/vhttpd-workbench/instances/fixture'
                project.mkdir(parents=True)
                config = project / 'vhttpd.toml'
                config.write_text('version=2')
                runtime = root / 'vhttpd'
                # A native fixture retains /proc/exe identity on both GNU and
                # Rust/uutils systems; copying a multicall sleep binary under
                # another basename can make it exit before discovery.
                compiler = shutil.which('cc')
                self.assertIsNotNone(compiler, 'Linux log fixture requires a C compiler')
                subprocess.run([compiler, '-x', 'c', '-', '-o', str(runtime)],
                               input='#include <unistd.h>\nint main(void) { sleep(30); return 0; }\n',
                               text=True, capture_output=True, check=True)
                live_log = project / '.desktop-upgrades/fixture/runtime.log'
                live_log.parent.mkdir(parents=True)
                live_log.write_text('x'*40000 + '\n[paseo-relay] connected\n')
                (project / 'process.log').write_text('old process log')
                with live_log.open('ab') as output:
                    process = subprocess.Popen([str(runtime)], cwd=project, stdout=output, stderr=output)
                    stream = io.StringIO()
                    with contextlib.redirect_stdout(stream):
                        logs.relay_logs(str(config))
                text = json.loads(stream.getvalue())['text']
                self.assertIn('[paseo-relay] connected', text)
                self.assertNotIn('old process log', text)
                self.assertLessEqual(len(text), 32768)
                with self.assertRaises(ValueError):
                    logs.relay_logs(str(root/'private/config.toml'))
            finally:
                if process is not None:
                    process.terminate()
                    process.wait(timeout=5)
                if previous is None:
                    os.environ.pop('HOME', None)
                else:
                    os.environ['HOME'] = previous

if __name__ == '__main__':
    unittest.main()
