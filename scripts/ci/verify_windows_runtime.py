"""Exercise a moved Windows runtime package with no developer tools on PATH."""
import argparse
import ctypes
import hashlib
import http.client
import json
import os
from pathlib import Path
import socket
import signal
import sys
import subprocess
import tempfile
import time
import uuid
import zipfile


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def graceful_stop(child):
    if child.poll() is not None:
        raise RuntimeError('Runtime exited before normal shutdown request')
    if os.name != 'nt':
        child.send_signal(signal.SIGTERM)
        child.wait(timeout=30)
        if child.returncode not in (143, -signal.SIGTERM):
            raise RuntimeError(f'Unexpected shutdown exit: {child.returncode}')
        return
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.OpenEventW.argtypes = [ctypes.c_uint32, ctypes.c_int, ctypes.c_wchar_p]
    kernel.OpenEventW.restype = ctypes.c_void_p
    kernel.SetEvent.argtypes = [ctypes.c_void_p]
    kernel.SetEvent.restype = ctypes.c_int
    kernel.CloseHandle.argtypes = [ctypes.c_void_p]
    kernel.CloseHandle.restype = ctypes.c_int
    event = kernel.OpenEventW(2, False, 'Local\\vhttpd.shutdown.' + str(child.pid))
    if not event:
        raise RuntimeError('Owned runtime did not publish its graceful shutdown event')
    try:
        if not kernel.SetEvent(event):
            raise RuntimeError('Cannot request normal shutdown')
    finally:
        kernel.CloseHandle(event)
    child.wait(timeout=30)
    if child.returncode != 143:
        raise RuntimeError(f'Expected graceful SIGTERM-equivalent exit (143), got {child.returncode}')


def verify(archive, output):
    if os.name != 'nt':
        raise RuntimeError('Run this acceptance on native Windows')
    expected = archive.with_name(archive.name + '.sha256').read_text().split()
    if expected != [hashlib.sha256(archive.read_bytes()).hexdigest(), archive.name]:
        raise RuntimeError('Runtime ZIP checksum mismatch')
    with tempfile.TemporaryDirectory(prefix='vhttpd Windows 安装 ') as folder:
        root = Path(folder)
        with zipfile.ZipFile(archive) as bundle:
            names = bundle.namelist()
            if len({name.casefold() for name in names}) != len(names) or sum(i.file_size for i in bundle.infolist()) > 536870912:
                raise RuntimeError('Invalid archive size or duplicate entry')
            if any((entry.external_attr >> 16) & 0o170000 == 0o120000 for entry in bundle.infolist()):
                raise RuntimeError('Runtime ZIP must not contain symlinks')
            for name in names:
                if '\\' in name or ':' in name or '..' in Path(name).parts or Path(name).is_absolute():
                    raise RuntimeError('Unsafe archive entry')
            bundle.extractall(root)
        package = root / 'vhttpd-windows-amd64'
        binary = package / 'vhttpd.exe'
        image = binary.read_bytes()
        pe_offset = int.from_bytes(image[60:64], 'little')
        if image[:2] != b'MZ' or image[pe_offset:pe_offset + 6] != b'PE\x00\x00\x64\x86':
            raise RuntimeError('Runtime package does not contain an x64 PE executable')
        metadata = json.loads((package / 'runtime-manifest.json').read_text(encoding='utf-8-sig'))
        exercise_runtime(binary, root, output, metadata)


