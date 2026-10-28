#!/usr/bin/env python3
"""Linux production-runtime application transaction acceptance; stdlib only."""
import argparse
import base64
import hashlib
import http.client
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import uuid


def free_port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', required=True, type=Path)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='vhttpd-application-') as folder:
        root = Path(folder).resolve()
        runtime = root / 'runtime'
        project = root / 'instances/app'
        runtime.mkdir(); project.mkdir(parents=True)
        binary = runtime / 'vhttpd'
        shutil.copy2(args.runtime.resolve(), binary)
        # Preserve CI-linked runtime libraries if the input is a relocatable package.
        if (args.runtime.parent / 'runtime').is_dir():
            shutil.copytree(args.runtime.parent / 'runtime', runtime / 'runtime')
        web, admin = free_port(), free_port()
        token = 'isolated-remote-admin-token'
        original_root = f'''version=2
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
        routes = '[[pipelines]]\nid="hello"\ningress="listener:web"\negress="adapter:app"\nmatch.paths=["*"]\n'
        source = 'import fs from "fs"; export default c=>c.json({release:"A",asset:fs.readFileSync("public/banner.txt").toString("utf8")},200);'
        for name, text in {'vhttpd.toml': original_root, 'engines.toml': engines, 'routes.toml': routes,
                           'main.mjs': source, '.env': 'REMOTE-ENV', 'user-data.txt': 'REMOTE-DATA',
                           '.desktop-instance-id': 'a'*24, '.desktop-runtime-id': 'legacy'}.items():
            (project / name).write_text(text)
        (project / 'public').mkdir(); (project / 'public/banner.txt').write_text('original-asset')
        env = dict(os.environ)
        for key in ['VHTTPD_RESTART_OPERATION', 'VJSX_DIR', 'VMODULES', 'VJS_QUICKJS_PATH']:
            env.pop(key, None)
        env.update(HOME=str(root), PATH='/usr/bin:/bin', VFLAGS='')
        helpers = []
        log = (root / 'initial.log').open('wb')
        initial = subprocess.Popen([str(binary), '--config', str(project / 'vhttpd.toml'), '--manual-restart'], cwd=project, env=env, stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT)

        def request(port, path, authenticated=False):
            connection = http.client.HTTPConnection('127.0.0.1', port, timeout=3)
            try:
                connection.request('GET', path, headers={'Connection': 'close', **({'x-vhttpd-admin-token': token} if authenticated else {})})
                response = connection.getresponse(); data = response.read()
                assert response.status == 200
                return json.loads(data)
            finally:
                connection.close()

        def instance():
            return request(admin, '/admin/workbench/instance', True)

        def wait_ready():
            deadline = time.monotonic() + 60
            while time.monotonic() < deadline:
                try:
                    value = instance()
                    if value['ready']:
                        return value
                except Exception:
                    pass
                time.sleep(.15)
            raise AssertionError('fixture business not ready')

        def deploy(contents, expected):
            before = wait_ready()
            operation = uuid.uuid4().hex[:24]
            directory = project / '.desktop-deployments' / operation
            directory.mkdir(parents=True, mode=0o700)
            # Local endpoints/credentials are intentionally absent from transport.
            local_root = original_root.replace(str(web), '0').replace(str(admin), '0').replace(token, '')
            files = {'vhttpd.toml': local_root, 'config/engines.toml': engines.replace('"main.mjs"', '"../main.mjs"'),
                     'config/routes.toml': routes, **contents}
            files['vhttpd.toml'] = files['vhttpd.toml'].replace('["engines.toml","routes.toml"]', '["config/engines.toml","config/routes.toml"]')
            records = []
            for name, text in files.items():
                data = text.encode() if isinstance(text, str) else text
                records.append(dict(path=name, data=base64.b64encode(data).decode(), hash=hashlib.sha256(data).hexdigest(), mode=0o600))
            payload = json.dumps(dict(protocol=1, id=operation, files=records, configs=['vhttpd.toml', 'config/engines.toml', 'config/routes.toml'], required=['control\x1ftoken']))
            (directory / 'payload.json').write_text(payload)
            descriptor = dict(id=operation, server_root=str(root), config_path=str(project/'vhttpd.toml'), runtime_id='legacy', admin_port=admin, token=token, expected_boot=before['boot_id'], expected_revision=before['effective_revision'], payload_hash=hashlib.sha256(payload.encode()).hexdigest())
            path = directory / 'request.json'
            path.write_text(json.dumps(descriptor)); path.chmod(0o600)
            prepared = subprocess.run([str(binary), '--workbench-deploy-prepare', str(path)], cwd=project, env=env, capture_output=True, text=True, timeout=30)
            assert prepared.returncode == 0, 'preflight: '+prepared.stderr
            preview = json.loads(prepared.stdout)
            assert preview['id'] == operation
            assert instance()['boot_id'] == before['boot_id']
            assert not path.exists(), 'prepare credential descriptor retained'
            lock = project / '.desktop-runtime-lock'; lock.mkdir()
            (lock / 'owner').write_text(operation)
            path.write_text(json.dumps(descriptor)); path.chmod(0o600)
            (project / '.desktop-deploy-current').write_text(operation)
            (directory / 'status.json').write_text(json.dumps(dict(id=operation, config_path=str(project/'vhttpd.toml'), phase='validating')))
            stream = (directory / 'launch.log').open('wb')
            helper = subprocess.Popen([str(binary), '--workbench-deploy-helper', str(path)], cwd=project, env=env, stdin=subprocess.DEVNULL, stdout=stream, stderr=subprocess.STDOUT)
            helpers.append((helper, stream))
            deadline = time.monotonic() + 110
            while time.monotonic() < deadline:
                status = json.loads((directory / 'status.json').read_text())
                if status['phase'] in ['completed', 'rolled_back', 'failed', 'rollback_failed']:
                    assert status['phase'] == expected, json.dumps(status)
                    current = wait_ready()
                    assert current['boot_id'] != before['boot_id']
                    assert current['disk_revision'] == current['effective_revision']
                    helper.wait(timeout=10)
                    assert not path.exists() and not (directory/'plan.json').exists()
                    assert not lock.exists()
                    return status, preview, current
                time.sleep(.15)
            raise AssertionError('deploy did not finish')

        try:
            baseline = wait_ready()
            a, _, applied = deploy({'main.mjs': source, 'public/banner.txt': 'asset-A', 'public/obsolete.txt': 'old'}, 'completed')
            assert request(web, '/')['asset'] == 'asset-A'
            revision_a = applied['effective_revision']
            config_before = {p.name: p.read_bytes() for p in [project/'vhttpd.toml', project/'config/engines.toml', project/'config/routes.toml']}
            failed, _, rolled = deploy({'main.mjs': 'throw new Error("intentional startup failure"); export default c=>c.text("bad");', 'public/banner.txt': 'asset-B', 'public/new.bin': b'\x00\x01\xff'}, 'rolled_back')
            assert rolled['effective_revision'] == revision_a
            assert request(web, '/')['asset'] == 'asset-A'
            assert (project/'public/obsolete.txt').read_text() == 'old'
            assert not (project/'public/new.bin').exists()
            for name, data in config_before.items():
                target = project/name if name=='vhttpd.toml' else project/'config'/name
                assert target.read_bytes() == data
            b, _, final = deploy({'main.mjs': source.replace('release:"A"', 'release:"B"'), 'public/banner.txt': 'asset-B', 'public/new.bin': b'\x00\x01\xff'}, 'completed')
            assert request(web, '/') == {'release': 'B', 'asset': 'asset-B'}
            assert (project/'public/new.bin').read_bytes() == b'\x00\x01\xff'
            assert not (project/'public/obsolete.txt').exists()
            assert (project/'.env').read_text() == 'REMOTE-ENV'
            assert (project/'user-data.txt').read_text() == 'REMOTE-DATA'
            report = dict(result='passed', original_boot=baseline['boot_id'], operations=[{k:s[k] for k in ['id','phase','revision','error']} for s in [a,failed,b]], checks=['source and binary/static assets','cross-include configuration','remote ports and Admin token preserved','warmup failure automatic rollback','removed assets restored on rollback','fixed source retry','obsolete managed file removal','remote env and unmanaged data retained','private request/plan cleanup'])
            if args.output:
                args.output.parent.mkdir(parents=True,exist_ok=True); args.output.write_text(json.dumps(report,indent=2)+'\n')
            print('PASS production application deployment, warmup rollback, retry, cross-include and remote environment preservation')
        finally:
            for helper, stream in helpers:
                if helper.poll() is None:
                    helper.terminate()
                stream.close()
            # Only this fixture's exact executable can be signalled.
            for process in Path('/proc').glob('[0-9]*/exe'):
                try:
                    if process.resolve() == binary:
                        os.kill(int(process.parent.name), signal.SIGTERM)
                except (OSError, ValueError):
                    pass
            try:
                initial.wait(timeout=10)
            except subprocess.TimeoutExpired:
                initial.kill(); initial.wait()
            log.close()


if __name__ == '__main__':
    main()
