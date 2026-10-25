#!/usr/bin/env python3
"""Verify Mac Desktop's SSH workflow against a real Linux process in OrbStack.

Uses private keys/configuration and an extracted Ubuntu sshd. No SSH service is
installed/enabled and no user SSH configuration is changed.
"""
import argparse
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time


def stop(child):
    if child is None or child.poll() is not None:
        return
    child.terminate()
    try:
        child.wait(timeout=5)
    except subprocess.TimeoutExpired:
        child.kill()
        child.wait()


def run(args):
    def remote(*command, data=None):
        return subprocess.check_output(
            ['orb', '-m', args.vm, *map(str, command)], input=data, text=True,
            stderr=subprocess.STDOUT,
        )

    def python(script, *parameters, data=None):
        return remote('python3', '-c', script, *parameters, data=data)

    python('from pathlib import Path; import sys; runtime=Path(sys.argv[1]); '
           'assert runtime.is_file(), "Linux runtime executable is missing"; '
           'assert (runtime.parent/"admin/ui/index.html").is_file(), '
           '"Use a complete runtime layout: admin/ui must be beside the executable"',
           args.runtime)
    root = python('import tempfile; from pathlib import Path; '
                  'print(tempfile.mkdtemp(prefix=".vhttpd-ssh-fixture-",dir=Path.home()))').strip()
    setup = json.loads(python('import socket,json,getpass; ports=[]\n'
                             'for _ in range(3):\n'
                             ' s=socket.socket(); s.bind(("127.0.0.1",0)); '
                             'ports.append(s.getsockname()[1]); s.close()\n'
                             'print(json.dumps({"ports":ports,"user":getpass.getuser()}))'))
    admin, web, ssh_port = setup['ports']
    app = sshd = test = None
    with tempfile.TemporaryDirectory(prefix='vhttpd-linux-ssh-', dir='/private/tmp') as directory:
        local = Path(directory)
        try:
            subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '',
                            '-f', str(local / 'client')], check=True)
            remote('/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', root + '/host')
            host_key = python('from pathlib import Path; import sys; '
                              'print(Path(sys.argv[1]).read_text())', root + '/host.pub').split()
            files = {
                'vhttpd.toml': f'''version=2
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
''',
                'routes.toml': '''[adapters.reply]
kind="fixed-response"
options.status="200"
options.body="before"
[[pipelines]]
id="hello"
ingress="listener:web"
egress="adapter:reply"
[pipelines.match]
paths=["/"]
''',
                'extra.toml': '''[engines.js]
kind="vjsx"
entry="main.mts"
runtime_profile="node"
thread_count=1
[adapters.js]
kind="http-handler"
engine="engine:js"
[[pipelines]]
id="vjsx"
ingress="listener:web"
egress="adapter:js"
[pipelines.match]
paths=["/vjsx"]
''',
                'main.mts': 'export default function handle(ctx) { '
                            'return ctx.json({ok:true,stage:"vjsx-ready"},200); }\n',
                'authorized_keys': (local / 'client.pub').read_text(),
                'sshd_config': f'''Port {ssh_port}
ListenAddress 127.0.0.1
HostKey {root}/host
PidFile {root}/sshd.pid
AuthorizedKeysFile {root}/authorized_keys
SshdSessionPath {args.sshd_tools}/usr/lib/openssh/sshd-session
SshdAuthPath {args.sshd_tools}/usr/lib/openssh/sshd-auth
StrictModes yes
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers {setup['user']}
AllowTcpForwarding local
LogLevel VERBOSE
''',
            }
            python('import sys,json; from pathlib import Path; root=Path(sys.argv[1]); '
                   '[(root/name).write_text(value) for name,value in json.load(sys.stdin).items()]',
                   root, data=json.dumps(files))
            (local / 'known_hosts').write_text(
                f'[127.0.0.1]:{ssh_port} {host_key[0]} {host_key[1]}\n')
            # OrbStack's built-in SSH endpoint supports command execution. Use
            # it only as a byte transport to the independent Linux OpenSSH server;
            # all tested forwarding/authentication is handled by that server.
            (local / 'ssh_config').write_text(f'''Host vhttpd-fixture
 HostName 127.0.0.1
 Port {ssh_port}
 User {setup['user']}
 IdentityFile {local}/client
 IdentitiesOnly yes
 UserKnownHostsFile {local}/known_hosts
 ProxyCommand /usr/bin/ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes orb /usr/bin/nc 127.0.0.1 %p
''')
            wrapper = local / 'ssh'
            wrapper.write_text('#!/bin/sh\nexec /usr/bin/ssh -F '
                               + shlex.quote(str(local / 'ssh_config')) + ' "$@"\n')
            wrapper.chmod(0o700)
            with (local / 'initial.log').open('w') as log, (local / 'ssh.log').open('w') as ssh_log:
                app = subprocess.Popen([
                    'orb', '-m', args.vm, '/usr/bin/env',
                    'VHTTPD_RESTART_FIXTURE=retained', '/bin/bash', '-c',
                    'cd "$1" && exec "$2" --config "$1/vhttpd.toml" --manual-restart',
                    'vhttpd-fixture', root, args.runtime,
                ], stdout=log, stderr=log)
                sshd = subprocess.Popen([
                    'orb', '-m', args.vm, '/usr/bin/env',
                    'LD_LIBRARY_PATH=' + args.sshd_tools + '/usr/lib/aarch64-linux-gnu',
                    args.sshd_tools + '/usr/sbin/sshd', '-D', '-e',
                    '-f', root + '/sshd_config',
                ], stdout=ssh_log, stderr=subprocess.STDOUT)
                time.sleep(1)
                if sshd.poll() is not None:
                    raise RuntimeError((local / 'ssh.log').read_text())
                environment = os.environ.copy()
                environment.update(VHTTPD_REMOTE_TEST_HOST='vhttpd-fixture',
                                   VHTTPD_REMOTE_TEST_PORT=str(admin),
                                   VHTTPD_REMOTE_TEST_SSH=str(wrapper))
                test = subprocess.Popen([str(args.host_test.resolve())], env=environment)
                deadline = time.monotonic() + 150
                while test.poll() is None:
                    app.poll()
                    if time.monotonic() > deadline:
                        raise RuntimeError('Mac host integration timed out')
                    time.sleep(0.1)
                if test.returncode:
                    raise RuntimeError('Mac host integration failed')
                result = json.loads(python(
                    'import urllib.request,json,os; from pathlib import Path; '
                    f'root=Path({root!r}); pid=int((root/"instance.pid").read_text()); '
                    'cwd=os.readlink(f"/proc/{pid}/cwd"); '
                    'kept=b"VHTTPD_RESTART_FIXTURE=retained" in Path(f"/proc/{pid}/environ").read_bytes().split(b"\\0"); '
                    f'base="http://127.0.0.1:{web}"; '
                    'a=urllib.request.urlopen(base+"/",timeout=5).read().decode(); '
                    'b=json.load(urllib.request.urlopen(base+"/vjsx",timeout=5)); '
                    'print(json.dumps({"response":a,"vjsx":b,"cwd":cwd,"environment_preserved":kept}))'))
                assert result['response'] == 'after', result
                assert result['cwd'] == root, result
                assert result['environment_preserved'], result
                assert result['vjsx'] == {'ok': True, 'stage': 'vjsx-ready'}, result
                assert app.poll() is not None, 'Original terminal process has not exited'
                print('PASS Linux: original terminal exited; detached replacement serves '
                      'published configuration and real vjsx handler after SSH reconnect; '
                      'original working directory and environment preserved')
                if args.output:
                    args.output.parent.mkdir(parents=True, exist_ok=True)
                    args.output.write_text(json.dumps({
                        'ok': True, 'vm': args.vm, 'runtime': args.runtime,
                        'linux': remote('uname', '-srm').strip(),
                        'v': remote('/home/guweigang/v/v', 'version').strip(),
                        'response': result, 'original_terminal_exit': app.returncode,
                    }, indent=2) + '\n')
        except BaseException:
            print('Fixture diagnostics:', (local / 'initial.log').read_text()[-3000:])
            print((local / 'ssh.log').read_text()[-3000:])
            print(python('from pathlib import Path; import sys; root=Path(sys.argv[1]); '
                         'print("\\n".join(str(p)+"\\n"+p.read_text()[-3000:] '
                         'for p in root.rglob("runtime.log")))', root))
            raise
        finally:
            stop(test)
            # Signal only processes whose command line still belongs to our
            # private fixture, then close the Orb command wrappers.
            python('import os,signal,sys,shutil; from pathlib import Path; root=Path(sys.argv[1]);\n'
                   'for name in ["instance.pid","sshd.pid"]:\n'
                   ' p=root/name\n'
                   ' if not p.exists(): continue\n'
                   ' try:\n'
                   '  pid=int(p.read_text().strip()); cmd=Path(f"/proc/{pid}/cmdline").read_bytes()\n'
                   '  if str(root).encode() in cmd: os.kill(pid,signal.SIGTERM)\n'
                   ' except (ProcessLookupError,FileNotFoundError): pass\n'
                   'shutil.rmtree(root)', root)
            stop(sshd)
            stop(app)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--vm', default='ubuntu')
    parser.add_argument('--runtime', required=True)
    parser.add_argument('--sshd-tools', required=True,
                        help='Linux extraction root of the Ubuntu openssh-server package')
    parser.add_argument('--host-test', type=Path, required=True)
    parser.add_argument('--output', type=Path)
    run(parser.parse_args())


if __name__ == '__main__':
    main()
