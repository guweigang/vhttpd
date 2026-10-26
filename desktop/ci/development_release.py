"""Publish immutable public previews from successful CI runs of one commit.

Executed from the default branch by workflow_run; downloaded artifacts are data,
never executable code. PR/fork runs cannot obtain this workflow's write token.
"""
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import subprocess
import tarfile
import zipfile

from macos_release import prepare, digest
from workbench_version import version_metadata

WORKFLOWS = ('workbench-macos-runtime.yml', 'vhttpd-binaries.yml')
RUNTIME_PLATFORMS = ('linux-amd64', 'linux-arm64', 'macos-amd64', 'macos-arm64')
ARTIFACTS = ('workbench-macos-arm64-unsigned-verified',) + tuple('vhttpd-' + p for p in RUNTIME_PLATFORMS)


def eligible(run, repo, default_branch):
    return (run.get('conclusion') == 'success' and run.get('status') == 'completed'
            and run.get('head_repository', {}).get('full_name') == repo
            and (run.get('event') == 'workflow_dispatch' or
                 (run.get('event') == 'push' and run.get('head_branch') == default_branch))
            and re.fullmatch('[0-9a-f]{40}', run.get('head_sha', '')) is not None)


def safe_unpack(archive, destination):
    destination.mkdir(parents=True)
    with zipfile.ZipFile(archive) as bundle:
        infos = bundle.infolist()
        names = [item.filename for item in infos]
        if len(infos) > 20000 or len(set(names)) != len(names) or sum(i.file_size for i in infos) > 536870912:
            raise ValueError('Invalid CI artifact size or duplicate path')
        for item in infos:
            path = PurePosixPath(item.filename)
            mode = item.external_attr >> 16
            if (path.is_absolute() or '..' in path.parts or '\\' in item.filename
                    or any(ord(c) < 32 for c in item.filename)
                    or (mode & 0o170000) not in (0, 0o100000, 0o040000)):
                raise ValueError('Unsafe CI artifact path or file type')
        bundle.extractall(destination)


def validate_runtime(directory, platform, sha):
    if platform not in RUNTIME_PLATFORMS:
        raise ValueError('Unsupported runtime platform')
    archive = directory / ('vhttpd-' + platform + '.tar.gz')
    sums = directory / (archive.name + '.sha256')
    if archive.stat().st_size > 268435456 or sums.read_text().split() != [digest(archive), archive.name]:
        raise ValueError('Runtime checksum mismatch')
    prefix = 'vhttpd-' + platform
    with tarfile.open(archive) as bundle:
        members = bundle.getmembers()
        if len(members) > 20000 or sum(m.size for m in members) > 536870912:
            raise ValueError('Runtime expansion limit exceeded')
        names = [m.name for m in members]
        if len(set(names)) != len(names):
            raise ValueError('Duplicate runtime package path')
        for member in members:
            path = PurePosixPath(member.name)
            if (path.is_absolute() or '..' in path.parts or '\\' in member.name
                    or path.parts[0] != prefix or not (member.isfile() or member.isdir())):
                raise ValueError('Unsafe runtime package')
        manifest = bundle.getmember(prefix + '/runtime-manifest.json')
        if manifest.size > 16384:
            raise ValueError('Runtime manifest too large')
        identity = json.load(bundle.extractfile(manifest))
        if identity.get('source_commit') != sha or identity.get('platform') != platform:
            raise ValueError('Runtime package source/platform mismatch')
        header = bundle.extractfile(prefix + '/vhttpd').read(20)
        if platform.startswith('linux-'):
            machine = 62 if platform == 'linux-amd64' else 183
            if header[:6] != b'\x7fELF\x02\x01' or int.from_bytes(header[18:20], 'little') != machine:
                raise ValueError('Linux ELF architecture mismatch')
        else:
            cpu = 0x01000007 if platform == 'macos-amd64' else 0x0100000c
            if header[:4] != b'\xcf\xfa\xed\xfe' or int.from_bytes(header[4:8], 'little') != cpu:
                raise ValueError('macOS Mach-O architecture mismatch')
        bundle.getmember(prefix + '/admin/ui/index.html')
    return [archive, sums]


