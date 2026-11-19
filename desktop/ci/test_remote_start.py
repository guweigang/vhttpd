"""Linux SSH startup script regression tests; no real credentials or services."""
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess
import tempfile
import unittest
import socket
import time
import urllib.request


class RemoteStartTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='vhttpd-start-')
        self.root = Path(self.temp.name)
        self.project = self.root / 'instance'
        self.project.mkdir()
        (self.project / '.desktop-instance-id').write_text('a' * 24)
        (self.project / '.desktop-runtime-id').write_text('legacy')
        (self.project / 'vhttpd.toml').write_text('original private configuration')
        (self.project / 'process.log').write_text('previous log\n')
        self.binary = self.root / 'vhttpd'
        self.binary.write_text('#!/bin/sh\n'
            'if [ "$1" = --workbench-upgrade-check ]; then exit 0; fi\n'
            'echo $$ > runtime.pid\nexec sleep 60\n')
        self.binary.chmod(0o700)

    def tearDown(self):
        pid = self.project / 'runtime.pid'
        if pid.exists() and pid.read_text().strip().isdigit():
            number = int(pid.read_text().strip())
            if number != os.getpid():
                try:
                    os.kill(number, signal.SIGTERM)
                except ProcessLookupError:
                    pass
        self.temp.cleanup()

    def start(self):
        values = dict(project=str(self.project), config=str(self.project/'vhttpd.toml'),
                      binary=str(self.binary), runtime_id='legacy', instance_id='a'*24,
                      pid_file=str(self.project/'runtime.pid'))
        script = 'set -eu\numask 077\n' + ''.join(
            key+'='+shlex.quote(value)+'\n' for key, value in values.items())
        script += (Path(__file__).resolve().parents[1]/'host/remote_scripts/start.sh').read_text()
        return subprocess.run(['/bin/sh'], input=script, text=True, capture_output=True, timeout=12)

    def test_stale_pid_is_backed_up_and_configuration_is_preserved(self):
        (self.project/'runtime.pid').write_text('99999999')
        result = self.start()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertIn('VHTTPD_START:started', result.stdout)
        self.assertEqual((self.project/'vhttpd.toml').read_text(), 'original private configuration')
        self.assertTrue((self.project/'process.log').read_text().startswith('previous log\n'))
        self.assertEqual([p.read_text() for p in (self.project/'.runtime/pid-backups').glob('*.pid')], ['99999999'])
        result = self.start()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('PID', result.stdout)

    def test_live_pid_is_not_removed(self):
        (self.project/'runtime.pid').write_text(str(os.getpid()))
        self.assertNotEqual(self.start().returncode, 0)
        self.assertEqual((self.project/'runtime.pid').read_text(), str(os.getpid()))

    def test_symlink_pid_is_not_followed(self):
        outside = self.root/'outside'
        outside.write_text('99999999')
        (self.project/'runtime.pid').symlink_to(outside)
        self.assertNotEqual(self.start().returncode, 0)
        self.assertEqual(outside.read_text(), '99999999')

    def test_other_operation_lock_is_preserved(self):
        (self.project/'.desktop-runtime-lock').mkdir()
        self.assertNotEqual(self.start().returncode, 0)
        self.assertTrue((self.project/'.desktop-runtime-lock').is_dir())

    @unittest.skipUnless(os.environ.get('VHTTPD_START_TEST_RUNTIME'), 'native runtime fixture not supplied')
    def test_native_runtime_restarts_after_stale_pid_and_start_is_idempotent(self):
        shutil.copy2(os.environ['VHTTPD_START_TEST_RUNTIME'], self.binary)
        with socket.socket() as s:
            s.bind(('127.0.0.1', 0))
            port = s.getsockname()[1]
        (self.project/'main.mjs').write_text('export default c=>c.json({ok:true},200);')
        config = f'''version=2
[server]
pid_file="runtime.pid"
[listeners.web]
protocol="http"
host="127.0.0.1"
port={port}
[engines.app]
kind="vjsx"
entry="main.mjs"
runtime_profile="node"
thread_count=1
[adapters.app]
kind="http-handler"
engine="engine:app"
[[pipelines]]
id="app"
ingress="listener:web"
egress="adapter:app"
match.paths=["*"]
'''
        (self.project/'vhttpd.toml').write_text(config)
        (self.project/'runtime.pid').write_text('99999999')
        result = self.start()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
        for _ in range(50):
            try:
                body = opener.open(f'http://127.0.0.1:{port}/probe', timeout=1).read()
                if body == b'{"ok":true}':
                    break
            except OSError:
                pass
            time.sleep(.1)
        else:
            self.fail('native business did not become ready')
        original_pid = (self.project/'runtime.pid').read_text()
        result = self.start()
        self.assertEqual(result.returncode, 0, result.stdout+result.stderr)
        self.assertIn('VHTTPD_START:already_running', result.stdout)
        self.assertEqual((self.project/'runtime.pid').read_text(), original_pid)
        self.assertEqual((self.project/'vhttpd.toml').read_text(), config)


if __name__ == '__main__':
    unittest.main()
