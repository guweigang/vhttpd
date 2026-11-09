import base64
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import time


# The shell owns the directory until the bounded Hub process has exited.
SUPERVISOR = """
trap 'kill -TERM "$child" 2>/dev/null; wait "$child"' TERM HUP INT
/usr/bin/timeout --kill-after=5s 3600s "$1" --config "$2" &
child=$!
wait "$child"
rm -rf -- "$3"
"""


def identity(pid, directory):
    proc = Path(f'/proc/{pid}')
    try:
        if proc.joinpath('cwd').resolve(strict=True) != directory:
            return ''
        return proc.joinpath('stat').read_text().rsplit(')', 1)[1].split()[19]
    except (OSError, IndexError):
        return ''


def remove_hub(directory):
    if not directory.exists():
        return
    if directory.is_symlink():
        raise RuntimeError()
    record = directory / 'owner.json'
    if record.exists():
        pid, stamp = json.loads(record.read_text())
        if stamp and identity(pid, directory) == stamp:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            for _ in range(55):
                if identity(pid, directory) != stamp:
                    break
                time.sleep(.1)
            else:
                raise RuntimeError()
    if directory.exists():
        shutil.rmtree(directory)


def manage(root, hub_id, binary, token, template, remove):
    try:
        os.umask(0o077)
        parent = Path(root).resolve(strict=True) / 'mcp-hubs'
        if parent.is_symlink():
            raise RuntimeError()
        directory = parent / hub_id
        if remove:
            remove_hub(directory)
            print('{}')
            return
        parent.mkdir(exist_ok=True)
        directory.mkdir()
        child = None
        try:
            with socket.socket() as web, socket.socket() as carrier:
                web.bind(('127.0.0.1', 0))
                carrier.bind(('127.0.0.1', 0))
                ports = dict(http_port=web.getsockname()[1], carrier_port=carrier.getsockname()[1])
            config = base64.b64decode(template).decode()
            config = (config.replace('port = 19931', 'port = CARRIER_PORT', 1)
                      .replace('port = 19930', 'port = ' + str(ports['http_port']), 1)
                      .replace('CARRIER_PORT', str(ports['carrier_port']), 1)
                      .replace('/tmp/vhttpd_mcp_relay_public_v2', 'hub')
                      .replace('change-me', token).replace('"/vhttpd/relay"', '"/vhttpd/relay/desktop-mcp"'))
            path = directory / 'hub.toml'
            path.write_text(config)
            with (directory / 'process.log').open('wb') as log:
                child = subprocess.Popen(
                    ['/bin/sh', '-c', SUPERVISOR, 'mcp-hub', binary, str(path), str(directory)],
                    cwd=directory, stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
            stamp = identity(child.pid, directory)
            if not stamp:
                raise RuntimeError()
            (directory / 'owner.json').write_text(json.dumps([child.pid, stamp]))
            for _ in range(25):
                if child.poll() is not None:
                    raise RuntimeError()
                try:
                    for port in ports.values():
                        with socket.create_connection(('127.0.0.1', port), timeout=.1):
                            pass
                    print(json.dumps(ports))
                    return
                except OSError:
                    time.sleep(.1)
            raise RuntimeError()
        except Exception:
            if child is not None and child.poll() is None:
                child.terminate()
                child.wait(timeout=6)
            remove_hub(directory)
            raise
    except Exception:
        print('VHTTPD_ERROR:remote_mcp_hub_operation_failed')
        raise SystemExit(1)
