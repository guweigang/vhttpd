"""Prepare accepted Mac assets and publish an owned draft only after upload."""
import hashlib
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import zipfile

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from workbench_version import version_metadata


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def prepare(download, output, env):
    version = version_metadata(env)
    archive = download / version['archive']
    result = json.loads((download / 'acceptance.json').read_text())
    checksum = digest(archive)
    targets = result.get('targets', [])
    if (result.get('archive') != archive.name or result.get('sha256') != checksum
            or result.get('source_commit') != env['GITHUB_SHA']
            or result.get('release_mode') != 'unsigned' or result.get('signature') != 'ad-hoc'
            or len(targets) != 2 or {t['macos'].split('.')[0] for t in targets} != {'15', '26'}
            or any(t['runtime'] != 'passed' or t['arch'] != 'arm64' for t in targets)
            or (download / 'SHA256SUMS').read_text().split() != [checksum, archive.name]):
        raise ValueError('Release must match the accepted unsigned archive, source and both target systems')
    with zipfile.ZipFile(archive) as bundle:
        guide = bundle.read('安装说明.txt').decode('utf-8')
        info = plistlib.loads(bundle.read('vhttpd-workbench.app/Contents/Info.plist'))
    if (archive.name not in guide or '@VERSION@' in guide
            or info.get('VHTTPDReleaseVersion') != version['version']
            or info.get('CFBundleShortVersionString') != version['bundle_version']):
        raise ValueError('App version and installation instructions must match the release version')
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ValueError('Release staging directory must be empty')
    prefix = archive.stem
    shutil.copyfile(archive, output / archive.name)
    (output / (prefix + '-INSTALL-zh.txt')).write_text(guide)
    shutil.copyfile(download / 'acceptance.json', output / (prefix + '-acceptance.json'))
    shutil.copyfile(download / '验收说明.txt', output / (prefix + '-ACCEPTANCE-zh.txt'))
    assets = sorted(output.iterdir())
    sums = output / (prefix + '-SHA256SUMS.txt')
    sums.write_text(''.join(digest(path) + '  ' + path.name + '\n' for path in assets))
    return version, [*assets, sums]


def gh(arguments):
    return subprocess.run(['gh', *arguments], text=True, capture_output=True)


def publish(download, output, env, command=gh):
    if env.get('GITHUB_EVENT_NAME') != 'push' or env.get('GITHUB_REF_TYPE') != 'tag':
        raise ValueError('Only a tag push may publish a release')
    version, assets = prepare(download, output, env)
    tag, sha, repo = version['tag'], env['GITHUB_SHA'], env['GITHUB_REPOSITORY']
    def checked(args):
        result = command(args)
        if result.returncode:
            raise RuntimeError('GitHub release command failed: ' + result.stderr)
        return result.stdout
    def verify_tag():
        obj = json.loads(checked(['api', 'repos/' + repo + '/git/ref/tags/' + tag]))['object']
        for _ in range(10):
            if obj['type'] == 'commit':
                if obj['sha'] != sha:
                    raise ValueError('Remote release tag moved since the accepted build')
                return
            if obj['type'] != 'tag':
                break
            obj = json.loads(checked(['api', 'repos/' + repo + '/git/tags/' + obj['sha']]))['object']
        raise ValueError('Cannot resolve release tag to the accepted commit')
    verify_tag()
    marker = '<!-- vhttpd-macos-ci sha=' + sha + ' -->'
    notes = output.parent / 'macos-release-notes.txt'
    notes.write_text('vhttpd Mac 工作台 ' + version['version'] + '\n\n'
        + 'Apple Silicon arm64，macOS 15.0 及以上。unsigned 开发者预览，无需开发环境。\n'
        + '同一包已通过 macOS 15/26 解压搬移、新建、失败重试、跨 include 发布、重启生效及历史恢复验收。\n'
        + '下载 zip、INSTALL-zh.txt 和 SHA256SUMS.txt；校验文件同时覆盖安装说明和验收记录。\n'
        + '没有 Developer ID 签名或 Apple 公证，首次打开可能受系统拦截；请先阅读安装说明。\n'
        + 'Finder、目标系统窗口和浏览器首次操作未纳入 CI 自动化验收。\n\n' + marker + '\n')
    existing = command(['api', 'repos/' + repo + '/releases/tags/' + tag])
    if existing.returncode == 0:
        release = json.loads(existing.stdout)
        if (not release.get('draft') or release.get('target_commitish') != sha
                or marker not in (release.get('body') or '')):
            raise ValueError('Refusing to replace a published release or an unrelated draft')
    elif 'HTTP 404' in existing.stderr:
        checked(['release', 'create', tag, '--repo', repo, '--verify-tag', '--target', sha,
                 '--draft', '--title', 'vhttpd ' + tag, '--notes-file', str(notes),
                 '--prerelease=' + version['prerelease']])
    else:
        raise RuntimeError('Unable to inspect existing GitHub release: ' + existing.stderr)
    checked(['release', 'upload', tag, '--repo', repo, '--clobber', *map(str, assets)])
    verify_tag()
    checked(['release', 'edit', tag, '--repo', repo, '--notes-file', str(notes),
             '--draft=false', '--prerelease=' + version['prerelease']])


if __name__ == '__main__':
    operation = publish if sys.argv[1] == 'publish' else prepare if sys.argv[1] == 'prepare' else None
    if operation is None:
        raise ValueError('Expected prepare or publish')
    operation(Path(sys.argv[2]), Path(sys.argv[3]), os.environ)
