"""Publish complete stable runtime/Desktop releases from same-run accepted artifacts."""
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tarfile
import zipfile

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / 'desktop' / 'ci'))
from macos_release import prepare as prepare_macos


def plan(env, root=ROOT):
    tag = env['GITHUB_REF_NAME']
    match = re.fullmatch(r'(desktop-v|v)(\d+\.\d+\.\d+)', tag)
    if not match or env.get('GITHUB_REF_TYPE') != 'tag':
        raise ValueError('A stable vMAJOR.MINOR.PATCH or desktop-vMAJOR.MINOR.PATCH tag is required')
    product = 'desktop' if match[1] == 'desktop-v' else 'runtime'
    version = match[2]
    expected = ((root / 'desktop/version.txt').read_text().strip() if product == 'desktop'
                else re.search(r"version:\s*'([^']+)'", (root / 'v.mod').read_text())[1])
    if version != expected:
        raise ValueError(f'{tag} does not match {product} source version {expected}')
    return product, version


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def one(root, name):
    paths = list(root.rglob(name))
    if len(paths) != 1:
        raise ValueError(f'Expected exactly one {name}, got {len(paths)}')
    return paths[0]


def checked_archive(root, name):
    path = one(root, name)
    fields = Path(str(path) + '.sha256').read_text().split()
    if len(fields) != 2 or fields[0] != digest(path) or Path(fields[1].lstrip('*')).name != name:
        raise ValueError(f'Archive checksum mismatch: {name}')
    return path


def member(path, suffix):
    if path.name.endswith('.zip'):
        with zipfile.ZipFile(path) as archive:
            names = [n for n in archive.namelist() if n.endswith('/' + suffix)]
            if len(names) != 1:
                raise ValueError(f'Expected one {suffix} in {path.name}')
            if archive.getinfo(names[0]).file_size > 1024 * 1024:
                raise ValueError(f'Oversized {suffix} in {path.name}')
            return archive.read(names[0])
    with tarfile.open(path) as archive:
        entries = [m for m in archive.getmembers() if m.isfile() and m.name.endswith('/' + suffix)]
        if len(entries) != 1 or entries[0].size > 1024 * 1024:
            raise ValueError(f'Expected one small {suffix} in {path.name}')
        return archive.extractfile(entries[0]).read()