def gh(args, output=None):
    return subprocess.run(['gh', *args], stdout=output or subprocess.PIPE,
                          stderr=subprocess.PIPE, text=output is None)


class Publisher:
    def __init__(self, repo, work, command=gh):
        self.repo, self.work, self.command = repo, Path(work), command

    def checked(self, args):
        result = self.command(args)
        if result.returncode:
            raise RuntimeError('GitHub operation failed: ' + str(result.stderr))
        return result.stdout

    def api(self, path):
        return json.loads(self.checked(['api', 'repos/' + self.repo + '/' + path]))

    def optional(self, path):
        result = self.command(['api', 'repos/' + self.repo + '/' + path])
        if result.returncode == 0:
            return json.loads(result.stdout)
        if 'HTTP 404' not in result.stderr:
            raise RuntimeError('Cannot inspect GitHub object')
        return None

    def download(self, artifact, destination):
        if artifact.get('expired') or not 0 < artifact.get('size_in_bytes', 0) <= 536870912:
            raise ValueError('Expired or oversized CI artifact')
        expected = artifact.get('digest', '')
        if not re.fullmatch(r'sha256:[0-9a-f]{64}', expected):
            raise ValueError('CI artifact has no SHA256 identity')
        with destination.open('wb') as output:
            result = self.command(['api', f'repos/{self.repo}/actions/artifacts/{int(artifact["id"])}/zip'], output=output)
        if result.returncode or 'sha256:' + digest(destination) != expected:
            raise ValueError('CI artifact download/digest mismatch')

    def assemble(self, runs, sha):
        self.work.mkdir(parents=True, exist_ok=True)
        directories = {}
        for run in runs:
            artifacts = self.api(f'actions/runs/{run["id"]}/artifacts?per_page=100')['artifacts']
            for name in ARTIFACTS:
                matches = [a for a in artifacts if a['name'] == name and not a.get('expired')]
                if not matches:
                    continue
                if len(matches) != 1 or name in directories:
                    raise ValueError('Ambiguous CI artifact')
                archive = self.work / (name + '.zip')
                self.download(matches[0], archive)
                destination = self.work / name
                safe_unpack(archive, destination)
                directories[name] = destination
        if set(directories) != set(ARTIFACTS):
            raise ValueError('CI run is missing the verified Workbench or complete Linux/macOS runtime artifacts')
        version = version_metadata({'VHTTPD_DEVELOPMENT_BUILD': '1', 'GITHUB_SHA': sha})['version']
        output = self.work / 'assets'
        _, assets = prepare(directories[ARTIFACTS[0]], output, {'GITHUB_SHA': sha, 'VHTTPD_WORKBENCH_VERSION': version})
        for platform in RUNTIME_PLATFORMS:
            for file in validate_runtime(directories['vhttpd-' + platform], platform, sha):
                target = output / file.name
                shutil.copyfile(file, target)
                assets.append(target)
        manifest = output / 'runtime-release.json'
        manifest.write_text(json.dumps({'tag': 'v' + version, 'source_commit': sha,
            'runs': [{'id': r['id'], 'url': r['html_url']} for r in runs],
            'assets': {p.name: digest(p) for p in assets}}, indent=2) + '\n')
        assets.append(manifest)
        sums = output / 'SHA256SUMS'
        sums.write_text(''.join(digest(p) + '  ' + p.name + '\n' for p in sorted(assets)))
        assets.append(sums)
        return 'v' + version, assets

    def publish(self, tag, sha, assets):
        marker = '<!-- vhttpd-development sha=' + sha + ' -->'
        ref = self.optional('git/ref/tags/' + tag)
        if ref is None:
            self.checked(['api', '--method', 'POST', 'repos/' + self.repo + '/git/refs',
                          '-f', 'ref=refs/tags/' + tag, '-f', 'sha=' + sha])
        self.verify_tag(tag, sha)
        existing = self.optional('releases/tags/' + tag)
        if existing:
            if existing.get('target_commitish') != sha or marker not in (existing.get('body') or ''):
                raise ValueError('Refusing unrelated release')
            if not existing.get('draft'):
                expected = {p.name: ('sha256:' + digest(p), p.stat().st_size) for p in assets}
                actual = {a['name']: (a.get('digest'), a['size']) for a in existing.get('assets', [])}
                if actual != expected or not existing.get('prerelease'):
                    raise ValueError('Published development versions are immutable')
                return
        notes = self.work / 'development-notes.txt'
        notes.write_text('vhttpd 开发版 ' + tag + '\n\n源码提交：' + sha + '\n'
            '由同一提交的 CI 成功构建：vhttpd Linux/macOS（amd64、arm64），Workbench macOS arm64。\n'
            'Workbench 包通过 macOS 15/26 运行验收。每个平台运行包均附独立 SHA256 校验文件。\n'
            '公开附件无需 GitHub 登录，可在 Desktop 选择版本或指定此标签。下载后校验 SHA256。\n'
            'Mac 为 unsigned/ad-hoc 开发者预览，首次打开限制见 INSTALL-zh.txt；未承诺 Gatekeeper 放行。\n'
            '开发版可能包含未稳定变更。此版本固定到该提交，不覆盖历史附件。\n\n' + marker + '\n')
        if existing is None:
            self.checked(['release', 'create', tag, '--repo', self.repo, '--verify-tag', '--target', sha,
                          '--draft', '--prerelease', '--latest=false', '--title', '开发版 ' + tag, '--notes-file', str(notes)])
        self.checked(['release', 'upload', tag, '--repo', self.repo, '--clobber', *map(str, assets)])
        self.verify_tag(tag, sha)
        self.checked(['release', 'edit', tag, '--repo', self.repo, '--draft=false', '--prerelease', '--latest=false', '--notes-file', str(notes)])

    def verify_tag(self, tag, sha):
        ref = self.api('git/ref/tags/' + tag)['object']
        if ref.get('type') != 'commit' or ref.get('sha') != sha:
            raise ValueError('Development tag does not identify the accepted source commit')


