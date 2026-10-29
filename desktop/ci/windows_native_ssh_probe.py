"""Fast real-client test, independent of V/bootstrap. Uses only local fixtures."""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import threading
import time

ssh, helper, work = sys.argv[1:]
work = Path(work)
work.mkdir(parents=True, exist_ok=True)
metadata = work / 'server.json'
fixture = subprocess.Popen([sys.executable, str(Path(__file__).with_name('windows_ssh_fixture.py')), str(metadata)])
try:
    deadline = time.monotonic() + 15
    while not metadata.exists() and time.monotonic() < deadline:
        time.sleep(.1)
    info = json.loads(metadata.read_text())
    broker = socket.socket()
    broker.bind(('127.0.0.1', 0))
    broker.listen(4)
    capability = 'ab' * 32
    requests = []
    def serve():
        while True:
            connection, _ = broker.accept()
            with connection, connection.makefile('rb') as stream:
                if stream.readline().decode().strip() != capability:
                    continue
                request = json.loads(stream.readline())
                requests.append(request['kind'])
                print('Fixture prompt:', request['prompt'], flush=True)
                if request['kind'] == 'host_key':
                    assert info['fingerprint'] in request['prompt']
                    reply = 'yes'
                else:
                    reply = "CI-only $ quote' \" test password"
                connection.sendall((reply + '\n').encode())
    threading.Thread(target=serve, daemon=True).start()
    environment = dict(os.environ, SSH_ASKPASS='.\\' + Path(helper).name, SSH_ASKPASS_REQUIRE='force', DISPLAY='fixture',
                       VHTTPD_SSH_ASKPASS_SOCKET=f'tcp://127.0.0.1:{broker.getsockname()[1]}',
                       VHTTPD_SSH_ASKPASS_CAPABILITY=capability)
    result = subprocess.run([ssh, '-vvv', '-T', '-o', 'StrictHostKeyChecking=ask', '-o', f'UserKnownHostsFile="{work / "known_hosts"}"',
                             '-o', 'PreferredAuthentications=password', '-o', 'PubkeyAuthentication=no', '-o', 'KbdInteractiveAuthentication=no',
                             '-o', 'ConnectTimeout=5', '-p', str(info['port']), '-l', 'fixture', '127.0.0.1', '/bin/sh -s'],
                            input=b'printf VHTTPD_FIXTURE_COMMAND\nexit\n', capture_output=True, env=environment, timeout=25, cwd=Path(helper).parent)
    if result.returncode or result.stdout.strip() != b'VHTTPD_FIXTURE_COMMAND':
        print(result.stderr.decode('utf-8', 'replace'))
        raise SystemExit(f'Native SSH failed: exit={result.returncode}, prompts={requests}')
    assert requests == ['host_key', 'password'], requests
    print('PASS native Windows OpenSSH + GUI helper: real first-host confirmation and password authentication')
finally:
    fixture.terminate()
    fixture.wait(timeout=5)