def exercise_runtime(binary, root, output, metadata=None):
    package = binary.parent
    checks = []
    home = root / 'Fresh 用户 home'
    project = home / 'project with includes'
    project.mkdir(parents=True)
    env = {key: os.environ[key] for key in ('SystemRoot', 'WINDIR', 'SystemDrive', 'TEMP', 'TMP') if key in os.environ}
    search_path = str(package) + ';' + str(Path(env['WINDIR']) / 'System32') if os.name == 'nt' else '/usr/bin:/bin'
    env.update(PATH=search_path, HOME=str(home),
               USERPROFILE=str(home), APPDATA=str(home / 'AppData/Roaming'), LOCALAPPDATA=str(home / 'AppData/Local'))
    info = json.loads(subprocess.check_output([str(binary), '--build-info'], env=env, cwd=home, text=True, timeout=15))
    if (metadata is not None and info != metadata['build_info']) or info.get('gc') != 'boehm' or info.get('gc_enabled') is not True:
        raise RuntimeError('Packaged binary metadata/GC mismatch')
    if subprocess.check_output([str(binary), '--version'], env=env, cwd=home, text=True, timeout=15).strip() != info['version']:
        raise RuntimeError('Packaged version mismatch')
    checks.append('standalone runtime version and enabled Boehm GC with system-only PATH')
    web, admin = free_port(), free_port()
    while admin == web:
        admin = free_port()
    token = uuid.uuid4().hex
    config = f'''version=2
    include=["engines.toml","routes.toml"]
    [server]
    pid_file="runtime.pid"
    [listeners.web]
    protocol="http"
    host="127.0.0.1"
    port={web}
    [listeners.admin]
    protocol="http"
    host="127.0.0.1"
    port={admin}
    [control]
    listener="listener:admin"
    token="{token}"
    '''
    engines = '[engines.app]\nkind="vjsx"\nentry="main.mjs"\nruntime_profile="node"\nthread_count=1\n[adapters.app]\nkind="http-handler"\nengine="engine:app"\n'
    routes = '[[pipelines]]\nid="hello"\ningress="listener:web"\negress="adapter:app"\nmatch.paths=["/before"]\n'
    for name, text in {'vhttpd.toml': config, 'engines.toml': engines, 'routes.toml': routes,
                       'main.mjs': 'import { platform } from "./lib/value.mjs"; export default c=>c.json({ok:true,platform},200);'}.items():
        (project / name).write_text(text, encoding='utf-8')
    (project / 'lib').mkdir()
    (project / 'lib/value.mjs').write_text('export const platform = "fixture";', encoding='utf-8')
    children = []
    logs = []

    def start():
        log = (root / ('run-' + str(len(children)) + '.log')).open('wb')
        logs.append(log)
        child = subprocess.Popen([str(binary), '--config', str(project / 'vhttpd.toml')], cwd=project,
                                 env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT,
                                 creationflags=subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0)
        children.append(child)
        return child

    def request(port, path, method='GET', body=None, authenticated=True, decode=True):
        connection = http.client.HTTPConnection('127.0.0.1', port, timeout=5)
        try:
            headers = {'Connection': 'close', 'Content-Type': 'application/json'}
            if authenticated:
                headers['x-vhttpd-admin-token'] = token
            connection.request(method, path, json.dumps(body) if body is not None else None, headers)
            response = connection.getresponse()
            content = response.read()
            if response.status != 200:
                raise RuntimeError(f'{method} {path.split("?")[0]} returned {response.status}')
            return json.loads(content) if decode else content
        finally:
            connection.close()

    def wait_ready(child):
        deadline = time.monotonic() + 90
        while time.monotonic() < deadline:
            if child.poll() is not None:
                raise RuntimeError('Runtime exited during startup; inspect isolated runtime log')
            try:
                state = request(admin, '/admin/workbench/instance')
            except (OSError, ValueError, RuntimeError, http.client.HTTPException):
                time.sleep(.1)
                continue
            if state.get('error'):
                raise RuntimeError('Runtime startup failed; inspect isolated log: ' + state['error'].split(':', 1)[0])
            if state['ready']:
                return state
            time.sleep(.1)
        raise RuntimeError('Runtime readiness timed out')

    try:
        child = start()
        before = wait_ready(child)
        if request(web, '/before')['platform'] != 'fixture':
            raise RuntimeError('vjsx handler did not run')
        if not request(admin, '/admin/ui/', decode=False):
            raise RuntimeError('Admin UI did not load')
        checks.append('fresh project, HTTP/vjsx startup and Admin UI load')
        workspace = request(admin, '/admin/config/workspace')
        files = {Path(item['source']['path']).name: item for item in workspace['files']}
        modifications = []
        for name, value in [('engines.toml', engines.replace('thread_count=1', 'thread_count=2')),
                            ('routes.toml', routes.replace('/before', '/after'))]:
            source = files[name]
            modifications.append({'path': source['source']['path'], 'original': source['value'], 'value': value})
        change = 'windows-' + uuid.uuid4().hex
        payload = {'config_path': workspace['config_path'], 'files': modifications}
        for path, body in [(f'/admin/config/changesets?id={change}', payload),
                           (f'/admin/config/changesets/{change}/validate', {}),
                           (f'/admin/config/changesets/{change}/publish', {})]:
            if not request(admin, path, 'POST', body)['ok']:
                raise RuntimeError('Whole-project configuration change was rejected')
        published = request(admin, '/admin/workbench/instance')
        if published['boot_id'] != before['boot_id'] or published['disk_revision'] == published['effective_revision']:
            raise RuntimeError('Published configuration was not marked pending')
        if request(web, '/before')['ok'] is not True:
            raise RuntimeError('Publishing partly changed the running project')
        checks.append('two include sources validated/published together; old running project remains unchanged')
        graceful_stop(child)
        child = start()
        after = wait_ready(child)
        if (after['boot_id'] == before['boot_id'] or not after['effective_revision'] or
                after['effective_revision'] != after['disk_revision']):
            raise RuntimeError('Whole-project activation did not match the new boot')
        if request(web, '/after')['ok'] is not True:
            raise RuntimeError('Published route did not become effective')
        graceful_stop(child)
        checks.append(('Desktop shutdown event' if os.name == 'nt' else 'POSIX SIGTERM') + ', normal exit, restart and whole-project activation')
    finally:
        for child in children:
            if child.poll() is None:
                child.kill()
                child.wait(timeout=10)
        for log in logs:
            log.close()
        # Keep logs alongside the result on failure too; never print config/token.
        output.parent.mkdir(parents=True, exist_ok=True)
        for log in root.glob('run-*.log'):
            output.with_name(log.name).write_bytes(log.read_bytes().replace(token.encode(), b'[redacted]'))
    output.write_text(json.dumps({'platform': sys.platform, 'version': info['version'],
                                'checks': checks, 'passed': True}, indent=2) + '\n')
    for check in checks:
        print('PASS', check)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path, nargs='?')
    parser.add_argument('--runtime', type=Path, help='Native preflight of the same HTTP/include/shutdown scenario')
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    if bool(args.archive) == bool(args.runtime):
        parser.error('Provide an archive or --runtime')
    if args.runtime:
        with tempfile.TemporaryDirectory(prefix='vhttpd-native-preflight-') as folder:
            exercise_runtime(args.runtime.resolve(strict=True), Path(folder), args.output.resolve())
    else:
        verify(args.archive.resolve(strict=True), args.output.resolve())