def main():
    event = json.loads(Path(os.environ['GITHUB_EVENT_PATH']).read_text())
    repo, default = event['repository']['full_name'], event['repository']['default_branch']
    if os.environ.get('GITHUB_EVENT_NAME') == 'workflow_dispatch':
        sha = event.get('inputs', {}).get('source_commit', '')
        if (event.get('inputs', {}).get('release_mode') != 'publish-development'
                or not re.fullmatch('[0-9a-f]{40}', sha)):
            raise ValueError('Manual publication requires publish-development and a full source commit SHA')
    else:
        trigger = event['workflow_run']
        if not eligible(trigger, repo, default):
            raise ValueError('Only successful own-repository default-branch pushes or manual CI builds can publish')
        sha = trigger['head_sha']
    publisher = Publisher(repo, 'development-release')
    runs = []
    for workflow in WORKFLOWS:
        candidates = publisher.api('actions/workflows/' + workflow + '/runs?head_sha=' + sha + '&status=completed&per_page=100')['workflow_runs']
        matching = [r for r in candidates if r.get('head_sha') == sha and eligible(r, repo, default)]
        if not matching:
            if os.environ.get('GITHUB_EVENT_NAME') == 'workflow_dispatch':
                raise ValueError('No successful build for ' + workflow + ' on ' + sha)
            print('Waiting for successful ' + workflow + ' on ' + sha)
            return
        required = {ARTIFACTS[0]} if workflow == WORKFLOWS[0] else set(ARTIFACTS[1:])
        for candidate in sorted(matching, key=lambda r: r['id'], reverse=True):
            artifacts = publisher.api(f'actions/runs/{candidate["id"]}/artifacts?per_page=100')['artifacts']
            if required <= {a['name'] for a in artifacts if not a.get('expired')}:
                runs.append(candidate)
                break
        else:
            if os.environ.get('GITHUB_EVENT_NAME') == 'workflow_dispatch':
                raise ValueError('No complete artifacts for ' + workflow + ' on ' + sha)
            print('Waiting for non-expired package artifacts from ' + workflow)
            return
    tag, assets = publisher.assemble(runs, sha)
    publisher.publish(tag, sha, assets)
    print('Published immutable public development version ' + tag)


if __name__ == '__main__':
    main()
