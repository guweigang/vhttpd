#!/usr/bin/env python3
"""Run real SSH acceptance without changing system/user SSH configuration."""

import argparse
import getpass
import os
import pathlib
import shlex
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request
import secrets


def free_port():
    with socket.socket() as connection:
        connection.bind(("127.0.0.1", 0))
        return connection.getsockname()[1]


def stop(child):
    if child is None or child.poll() is not None:
        return
    child.terminate()
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()


def run(runtime, host_test, password_auth=False, unknown_host=False, sshd_tools=None):
    root = pathlib.Path(tempfile.mkdtemp(prefix="vhttpd-ssh-e2e-"))
    app = sshd = test = None
    password_server = None
    password = secrets.token_urlsafe(24) if password_auth else ''
    admin, web, ssh_port = free_port(), free_port(), free_port()
    try:
        (root / "vhttpd.toml").write_text(f'''version=2
include=["routes.toml","extra.toml"]
[server]
pid_file="{root}/instance.pid"
[listeners.admin]
protocol="http"
host="127.0.0.1"
port={admin}
[control]
listener="listener:admin"
token="remote-fixture-private"
[listeners.web]
protocol="http"
host="127.0.0.1"
port={web}
''')
        (root / "routes.toml").write_text('''[adapters.reply]
kind="fixed-response"
options.status="200"
options.body="before"
[[pipelines]]
id="hello"
ingress="listener:web"
egress="adapter:reply"
[pipelines.match]
paths=["*"]
''')
        (root / "extra.toml").write_text("# second include\n")
        for name in ["host", "client"]:
            subprocess.run([
                "/usr/bin/ssh-keygen", "-q", "-t", "ed25519", "-N", "",
                "-f", str(root / name),
            ], check=True)
        (root / "sshd_config").write_text(f'''Port {ssh_port}
ListenAddress 127.0.0.1
HostKey {root}/host
PidFile {root}/sshd.pid
AuthorizedKeysFile {root}/client.pub
StrictModes no
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers {getpass.getuser()}
AllowTcpForwarding local
LogLevel VERBOSE
''')
        if sshd_tools is not None and (sshd_tools / 'usr/lib/openssh/sshd-session').is_file():
            with (root / "sshd_config").open('a') as config:
                config.write(f'SshdSessionPath {sshd_tools}/usr/lib/openssh/sshd-session\n'
                             f'SshdAuthPath {sshd_tools}/usr/lib/openssh/sshd-auth\n')
        key = (root / "host.pub").read_text().split()
        (root / "known_hosts").write_text(
            f"[127.0.0.1]:{ssh_port} {key[0]} {key[1]}\n"
        )
        if password_auth:
            from password_ssh_fixture import PasswordSSHFixture
            password_server = PasswordSSHFixture(ssh_port, admin, password)
            (root / 'known_hosts').write_text(password_server.known_host(ssh_port))
        if unknown_host:
            (root / 'known_hosts').write_text('')
        subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'rsa' if password_auth else 'ed25519',
                        '-N', '', '-f', str(root / 'changed-host')], check=True)
        changed = (root / 'changed-host.pub').read_text().split()
        (root / 'changed_known_hosts').write_text(f'[127.0.0.1]:{ssh_port} {changed[0]} {changed[1]}\n')
        (root / "ssh_config").write_text(f'''Host vhttpd-fixture
 HostName 127.0.0.1
 Port {ssh_port}
 User {getpass.getuser()}
 IdentityFile {root}/client
 IdentitiesOnly yes
 UserKnownHostsFile {root}/known_hosts
''')
        wrapper = root / "ssh"
        wrapper.write_text(
            "#!/bin/sh\nexec /usr/bin/ssh -F "
            + shlex.quote(str(root / "ssh_config")) + ' "$@"\n'
        )
        wrapper.chmod(0o700)
        with (root / "initial.log").open("w") as log, (root / "ssh.log").open("w") as ssh_log:
            app = subprocess.Popen([
                str(runtime.resolve()), "--config", str(root / "vhttpd.toml"),
                "--manual-restart",
            ], stdout=log, stderr=log)
            if not password_auth:
                sshd = subprocess.Popen([
                    str(sshd_tools / 'usr/sbin/sshd') if sshd_tools else "/usr/sbin/sshd",
                    "-D", "-e", "-f", str(root / "sshd_config"),
                ], stdout=ssh_log, stderr=subprocess.STDOUT)
            time.sleep(1)
            if sshd is not None and sshd.poll() is not None:
                raise RuntimeError((root / "ssh.log").read_text())
            environment = os.environ.copy()
            environment.update(
                VHTTPD_REMOTE_TEST_HOST="vhttpd-fixture",
                VHTTPD_REMOTE_TEST_PORT=str(admin),
                VHTTPD_REMOTE_TEST_SSH=str(wrapper),
                VHTTPD_REMOTE_TEST_AUTH='password' if password_auth else 'key',
                VHTTPD_REMOTE_TEST_UNKNOWN_HOST='1' if unknown_host else '',
                VHTTPD_REMOTE_TEST_KNOWN_HOSTS=str(root / 'known_hosts'),
                VHTTPD_REMOTE_TEST_CHANGED_HOST_KEY=str(root / 'changed_known_hosts'),
            )
            test = subprocess.Popen([str(host_test.resolve())], env=environment,
                                    stdin=subprocess.PIPE if password_auth else None)
            if password_auth:
                test.stdin.write((password + '\n').encode())
                test.stdin.close()
            deadline = time.monotonic() + 150
            while test.poll() is None:
                # Reap the original process so its restart helper can observe exit.
                app.poll()
                if time.monotonic() > deadline:
                    raise RuntimeError("host integration timed out")
                time.sleep(0.1)
            if test.returncode:
                raise RuntimeError("host integration failed\n" + (root / "ssh.log").read_text()[-4000:])
            with urllib.request.urlopen(f"http://127.0.0.1:{web}/", timeout=5) as response:
                assert response.read() == b"after"
            if password_auth:
                # Initial login, reconnect, two instance-origin checks, wrong Admin token, wrong password.
                assert password_server.auth_attempts == 6, f'Unexpected authentication before trust or after key change: {password_server.auth_attempts}'
                print('PASS no password authentication before host trust or after changed-key rejection')
            print("PASS actual business response after browser publication + SSH restart")
    finally:
        stop(test)
        stop(sshd)
        if password_server is not None:
            password_server.close()
        if app is not None:
            app.poll()
        pid_file = root / "instance.pid"
        if pid_file.exists():
            try:
                os.kill(int(pid_file.read_text().strip()), 15)
            except ProcessLookupError:
                pass
        stop(app)
        shutil.rmtree(root)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--runtime", required=True, type=pathlib.Path)
    parser.add_argument("--host-test", required=True, type=pathlib.Path)
    parser.add_argument("--sshd-tools", type=pathlib.Path,
                        help="Optional extracted Linux OpenSSH package; no system SSH changes")
    parser.add_argument('--password', action='store_true', help='Use a password-only SSH fixture')
    parser.add_argument('--unknown-host', action='store_true', help='Verify in-workbench first-use confirmation and cancellation')
    args = parser.parse_args()
    if not args.runtime.is_file() or not args.host_test.is_file():
        parser.error("build the runtime and host test executable first")
    run(args.runtime, args.host_test, args.password, args.unknown_host, args.sshd_tools)


if __name__ == "__main__":
    main()
