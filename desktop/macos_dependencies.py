#!/usr/bin/env python3
"""Fetch pinned macOS libraries without installing or changing Homebrew."""
import hashlib
import json
import os
from pathlib import Path
import sys
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
LOCK = json.loads((ROOT / 'desktop/macos-dependencies.json').read_text())
CACHE = ROOT / '.deps/macos-sequoia'


def prepare():
    CACHE.mkdir(parents=True, exist_ok=True)
    for package in LOCK['packages']:
        name = package['name']
        archive = CACHE / (package['sha256'] + '.tar.gz')
        if not archive.exists():
            repository = package['url'].split('/v2/')[1].split('/blobs/')[0]
            auth_url = 'https://ghcr.io/token?service=ghcr.io&scope=repository:' + repository + ':pull'
            token = json.load(urllib.request.urlopen(auth_url))['token']
            request = urllib.request.Request(package['url'], headers={'Authorization': 'Bearer ' + token})
            with urllib.request.urlopen(request) as response:
                data = response.read()
            if hashlib.sha256(data).hexdigest() != package['sha256']:
                raise RuntimeError('Dependency checksum mismatch: ' + name)
            temporary = archive.with_suffix('.download')
            temporary.write_bytes(data)
            temporary.replace(archive)
        if hashlib.sha256(archive.read_bytes()).hexdigest() != package['sha256']:
            raise RuntimeError('Cached dependency checksum mismatch: ' + name)
        destination = CACHE / package['sha256']
        if not destination.exists():
            with tempfile.TemporaryDirectory(dir=CACHE) as directory:
                with tarfile.open(archive) as bundle:
                    bundle.extractall(directory, filter='data')
                Path(directory).rename(destination)
        versions = [p for p in (destination / name).iterdir() if p.is_dir()]
        if len(versions) != 1:
            raise RuntimeError('Unexpected bottle layout: ' + name)
        opt = CACHE / 'opt' / name
        opt.parent.mkdir(exist_ok=True)
        if not opt.is_symlink():
            opt.symlink_to(versions[0])
        print('Verified ' + name + ' ' + package['version'], flush=True)
    # Some bottles intentionally leave relocation placeholders for brew to replace.
    for pc in (CACHE / 'opt').glob('*/lib/pkgconfig/*.pc'):
        text = pc.read_text()
        text = text.replace('@@HOMEBREW_PREFIX@@', '/opt/homebrew')
        for package in LOCK['packages']:
            name = package['name']
            text = text.replace('/opt/homebrew/opt/' + name, str(CACHE / 'opt' / name))
            text = text.replace('@@HOMEBREW_CELLAR@@/' + name, str(CACHE / package['sha256'] / name))
        pc.write_text(text)


def compiler(arguments):
    def relocate(argument):
        if argument == '-w':
            return None  # Keep availability diagnostics enabled for older targets.
        for package in LOCK['packages']:
            name = package['name']
            argument = argument.replace('/opt/homebrew/opt/' + name + '/', str(CACHE / 'opt' / name) + '/')
            argument = argument.replace('/opt/homebrew/Cellar/' + name + '/', str(CACHE / package['sha256'] / name) + '/')
        for alias in ['openssl', 'openssl@3']:
            argument = argument.replace('/opt/homebrew/opt/' + alias + '/', str(CACHE / 'opt/openssl@4') + '/')
        # V has fallback search paths in addition to package-specific paths.
        if argument in ['-I/opt/homebrew/include', '-L/opt/homebrew/lib']:
            return None
        if argument.startswith(('-I/opt/local/', '-L/opt/local/', '-I/usr/local/', '-L/usr/local/')):
            return None  # Ignore V's fallback MacPorts/Intel Homebrew paths.
        if '/opt/homebrew/' in argument:
            raise RuntimeError('Unisolated compiler dependency: ' + argument)
        return argument
    args = [value for argument in arguments if (value := relocate(argument)) is not None]
    args += ['-mmacosx-version-min=' + LOCK['deployment_target'], '-Werror=unguarded-availability', '-Werror=unguarded-availability-new']
    if '-c' not in args and '-E' not in args:
        args += ['-Wl,-no_warn_duplicate_libraries', '-Wl,-fatal_warnings']
    os.execv('/usr/bin/clang', ['/usr/bin/clang', *args])


if __name__ == '__main__':
    if sys.argv[1:] and sys.argv[1] == '--cc':
        compiler(sys.argv[2:])
    else:
        prepare()
