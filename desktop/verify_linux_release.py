#!/usr/bin/env python3
"""Exercise an extracted Linux package with developer trees hidden by bwrap."""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile


def verify(archive):
    expected = archive.with_name(archive.name + '.sha256').read_text().split()
    if len(expected) != 2 or expected[1] != archive.name:
        raise RuntimeError('Invalid archive checksum sidecar')
    if hashlib.sha256(archive.read_bytes()).hexdigest() != expected[0]:
        raise RuntimeError('Archive checksum mismatch')
    with tempfile.TemporaryDirectory(prefix='vhttpd-linux-installed-') as folder:
        root = Path(folder)
        with tarfile.open(archive) as package:
            members = package.getmembers()
            if not members or any(not (entry.isdir() or entry.isfile()) for entry in members):
                raise RuntimeError('Unexpected archive entry type')
            top = {Path(entry.name).parts[0] for entry in members}
            if len(top) != 1:
                raise RuntimeError('Expected one complete package directory')
            package.extractall(root, filter='data')
        app = root / top.pop()
        host = app / 'vhttpd-workbench'
        runtime = app / 'runtime/vhttpd'
        for executable in (host, runtime):
            if not os.access(executable, os.X_OK):
                raise RuntimeError(f'Executable permission missing: {executable.name}')
            libraries = subprocess.check_output(['ldd', str(executable)], text=True)
            if 'not found' in libraries:
                raise RuntimeError(libraries)
            for line in libraries.splitlines():
                if '=>' not in line:
                    continue
                name, resolved = line.split('=>', 1)
                # glibc remains an explicit OS requirement; other ELF dependencies
                # must resolve inside this moved download, not the build machine.
                if name.strip().startswith(('libc.so.', 'libm.so.', 'libdl.so.',
                                             'libpthread.so.', 'librt.so.', 'libresolv.so.',
                                             'libutil.so.')):
                    continue
                if not resolved.strip().startswith(str(app) + '/'):
                    raise RuntimeError('Unbundled ELF dependency: ' + line)
        for asset in ('resources/vhttpd-mark.png', 'fonts/NotoSansCJKsc-Regular.otf',
                      'fonts/NotoSansCJKsc-Bold.otf', 'fonts/NotoSansCJK-LICENSE.txt',
                      'fonts/RobotoMono-Regular.ttf', '安装说明.txt'):
            if not (app / asset).is_file():
                raise RuntimeError('Missing package asset: ' + asset)
        home = root / 'Fresh Home'
        home.mkdir()
        env = {'HOME': str(home), 'PATH': '/usr/bin:/bin', 'LANG': 'C.UTF-8',
               'VHTTPD_DESKTOP_REGISTRY': str(home / 'projects.json')}
        isolated = ['bwrap', '--ro-bind', '/', '/', '--bind', '/tmp', '/tmp']
        # Orb mounts /Users; GitHub's Ubuntu runners do not have that directory.
        # Creating a missing mount point under the read-only root is invalid.
        for developer_tree in ('/Users', '/home', '/usr/local'):
            if Path(developer_tree).is_dir():
                isolated += ['--tmpfs', developer_tree]
        hidden_tools = set()
        for tool in ('v', 'vlang', 'node', 'nodejs', 'npm', 'npx', 'cc', 'gcc', 'g++',
                     'c++', 'clang', 'make', 'cmake'):
            executable = shutil.which(tool)
            if executable:
                target = str(Path(executable).resolve())
                if not target.startswith(('/home/', '/usr/local/')) and target not in hidden_tools:
                    isolated += ['--ro-bind', '/dev/null', target]
                    hidden_tools.add(target)
        service_archive = root / ('vhttpd-linux-' +
                                  ('arm64' if platform.machine() == 'aarch64' else 'amd64') + '.tar.gz')
        with tarfile.open(service_archive, 'w:gz') as bundle:
            bundle.add(app / 'runtime', arcname=service_archive.name[:-7])
        service_archive.with_name(service_archive.name + '.sha256').write_text(
            hashlib.sha256(service_archive.read_bytes()).hexdigest() + '  ' + service_archive.name + '\n')
        env['VHTTPD_RUNTIME_TEST_ARCHIVE'] = str(service_archive)
        for mode in ('--smoke', '--persistent-status-smoke', '--shared-relay-smoke', '--runtime-smoke'):
            try:
                output = subprocess.check_output([*isolated, '--', str(host), mode],
                                                 env=env, cwd=root, text=True,
                                                 stderr=subprocess.STDOUT, timeout=240)
            except subprocess.CalledProcessError as error:
                print(error.output, end='', flush=True)
                raise RuntimeError(f'Isolated {mode} failed with exit {error.returncode}') from error
            print(output, end='', flush=True)
        print('PASS SHA256, safe extraction, moved ELF dependencies, packaged fonts and licenses')
        print('PASS fresh HOME, system PATH, developer trees and compiler/Node access hidden by bubblewrap')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('archive', type=Path)
    args = parser.parse_args()
    verify(args.archive.resolve(strict=True))
