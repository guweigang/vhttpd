#!/usr/bin/env python3
"""Real two-listener vjsx process: authenticated counters follow WS lifecycle."""
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('listener_counter_ws', ROOT / 'tests/multi-app-paseo/ws_client.py')
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def port():
    with socket.socket() as connection:
        connection.bind(('127.0.0.1', 0))
        return connection.getsockname()[1]

def request(number, path, token='counter-fixture'):
    req = urllib.request.Request(f'http://127.0.0.1:{number}{path}', headers={'x-vhttpd-admin-token': token})
    with HTTP.open(req, timeout=3) as response:
        return json.load(response)

def wait(fn):
    end = time.monotonic() + 60
    while time.monotonic() < end:
        try:
            value = fn()
            if value:
                return value
        except (OSError, ValueError):
            pass
        time.sleep(.1)
    raise AssertionError('Listener counters did not reach expected state')

def run():
    binary = os.environ['VHTTPD_BIN']
    with tempfile.TemporaryDirectory(prefix='vhttpd-listener-counters-', dir=os.environ.get('VHTTPD_COUNTER_WORK_ROOT')) as directory:
        work = Path(directory)
        web, paseo, admin = port(), port(), port()
        (work / 'paseo').mkdir()
        shutil.copy2(ROOT / 'examples/paseo-relay/app.mts', work / 'paseo/app.mts')
        component = (ROOT / 'examples/paseo-relay/component.toml').read_text().replace('port = 19901', f'port = {paseo}')
        (work / 'paseo/component.toml').write_text(component)
        (work / 'main.mjs').write_text('export default function(ctx) { return ctx.json({ok:true}); }')
        config = work / 'vhttpd.toml'
        config.write_text(f'''version=2
include=["paseo/component.toml"]
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
token="counter-fixture"
[engines.web]
kind="vjsx"
entry="main.mjs"
module_root="."
thread_count=1
[adapters.web]
kind="http-handler"
engine="engine:web"
[[pipelines]]
id="web"
ingress="listener:web"
match.paths=["*"]
egress="adapter:web"
''')
        with (work / 'runtime.log').open('wb') as log:
            runtime_environment = os.environ.copy()
            if library_path := os.environ.get('VHTTPD_COUNTER_RUNTIME_LIBRARY_PATH'):
                runtime_environment['DYLD_LIBRARY_PATH'] = library_path
            process = subprocess.Popen([binary, '--config', str(config)], cwd=work, stdout=log, stderr=log, env=runtime_environment)
            client = None
            try:
                wait(lambda: request(web, '/').get('ok'))
                wait(lambda: request(paseo, '/meta').get('app') == 'paseo-relay')
                endpoint = '/admin/runtime/websocket-listeners'
                initial = wait(lambda: request(admin, endpoint))
                assert initial['scope'] == 'process' and initial['active_connections'] == 0
                try:
                    request(admin, endpoint, token='incorrect')
                    raise AssertionError('Unauthenticated counters exposed')
                except urllib.error.HTTPError as error:
                    assert error.code == 403
                client = ws.WebSocket('127.0.0.1', paseo, '/ws?serverId=counter-fixture&role=client&connectionId=counter&v=2')
                active = wait(lambda: (data if (data := request(admin, endpoint))['active_connections'] == 1 else None))
                assert any('paseo' in item['listener_ids'] and item['active_connections'] == 1 for item in active['listeners'])
                assert any('web' in item['listener_ids'] and item['active_connections'] == 0 for item in active['listeners'])
                client.close()
                client = None
                wait(lambda: request(admin, endpoint)['active_connections'] == 0)
                assert request(web, '/')['ok']
                print(json.dumps({'passed': True, 'single_process': True, 'secondary_listener_count': '0 -> 1 -> 0', 'authenticated': True, 'primary_http_preserved': True}))
            finally:
                if client is not None:
                    client.close()
                process.terminate()
                try:
                    process.wait(timeout=15)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()

if __name__ == '__main__':
    run()
