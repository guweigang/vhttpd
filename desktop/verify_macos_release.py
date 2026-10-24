#!/usr/bin/env python3
"""Check the actual zip with system-only PATH and no access to development trees."""
import concurrent.futures
import json
import os
from pathlib import Path
import plistlib
import re
import socket
import subprocess
import time
import urllib.request
import sys
import tempfile
import zipfile


def run(*args, **kwargs):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT, **kwargs)


def verify_first_admin_requests(root, runtime, policy, env):
    project = root / 'Fresh Admin Project'
    project.mkdir()
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        port = reservation.getsockname()[1]
    with socket.socket() as reservation:
        reservation.bind(('127.0.0.1', 0))
        web_port = reservation.getsockname()[1]
    while web_port == port:
        with socket.socket() as reservation:
            reservation.bind(('127.0.0.1', 0))
            web_port = reservation.getsockname()[1]
    token = 'isolated-release-check'
    config = project / 'vhttpd.toml'
    config.write_text(f'\nversion=2\n[server]\npid_file="runtime.pid"\n[observability]\nevent_log="events.ndjson"\n[listeners.admin]\nprotocol="http"\nhost="127.0.0.1"\nport={port}\n[control]\nlistener="listener:admin"\ntoken="{token}"\n[listeners.web]\nprotocol="http"\nhost="127.0.0.1"\nport={web_port}\n[adapters.health]\nkind="fixed-response"\noptions.status=200\noptions.body="ok"\n[[pipelines]]\nid="health"\ningress="listener:web"\negress="adapter:health"\n')
    def request(path):
        req = urllib.request.Request(f'http://127.0.0.1:{port}' + path, headers={'x-vhttpd-admin-token': token})
        with urllib.request.urlopen(req, timeout=3) as response:
            return response.status
    with (project / 'runtime.log').open('w') as output:
        child = subprocess.Popen(['/usr/bin/sandbox-exec', '-f', str(policy), str(runtime / 'vhttpd'), '--config', str(config)], cwd=project, env=env, stdout=output, stderr=subprocess.STDOUT)
        try:
            deadline = time.monotonic() + 30
            while True:
                if child.poll() is not None:
                    raise RuntimeError('First-load instance exited: ' + (project / 'runtime.log').read_text()[-2000:])
                try:
                    if request('/admin/runtime') == 200:
                        break
                except Exception:
                    if time.monotonic() >= deadline:
                        raise
                time.sleep(.1)
            with concurrent.futures.ThreadPoolExecutor(max_workers=16) as pool:
                statuses = list(pool.map(request, ['/admin/drafts'] * 32))
                if any(status != 200 for status in statuses):
                    raise RuntimeError('Concurrent first Admin requests failed')
        finally:
            child.terminate()
            try:
                child.wait(timeout=7)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
    print('PASS concurrent first Admin requests initialize an empty project without false directory errors')


def verify(archive):
    repo = Path(__file__).resolve().parent.parent
    with zipfile.ZipFile(archive) as bundle:
        guide = bundle.getinfo('安装说明.txt')
        if not guide.flag_bits & 0x800:
            raise RuntimeError('Chinese installation guide filename must declare UTF-8')
    with tempfile.TemporaryDirectory(prefix='vhttpd-install-') as directory:
        root = Path(directory).resolve()
        installed = root / 'Applications with spaces'
        installed.mkdir()
        run('/usr/bin/ditto', '-x', '-k', str(archive), str(installed))
        app = installed / 'vhttpd-workbench.app'
        if not (installed / '安装说明.txt').is_file():
            raise RuntimeError('The zip must include installation instructions beside the app')
        run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
        info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
        if not info.get('LSMinimumSystemVersion'):
            raise RuntimeError('The app must declare its actual minimum macOS')
        if info['LSMinimumSystemVersion'] != '15.0':
            raise RuntimeError('Release deployment target must be macOS 15.0')
        runtime = app / 'Contents/Resources/runtime'
        binaries = [app / 'Contents/MacOS/vhttpd-workbench', runtime / 'vhttpd', *(runtime / 'lib').iterdir()]
        for binary in binaries:
            if 'arm64' not in run('/usr/bin/lipo', '-archs', str(binary)).split():
                raise RuntimeError(f'Missing arm64: {binary.name}')
            commands = run('/usr/bin/otool', '-l', str(binary))
            versions = re.findall(r'\bminos\s+(\d+(?:\.\d+){1,2})', commands)
            if not versions or any(tuple(map(int, value.split('.'))) > (15, 0, 0) for value in versions):
                raise RuntimeError(f'Binary exceeds macOS 15.0 deployment target: {binary.name}: {versions}')
            for line in run('/usr/bin/otool', '-L', str(binary)).splitlines()[1:]:
                dependency = line.strip().split(' (compatibility', 1)[0]
                if not dependency.startswith(('/System/Library/', '/usr/lib/', '@loader_path/')):
                    raise RuntimeError(f'Development dependency: {binary.name}: {dependency}')
        home = root / 'Fresh Home'
        home.mkdir()
        tmp = root / 'tmp'
        tmp.mkdir()
        # A moved debug executable can still read $embed_file through an absolute
        # developer path. Deny those paths rather than relying on a shortened PATH.
        denied = [repo.parent, Path('/opt/homebrew'), Path('/usr/local'), Path.home() / '.vmodules', Path.home() / 'local']
        filters = ' '.join('(subpath ' + json.dumps(str(path)) + ')' for path in denied)
        profile = '(version 1)(allow default)(deny file-read* ' + filters + ')'
        profile += '(deny process-exec (subpath "/Applications/Xcode.app") (subpath "/Library/Developer") (literal "/usr/bin/cc") (literal "/usr/bin/clang") (literal "/usr/bin/xcrun"))'
        policy = root / 'no-development.sb'
        policy.write_text(profile)
        env = {'HOME': str(home), 'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'TMPDIR': str(tmp) + '/', 'LANG': 'en_US.UTF-8'}
        result = run('/usr/bin/sandbox-exec', '-f', str(policy), str(binaries[0]), '--smoke', env=env, cwd=root)
        print(result, end='')
        result = run('/usr/bin/sandbox-exec', '-f', str(policy), str(binaries[0]), '--persistent-status-smoke', env=env, cwd=root)
        print(result, end='')
        result = run('/usr/bin/sandbox-exec', '-f', str(policy), str(binaries[0]), '--shared-relay-smoke', env=env, cwd=root)
        print(result, end='')
        result = run('/usr/bin/sandbox-exec', '-f', str(policy), str(binaries[0]), '--runtime-smoke', env=env, cwd=root)
        print(result, end='')
        verify_first_admin_requests(root, runtime, policy, env)
        print('PASS archive extraction, install guide, signature, arm64, relocatable libraries, minimum macOS ' + info['LSMinimumSystemVersion'])
        print('PASS fresh HOME, system-only PATH, denied developer trees and compiler execution')
        print('Gatekeeper/notarization and another clean Mac require separate validation.')


if __name__ == '__main__':
    try:
        verify(Path(sys.argv[1]).resolve(strict=True))
    except subprocess.CalledProcessError as error:
        print(error.output, file=sys.stderr)
        raise SystemExit(error.returncode)
