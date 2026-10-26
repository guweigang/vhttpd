"""Verify the actual extracted runtime, including all relocated Mac libraries."""
from pathlib import Path
import platform
import subprocess
import sys
import tarfile
import tempfile


def run(command, **kwargs):
    return subprocess.check_output(command, text=True, timeout=30, **kwargs)


def verify_macos(root):
    binary = root / 'vhttpd'
    for file in [binary, *sorted((root / 'runtime/libs').iterdir())]:
        if not file.is_file():
            raise ValueError('Unexpected library entry: ' + str(file))
        run(['/usr/bin/codesign', '--verify', '--strict', str(file)])
        for line in run(['/usr/bin/otool', '-L', str(file)]).splitlines()[1:]:
            dependency = line.strip().split(' (', 1)[0]
            if dependency.startswith(('/usr/lib/', '/System/Library/', '/Library/Apple/System/Library/')):
                continue
            if dependency.startswith('@loader_path/'):
                target = file.parent / dependency.removeprefix('@loader_path/')
            elif dependency.startswith('@executable_path/'):
                target = binary.parent / dependency.removeprefix('@executable_path/')
            else:
                raise ValueError('Non-portable runtime dependency: ' + dependency)
            target = target.resolve()
            if not target.is_relative_to(root.resolve()) or not target.is_file():
                raise ValueError('Missing bundled dependency: ' + dependency)


def verify_linux(root):
    system = ('libc.so.', 'libm.so.', 'libdl.so.', 'libpthread.so.', 'librt.so.',
              'ld-linux', 'libresolv.so.', 'libutil.so.')
    for file in [root / 'vhttpd', *sorted((root / 'runtime/libs').iterdir())]:
        for line in run(['ldd', str(file)]).splitlines():
            if 'not found' in line:
                raise ValueError('Missing runtime dependency: ' + line.strip())
            dependency = line.split('=>', 1)[-1].strip().split(' ', 1)[0]
            if not dependency.startswith('/'):
                continue
            target = Path(dependency).resolve()
            if not target.is_relative_to(root.resolve()) and not target.name.startswith(system):
                raise ValueError('Unbundled runtime dependency: ' + str(target))


def main():
    archive = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix='vhttpd-package-') as directory:
        destination = Path(directory)
        with tarfile.open(archive) as bundle:
            bundle.extractall(destination, filter='data')
        root = destination / archive.name.removesuffix('.tar.gz')
        if platform.system() == 'Darwin':
            verify_macos(root)
        elif platform.system() == 'Linux':
            verify_linux(root)
        else:
            raise ValueError('Unsupported runtime package OS')
        home = destination / 'home'
        home.mkdir()
        env = {'PATH': '/usr/bin:/bin:/usr/sbin:/sbin', 'HOME': str(home),
               'TMPDIR': str(destination), 'LANG': 'C', 'LC_ALL': 'C'}
        # No development PATH, DYLD overrides or inherited V/Node configuration.
        binary = str(root / 'vhttpd')
        command = [binary]
        if platform.system() == 'Darwin':
            policy = destination / 'no-development.sb'
            policy.write_text('(version 1)(allow default)'
                              '(deny file-read* (subpath "/opt/homebrew") (subpath "/usr/local"))')
            command = ['/usr/bin/sandbox-exec', '-f', str(policy), binary]
        print('Extracted runtime version:', run([*command, '--version'], env=env, cwd=home).strip())
        run([*command, '--help'], env=env, cwd=home)
        if not (root / 'admin/ui/index.html').is_file():
            raise ValueError('Packaged Admin UI is missing')
        print('Extracted standalone runtime: passed')


if __name__ == '__main__':
    main()
