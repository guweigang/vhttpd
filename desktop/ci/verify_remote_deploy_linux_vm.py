#!/usr/bin/env python3
"""Mac SSH -> empty Linux HOME -> CI package -> vjsx -> publish/restart.

Uses a private unprivileged sshd and an isolated HOME. Does not install services,
change user SSH configuration, or access any saved Desktop credentials.
"""
import argparse
import base64
import hashlib
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile
import time


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--runtime', required=True)
    parser.add_argument('--host-test', type=Path, required=True)
    parser.add_argument('--sshd-tools', required=True)
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()

    def vm(*cmd, data=None):
        return subprocess.check_output(['orb', '-m', 'ubuntu', *map(str, cmd)],
                                       input=data, text=True, stderr=subprocess.STDOUT)

    def py(code, *params, data=None):
        return vm('python3', '-c', code, *params, data=data)

    root = py('import tempfile; print(tempfile.mkdtemp(prefix=".vhttpd-deploy-",dir="/home/guweigang"))').strip()
    sshd = None
    with tempfile.TemporaryDirectory(prefix='vhttpd-deploy-', dir='/private/tmp') as folder:
        local = Path(folder)
        try:
            setup = json.loads(py('import socket,json,getpass; sockets=[]\n'
                                  'for _ in range(3):\n s=socket.socket();s.bind(("127.0.0.1",0));sockets.append(s)\n'
                                  'print(json.dumps({"ports":[s.getsockname()[1] for s in sockets],"user":getpass.getuser()}))'))
            ssh_port, web, admin = setup['ports']
            subprocess.run(['/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', str(local/'client')], check=True)
            vm('/usr/bin/ssh-keygen', '-q', '-t', 'ed25519', '-N', '', '-f', root+'/host')
            pub = py('from pathlib import Path; import sys; print(Path(sys.argv[1]).read_text())', root+'/host.pub').split()
            # ForceCommand supplies a genuinely empty HOME and no development PATH
            # to both scp and shell commands, without creating a system account.
            wrapper = f'''#!/bin/sh
export HOME={shlex.quote(root+'/home')}
export PATH=/usr/bin:/bin
unset VJS_QUICKJS_PATH VJS_QUICKJS_LIB_PATH VMODULES LD_LIBRARY_PATH
cd "$HOME"
exec /bin/sh -c "$SSH_ORIGINAL_COMMAND"
'''
            config = f'''Port {ssh_port}
ListenAddress 127.0.0.1
HostKey {root}/host
PidFile {root}/sshd.pid
AuthorizedKeysFile {root}/authorized_keys
SshdSessionPath {args.sshd_tools}/usr/lib/openssh/sshd-session
SshdAuthPath {args.sshd_tools}/usr/lib/openssh/sshd-auth
ForceCommand {root}/command
StrictModes yes
UsePAM no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
AllowUsers {setup['user']}
AllowTcpForwarding local
LogLevel VERBOSE
'''
            py('from pathlib import Path;import json,sys;root=Path(sys.argv[1]);(root/"home").mkdir();'
               '[(root/k).write_text(v) for k,v in json.load(sys.stdin).items()];(root/"command").chmod(0o700)',
               root, data=json.dumps({'command':wrapper, 'sshd_config':config, 'authorized_keys':(local/'client.pub').read_text()}))
            # Build the exact artifact layout used by GitHub CI, with native ELF
            # libraries. Build tools stay outside the isolated target HOME.
            repo = str(Path(__file__).resolve().parents[2])
            vm('/bin/bash', '-c', '''set -eu
mkdir -p "$1/package/vhttpd-linux-arm64/runtime" "$1/package/vhttpd-linux-arm64/admin"
cp "$2" "$1/package/vhttpd-linux-arm64/vhttpd"
cp -R "$3/admin/ui" "$1/package/vhttpd-linux-arm64/admin/ui"
bash "$3/scripts/bundle_runtime_libs.sh" "$1/package/vhttpd-linux-arm64/vhttpd" "$1/package/vhttpd-linux-arm64/runtime/libs"
tar -czf "$1/vhttpd-linux-arm64.tar.gz" -C "$1/package" vhttpd-linux-arm64
''', 'fixture', root, args.runtime, repo)
            archive = local/'vhttpd-linux-arm64.tar.gz'
            archive.write_bytes(base64.b64decode(py('from pathlib import Path;import base64,sys;print(base64.b64encode(Path(sys.argv[1]).read_bytes()).decode())',root+'/'+archive.name)))
            subprocess.run(['/usr/bin/tar','-tzf',str(archive)],stdout=subprocess.DEVNULL,check=True)
            (local/(archive.name+'.sha256')).write_text(hashlib.sha256(archive.read_bytes()).hexdigest()+'  '+archive.name+'\n')
            (local/'known_hosts').write_text('')
            (local/'changed_hosts').write_text(f'[127.0.0.1]:{ssh_port} '+ ' '.join((local/'client.pub').read_text().split()[:2])+'\n')
            (local/'ssh_config').write_text(f'''Host vhttpd-fixture
 HostName 127.0.0.1
 Port {ssh_port}
 User {setup['user']}
 IdentityFile {local}/client
 IdentitiesOnly yes
 UserKnownHostsFile {local}/known_hosts
 ProxyCommand /usr/bin/ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes orb /usr/bin/nc 127.0.0.1 %p
''')
            for name in ['ssh','scp']:
                (local/name).write_text('#!/bin/sh\nexec /usr/bin/'+name+' -F '+shlex.quote(str(local/'ssh_config'))+' "$@"\n')
                (local/name).chmod(0o700)
            with (local/'sshd.log').open('w') as log:
                sshd = subprocess.Popen(['orb','-m','ubuntu','/usr/bin/env',
                    'LD_LIBRARY_PATH='+args.sshd_tools+'/usr/lib/aarch64-linux-gnu',
                    args.sshd_tools+'/usr/sbin/sshd','-D','-e','-f',root+'/sshd_config'],stdout=log,stderr=log)
                time.sleep(1)
                assert sshd.poll() is None, (local/'sshd.log').read_text()
                env = dict(os.environ, VHTTPD_SERVER_TEST_SSH=str(local/'ssh'), VHTTPD_SERVER_TEST_SCP=str(local/'scp'),
                           VHTTPD_SERVER_TEST_PACKAGE=str(archive), VHTTPD_SERVER_TEST_WEB=str(web), VHTTPD_SERVER_TEST_ADMIN=str(admin),
                           VHTTPD_SERVER_TEST_KNOWN_HOSTS=str(local/'known_hosts'), VHTTPD_SERVER_TEST_CHANGED_HOST=str(local/'changed_hosts'),
                           VHTTPD_DESKTOP_DATA_DIR=str(local/'registry'))
                subprocess.run([str(args.host_test.resolve())], env=env, check=True, timeout=240)
                result = json.loads(py('import urllib.request,json,sys;'
                    'print(json.dumps(json.load(urllib.request.urlopen("http://127.0.0.1:"+sys.argv[1]+"/",timeout=5))))',web))
                result = {'ok':True,'linux':vm('uname','-srm').strip(),'response':result,
                          'archive_sha256':hashlib.sha256(archive.read_bytes()).hexdigest(),
                          'coverage':['empty HOME','bundled ELF dependencies','SHA256','vjsx create/start','browser SSO',
                                      'cross-include validate/publish','manual restart','whole-project effectiveness','SSH session reuse',
                                      'first fingerprint cancel/confirm','changed fingerprint blocked','port conflict and same-instance retry']}
                if args.output:
                    args.output.parent.mkdir(parents=True,exist_ok=True)
                    args.output.write_text(json.dumps(result,indent=2)+'\n')
                print('PASS remote deployment acceptance')
        except BaseException:
            if (local/'sshd.log').exists(): print((local/'sshd.log').read_text()[-2500:])
            print(py('from pathlib import Path;import sys;root=Path(sys.argv[1]);'
                     'print("\\n".join(p.read_text()[-2000:] for p in root.rglob("process.log")))',root))
            raise
        finally:
            py('import os,signal,shutil,sys;from pathlib import Path;root=Path(sys.argv[1]);\n'
               'for path in Path("/proc").glob("[0-9]*/cmdline"):\n'
               ' try:\n'
               '  if int(path.parent.name)!=os.getpid() and str(root).encode() in path.read_bytes() and b"vhttpd" in path.read_bytes(): os.kill(int(path.parent.name),signal.SIGTERM)\n'
               ' except (FileNotFoundError,ProcessLookupError,PermissionError): pass\n'
               'shutil.rmtree(root)',root)
            if sshd:
                sshd.terminate()
                try: sshd.wait(timeout=5)
                except subprocess.TimeoutExpired: sshd.kill();sshd.wait()


if __name__ == '__main__':
    main()
