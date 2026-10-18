#!/usr/bin/env python3
"""Assemble the existing Mac runtime and UI with relocatable dylib references."""
import os
import plistlib
import re
import tempfile
import zipfile
from pathlib import Path
import shutil
import subprocess
import sys


def run(*args):
    return subprocess.check_output(args, text=True, stderr=subprocess.STDOUT)


def dependencies(path):
    return [line.strip().split(' (compatibility', 1)[0]
            for line in run('/usr/bin/otool', '-L', str(path)).splitlines()[1:]]


def stamp_minimum_macos(app, binaries):
    versions = []
    for binary in binaries:
        for command in run('/usr/bin/otool', '-l', str(binary)).split('Load command'):
            field = 'minos' if 'cmd LC_BUILD_VERSION' in command else 'version' if 'cmd LC_VERSION_MIN_MACOSX' in command else None
            if field:
                match = re.search(r'\b' + field + r'\s+(\d+(?:\.\d+){1,2})', command)
                if match:
                    version = tuple(int(part) for part in match[1].split('.'))
                    if version > (15, 0, 0):
                        raise RuntimeError(f'{binary.name} requires macOS {match[1]}, above the 15.0 release target')
                    versions.append(version)
    if not versions:
        raise RuntimeError('Cannot determine minimum macOS from bundled Mach-O files')
    minimum = '.'.join(str(part) for part in max(versions))
    path = app / 'Contents/Info.plist'
    info = plistlib.loads(path.read_bytes())
    info['LSMinimumSystemVersion'] = minimum
    path.write_bytes(plistlib.dumps(info))
    return minimum


def archive(app, output):
    # Keep installation instructions beside the app, available before first launch.
    guide = app / 'Contents/Resources/INSTALL-zh.txt'
    if not guide.is_file():
        raise RuntimeError('Installation instructions are missing from the app')
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', str(app))
    with tempfile.TemporaryDirectory(prefix='vhttpd-release-') as directory:
        staging = Path(directory)
        # Preserve the notarization ticket and macOS metadata when archiving a
        # stapled app; generic filesystem copies can lose extended attributes.
        run('/usr/bin/ditto', str(app), str(staging / app.name))
        run('/usr/bin/ditto', '-c', '-k', '--sequesterRsrc', str(staging), str(output))
    # ditto omits the ZIP UTF-8 filename flag. Add the Chinese guide through
    # zipfile so other unzip tools display its name correctly as well.
    with zipfile.ZipFile(output, 'a', compression=zipfile.ZIP_DEFLATED) as bundle:
        bundle.write(guide, '安装说明.txt')
    print(f'Mac archive with installation instructions: {output}')


def package(root, app):
    runtime = app / 'Contents/Resources/runtime'
    runtime.mkdir(parents=True)
    binary = runtime / 'vhttpd'
    runtime_source = Path(os.environ.get('VHTTPD_PACKAGE_RUNTIME', str(root / 'vhttpd'))).resolve(strict=True)
    shutil.copy2(runtime_source, binary)
    shutil.copytree(root / 'admin/ui', runtime / 'admin/ui')
    libs = runtime / 'lib'
    libs.mkdir()
    copied = {}
    names = {}
    pending = [(runtime_source, binary)]
    modified = []
    while pending:
        source, target = pending.pop()
        target.chmod(target.stat().st_mode | 0o200)
        for dependency in dependencies(source):
            if dependency.startswith(('/usr/lib/', '/System/Library/')):
                continue
            dependency_root = os.environ.get('VHTTPD_MACOS_DEPS')
            if dependency_root:
                candidates = {p.resolve() for p in Path(dependency_root).glob('opt/*/lib/' + Path(dependency).name)}
                if len(candidates) != 1:
                    raise RuntimeError(f'Dependency must resolve uniquely in pinned macOS libraries: {dependency}')
                resolved = candidates.pop()
            else:
                if not os.path.isabs(dependency):
                    raise RuntimeError(f'Unresolved runtime dependency: {dependency}')
                resolved = Path(dependency).resolve(strict=True)
            if resolved == source.resolve():
                continue  # dylib install name, rather than a dependency
            name = resolved.name
            if name in names and names[name] != resolved:
                raise RuntimeError(f'Conflicting library names: {name}')
            names[name] = resolved
            if resolved not in copied:
                dest = libs / name
                shutil.copy2(resolved, dest)
                copied[resolved] = dest
                pending.append((resolved, dest))
            relative = '@loader_path/' + ('lib/' if target == binary else '') + name
            run('/usr/bin/install_name_tool', '-change', dependency, relative, str(target))
        if target != binary:
            run('/usr/bin/install_name_tool', '-id', '@loader_path/' + target.name, str(target))
        modified.append(target)
    for target in modified:
        run('/usr/bin/codesign', '--force', '--sign', '-', str(target))
    # Verify no developer machine paths remain in load commands.
    for target in modified:
        for dependency in dependencies(target):
            if not dependency.startswith(('/usr/lib/', '/System/Library/', '@loader_path/')):
                raise RuntimeError(f'Non-portable dependency: {dependency}')
    minimum = stamp_minimum_macos(app, [app / 'Contents/MacOS/vhttpd-workbench', *modified])
    shutil.copy2(root / 'desktop/assets/INSTALL-zh.txt', app / 'Contents/Resources/INSTALL-zh.txt')
    run('/usr/bin/codesign', '--force', '--deep', '--sign', '-', str(app))
    print(f'Minimum macOS from bundled binaries: {minimum}')
    print(f'Bundled runtime, Admin UI and {len(copied)} libraries: {app}')


if __name__ == '__main__':
    if sys.argv[1] == '--archive':
        archive(Path(sys.argv[2]).resolve(), Path(sys.argv[3]).resolve())
    else:
        package(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
