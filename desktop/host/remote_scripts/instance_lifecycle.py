"""Fixed-purpose Linux managed-instance process probe and graceful stop; stdin JSON only."""
import hashlib
import json
import os
from pathlib import Path
import select
import signal
import socket
import sys


def run(req):
    root = Path.home() / '.local/share/vhttpd-workbench/instances'
    name = req['name']
    if not name or len(name) > 64 or not name[0].isascii() or not name[0].isalnum() or any(not c.isascii() or not (c.isalnum() or c in '-_') for c in name):
        raise ValueError('invalid_instance_name')
    project = root / name
    if root.is_symlink() or root.resolve() != root:
        raise ValueError('unsafe_instances_root')
    if req['action'] == 'create':
        if os.path.lexists(project):
            raise ValueError('instance_already_exists')
        ports = req['ports']
        sockets = []
        try:
            for port in ports:
                if not 1024 <= port <= 65535:
                    raise ValueError('invalid_port')
                sock = socket.socket()
                sockets.append(sock)
                sock.bind(('0.0.0.0', port))
        finally:
            for sock in sockets:
                sock.close()
        return {'state': 'absent', 'fingerprint': ''}
    if project.is_symlink() or project.resolve() != project or not project.is_dir():
        raise ValueError('unsafe_managed_instance')
    for filename, expected in [('.desktop-instance-id', req['id']), ('.desktop-runtime-id', req['runtime_id'])]:
        marker = project / filename
        if marker.is_symlink() or marker.read_text() != expected or marker.stat().st_uid != os.getuid():
            raise ValueError('managed_instance_identity_changed')
    binary = Path(req['binary'])
    if binary.is_symlink() or not binary.is_file():
        raise ValueError('unsafe_runtime_binary')
    processes = []
    for proc in Path('/proc').glob('[0-9]*'):
        try:
            if (proc / 'cwd').resolve() != project:
                continue
            executable = os.readlink(proc / 'exe')
            if Path(executable.removesuffix(' (deleted)')).name != 'vhttpd':
                continue
            # Refuse a foreign runtime or invocation sharing this directory.
            args = (proc / 'cmdline').read_bytes().split(b'\0')
            config = str(project / 'vhttpd.toml').encode()
            if executable != str(binary) or b'--config' not in args or args.index(b'--config') + 1 >= len(args) or args[args.index(b'--config') + 1] != config or proc.stat().st_uid != os.getuid():
                raise ValueError('foreign_process_in_instance')
            stat = (proc / 'stat').read_text().rsplit(')', 1)[1].split()
            if stat[0] == 'Z':
                continue
            processes.append((int(proc.name), stat[19]))
        except (FileNotFoundError, ProcessLookupError, PermissionError):
            continue
    if len(processes) > 1:
        raise ValueError('multiple_instance_processes')
    fingerprint = hashlib.sha256(json.dumps(processes).encode()).hexdigest()
    result = {'state': 'running' if processes else 'stopped', 'fingerprint': fingerprint}
    if req['action'] != 'stop':
        return result
    lock = project / '.desktop-runtime-lock'
    lock.mkdir(mode=0o700)
    try:
        if req['fingerprint'] != fingerprint:
            raise ValueError('process_changed_since_preflight')
        if not processes:
            return result
        if not hasattr(os, 'pidfd_open') or not hasattr(signal, 'pidfd_send_signal'):
            raise ValueError('safe_stop_requires_linux_pidfd')
        pid, start = processes[0]
        fd = os.pidfd_open(pid)
        try:
            # Recheck identity after acquiring pidfd, preventing PID reuse.
            proc = Path('/proc') / str(pid)
            if (proc / 'stat').read_text().rsplit(')', 1)[1].split()[19] != start or (proc / 'cwd').resolve() != project or os.readlink(proc / 'exe') != str(binary):
                raise ValueError('process_changed_since_preflight')
            signal.pidfd_send_signal(fd, signal.SIGTERM)
            poll = select.poll()
            poll.register(fd, select.POLLIN)
            if not poll.poll(15000):
                raise ValueError('graceful_stop_pending_check_instance_status')
        finally:
            os.close(fd)
        return {'state': 'stopped', 'fingerprint': ''}
    finally:
        lock.rmdir()


if __name__ == '__main__':
    try:
        print(json.dumps(run(json.load(sys.stdin))))
    except Exception as error:
        # Never reflect config, paths, credentials or arbitrary exception details.
        code = str(error) if isinstance(error, ValueError) else 'instance_probe_failed'
        print(json.dumps({'error': code}))
        sys.exit(1)