def prepare(download, output, env):
    product, version = plan(env)
    if output.exists() and any(output.iterdir()):
        raise ValueError('Release staging directory must be empty')
    output.mkdir(parents=True, exist_ok=True)
    sha = env['GITHUB_SHA']
    lock = dict(line.split('=', 1) for line in (ROOT / 'scripts/ci/toolchain.env').read_text().splitlines()
                if line and not line.startswith('#'))
    platforms = ['macos-amd64', 'macos-arm64', 'linux-amd64', 'linux-arm64', 'windows-amd64']
    if product == 'runtime':
        for platform in platforms:
            extension = 'zip' if platform.startswith('windows') else 'tar.gz'
            path = checked_archive(download, f'vhttpd-{platform}.{extension}')
            manifest = json.loads(member(path, 'runtime-manifest.json'))
            info = manifest.get('build_info', manifest)
            if (manifest.get('source_commit') != sha or info.get('version') != version
                    or manifest.get('v_commit') != lock['V_COMMIT']
                    or manifest.get('vjsx_commit') != lock['VJSX_COMMIT']
                    or info.get('gc') != 'boehm' or info.get('gc_enabled') is not True
                    or (not platform.startswith('windows') and manifest.get('platform') != platform)):
                raise ValueError(f'Runtime version, source, toolchain or GC mismatch: {platform}')
            shutil.copyfile(path, output / path.name)
            shutil.copyfile(Path(str(path) + '.sha256'), output / (path.name + '.sha256'))
    else:
        platforms = ['macos-arm64', 'linux-amd64', 'linux-arm64', 'windows-amd64']
        accepted = one(download, 'workbench-macos-arm64-unsigned-verified')
        mac_output = output / 'macos'
        prepare_macos(accepted, mac_output, env)
        for path in mac_output.iterdir():
            shutil.move(str(path), output / path.name)
        mac_output.rmdir()
        for platform in platforms[1:]:
            extension = 'zip' if platform.startswith('windows') else 'tar.gz'
            path = checked_archive(download, f'vhttpd-workbench-{platform}-{version}.{extension}')
            if member(path, 'VERSION.txt').decode().strip() != 'Desktop ' + version:
                raise ValueError(f'Desktop version mismatch: {platform}')
            if platform.startswith('windows'):
                info = json.loads(member(path, 'build-info.json'))
                if info.get('commit') != sha or info.get('version') != version or info.get('v') != lock['V_COMMIT']:
                    raise ValueError('Windows Desktop source or toolchain mismatch')
            shutil.copyfile(path, output / path.name)
            shutil.copyfile(Path(str(path) + '.sha256'), output / (path.name + '.sha256'))
    guide = ('vhttpd ' + version + '\n\nmacOS / Linux：解压对应架构的 tar.gz，按包内 scripts/install_runtime.sh 安装，'
             '或直接运行包内 vhttpd。Windows：解压 zip，按包内安装说明运行 vhttpd.exe。\n'
             '运行包包含原生依赖，无需安装 V、Node 或编译工具。\n' if product == 'runtime' else
             'vhttpd Desktop ' + version + '\n\nmacOS：Apple Silicon arm64，macOS 15 及以上；解压 zip 后将 App 移入 Applications。\n'
             'Linux：按 CPU 架构选择 amd64 / arm64，解压后运行工作台启动脚本。\n'
             'Windows：解压 zip 后运行 vhttpd-workbench.exe，保留 resources、tools 和 DLL。\n'
             'Windows 本地 vhttpd 运行包独立下载；三端均无需 V、Node 或编译环境。\n')
    guide += ('\n先核对 SHA256SUMS。macOS 包未经 Developer ID 签名或 Apple 公证；首次打开可能被 Gatekeeper 拦截，'
              '请按包内安装说明在系统设置中允许打开，勿关闭系统整体安全检查。\n'
              'macOS 15/26 的无开发环境运行验收已覆盖；浏览器下载后 Finder/Gatekeeper 首次放行不在自动化验收范围内。\n')
    (output / 'INSTALL-zh.txt').write_text(guide)
    manifest = {'product': product, 'version': version, 'source_commit': sha,
                'platforms': platforms, 'v_commit': lock['V_COMMIT'], 'vjsx_commit': lock['VJSX_COMMIT'],
                'run_url': f"https://github.com/{env['GITHUB_REPOSITORY']}/actions/runs/{env['GITHUB_RUN_ID']}"}
    (output / 'release-manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    files = sorted(output.iterdir())
    (output / 'SHA256SUMS').write_text(''.join(f'{digest(p)}  {p.name}\n' for p in files))
    return product, version, sorted(output.iterdir())


def gh(args):
    return subprocess.run(['gh', *args], capture_output=True, text=True)


def publish(download, output, env, command=gh):
    if env.get('GITHUB_EVENT_NAME') != 'push' or env.get('GITHUB_REF_TYPE') != 'tag':
        raise ValueError('Stable releases require a tag push')
    product, version, assets = prepare(download, output, env)
    repo, sha, tag = env['GITHUB_REPOSITORY'], env['GITHUB_SHA'], env['GITHUB_REF_NAME']

    def checked(args):
        result = command(args)
        if result.returncode:
            raise RuntimeError(result.stderr)
        return result.stdout

    def verify_tag():
        obj = json.loads(checked(['api', f'repos/{repo}/git/ref/tags/{tag}']))['object']
        for _ in range(10):
            if obj['type'] == 'commit':
                if obj['sha'] != sha:
                    raise ValueError('Release tag moved after build')
                return
            if obj['type'] != 'tag':
                break
            obj = json.loads(checked(['api', f'repos/{repo}/git/tags/{obj["sha"]}']))['object']
        raise ValueError('Cannot resolve release tag')

    verify_tag()
    marker = f'<!-- vhttpd-stable-ci sha={sha} -->'
    notes = output.parent / 'release-notes.txt'
    title = ('vhttpd Desktop ' if product == 'desktop' else 'vhttpd ') + version
    notes.write_text(title + '\n\n三端运行包已通过 CI 构建、解压启动及配置发布/重启生效验收。\n'
                     '下载对应平台附件，先阅读 INSTALL-zh.txt 并核对 SHA256SUMS。\n'
                     'macOS 包未经 Apple 签名/公证，首次打开请按安装说明操作。\n\n' + marker + '\n')
    existing = command(['api', f'repos/{repo}/releases/tags/{tag}'])
    if existing.returncode == 0:
        data = json.loads(existing.stdout)
        if not data.get('draft') or data.get('target_commitish') != sha or marker not in (data.get('body') or ''):
            raise ValueError('Refusing to replace a public release or unrelated draft')
    elif 'HTTP 404' in existing.stderr:
        checked(['release', 'create', tag, '--repo', repo, '--verify-tag', '--target', sha,
                 '--draft', '--title', title, '--notes-file', str(notes), '--prerelease=false', '--latest=false'])
    else:
        raise RuntimeError(existing.stderr)
    checked(['release', 'upload', tag, '--repo', repo, '--clobber', *map(str, assets)])
    # Compare remote asset sizes before the draft becomes public.
    remote = json.loads(checked(['api', f'repos/{repo}/releases/tags/{tag}']))
    sizes = {a['name']: a['size'] for a in remote['assets']}
    if sizes != {p.name: p.stat().st_size for p in assets}:
        raise ValueError('Uploaded release assets are incomplete')
    verify_tag()
    checked(['release', 'edit', tag, '--repo', repo, '--draft=false', '--prerelease=false',
             '--latest=' + ('true' if product == 'runtime' else 'false')])


if __name__ == '__main__':
    if sys.argv[1] == 'plan':
        product, version = plan(os.environ)
        if os.environ.get('GITHUB_OUTPUT'):
            with open(os.environ['GITHUB_OUTPUT'], 'a') as output:
                output.write(f'product={product}\nversion={version}\n')
        print(product, version)
    elif sys.argv[1] == 'publish':
        publish(Path(sys.argv[2]), Path(sys.argv[3]), os.environ)
    else:
        raise ValueError('Expected plan or publish')
