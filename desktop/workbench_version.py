"""Resolve one version for the tag, app bundle and downloadable archive."""
import json
import os
import re
from pathlib import Path


def repository_version():
    """Desktop owns this manifest independently of the service's v.mod."""
    return (Path(__file__).resolve().parent / 'version.txt').read_text().strip()


SEMVER = re.compile(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?')


def parse_version(version):
    match = SEMVER.fullmatch(version)
    if (not match or len(version) > 100 or
            (match[4] and any(p.isdigit() and len(p) > 1 and p.startswith('0') for p in match[4].split('.')))):
        raise ValueError('Expected a SemVer version')
    return match


def version_metadata(env):
    tag = env.get('GITHUB_REF_NAME', '') if env.get('GITHUB_REF_TYPE') == 'tag' else ''
    runtime_tag = None
    if tag.startswith('desktop-v'):
        version = tag[len('desktop-v'):]
        if env.get('VHTTPD_WORKBENCH_VERSION', version) != version:
            raise ValueError('Build version must match the Desktop release tag')
    else:
        if tag:
            if not tag.startswith('v'):
                raise ValueError('Expected desktop-vMAJOR.MINOR.PATCH or runtime tag vMAJOR.MINOR.PATCH')
            runtime_tag = parse_version(tag[1:])
        version = env['VHTTPD_WORKBENCH_VERSION'] if 'VHTTPD_WORKBENCH_VERSION' in env else repository_version()
    parse_version(version)
    if not tag and env.get('VHTTPD_DEVELOPMENT_BUILD') == '1':
        sha = env.get('GITHUB_SHA', '')
        if not re.fullmatch('[0-9a-f]{40}', sha):
            raise ValueError('A development build requires a full source commit')
        version = version.split('-')[0].split('+')[0] + '-dev.g' + sha[:12]
    match = parse_version(version)
    return {'version': version, 'bundle_version': '.'.join(match.group(1, 2, 3)),
            'archive': 'vhttpd-workbench-macos-arm64-' + version + '.zip',
            'tag': tag, 'prerelease': 'true' if match[4] or (runtime_tag and runtime_tag[4]) else 'false'}


def windows_resource(metadata):
    numbers = tuple(int(part) for part in metadata['bundle_version'].split('.')) + (0,)
    if any(part > 65535 for part in numbers):
        raise ValueError('Windows version fields must fit in 16 bits')
    numeric = ','.join(map(str, numbers))
    icon = (Path(__file__).resolve().parent / 'assets/vhttpd-windows.ico').as_posix()
    version = metadata['version']
    return f'''#pragma code_page(65001)
1 ICON "{icon}"
1 VERSIONINFO
 FILEVERSION {numeric}
 PRODUCTVERSION {numeric}
 FILEFLAGSMASK 0x3fL
 FILEFLAGS {"0x2L" if metadata['prerelease'] == 'true' else "0x0L"}
 FILEOS 0x40004L
 FILETYPE 0x1L
BEGIN
 BLOCK "StringFileInfo"
 BEGIN
  BLOCK "040904B0"
  BEGIN
   VALUE "FileDescription", "vhttpd Desktop\\0"
   VALUE "FileVersion", "{version}\\0"
   VALUE "ProductName", "vhttpd Desktop\\0"
   VALUE "ProductVersion", "{version}\\0"
   VALUE "OriginalFilename", "vhttpd-workbench.exe\\0"
  END
 END
 BLOCK "VarFileInfo"
 BEGIN
  VALUE "Translation", 0x409, 1200
 END
END
'''


if __name__ == '__main__':
    import sys
    metadata = version_metadata(os.environ)
    if len(sys.argv) == 3 and sys.argv[1] == '--windows-resource':
        Path(sys.argv[2]).write_text(windows_resource(metadata), encoding='utf-8')
    elif len(sys.argv) == 3 and sys.argv[1] == '--field':
        print(metadata[sys.argv[2]])
    else:
        print(json.dumps(metadata))
        if os.environ.get('GITHUB_OUTPUT'):
            with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
                output.write(''.join(key + '=' + value + '\n' for key, value in metadata.items()))
