"""Resolve one version for the tag, app bundle and downloadable archive."""
import json
import os
import re


def version_metadata(env):
    tag = env.get('GITHUB_REF_NAME', '') if env.get('GITHUB_REF_TYPE') == 'tag' else ''
    version = tag[1:] if tag.startswith('v') else env.get('VHTTPD_WORKBENCH_VERSION', '0.1.0')
    if not tag and env.get('VHTTPD_DEVELOPMENT_BUILD') == '1':
        sha = env.get('GITHUB_SHA', '')
        if not re.fullmatch('[0-9a-f]{40}', sha):
            raise ValueError('A development build requires a full source commit')
        version = version.split('-')[0].split('+')[0] + '-dev.g' + sha[:12]
    match = re.fullmatch(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(?:-([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?(?:\+([0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*))?', version)
    if (not match or len(version) > 100 or (tag and tag != 'v' + version)
            or (match[4] and any(p.isdigit() and len(p) > 1 and p.startswith('0') for p in match[4].split('.')))):
        raise ValueError('Expected a SemVer version or tag vMAJOR.MINOR.PATCH[-prerelease]')
    if tag and env.get('VHTTPD_WORKBENCH_VERSION', version) != version:
        raise ValueError('Build version must match the release tag')
    return {'version': version, 'bundle_version': '.'.join(match.group(1, 2, 3)),
            'archive': 'vhttpd-workbench-macos-arm64-' + version + '.zip',
            'tag': tag, 'prerelease': 'true' if match[4] else 'false'}


if __name__ == '__main__':
    import sys
    metadata = version_metadata(os.environ)
    if len(sys.argv) == 3 and sys.argv[1] == '--field':
        print(metadata[sys.argv[2]])
    else:
        print(json.dumps(metadata))
        if os.environ.get('GITHUB_OUTPUT'):
            with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
                output.write(''.join(key + '=' + value + '\n' for key, value in metadata.items()))
