"""Attach target-system evidence to a CI-built unsigned preview download."""
import hashlib
import json
import os
from pathlib import Path
import re
import sys


def collect(download, evidence, env=os.environ):
    archives = list(download.glob('*.zip'))
    if len(archives) != 1:
        raise ValueError('Expected exactly one CI-built download')
    archive = archives[0]
    checksum = hashlib.sha256(archive.read_bytes()).hexdigest()
    checksum_fields = (download / 'SHA256SUMS').read_text().split()
    if checksum_fields != [checksum, archive.name]:
        raise ValueError('Download checksum does not match SHA256SUMS')
    targets = []
    for major in ('15', '26'):
        report = evidence / ('macos-' + major)
        if (report / 'result.txt').read_text().strip() != 'PASS':
            raise ValueError('macOS ' + major + ' runtime acceptance did not pass')
        environment = (report / 'environment.txt').read_text()
        version = re.search(r'^ProductVersion:\s*(\S+)', environment, re.M)
        if (not version or version[1].split('.')[0] != major
                or 'arm64' not in environment.splitlines()
                or 'archive_sha256=' + checksum not in environment.splitlines()):
            raise ValueError('Target OS, architecture or candidate identity mismatch')
        policy_exit = int((report / 'gatekeeper-exit.txt').read_text())
        policy = (report / 'gatekeeper.txt').read_text()
        if policy_exit == 0 and re.search(r'^source=Notarized Developer ID$', policy, re.M):
            raise ValueError('Expected an unsigned preview, received a notarized candidate')
        targets.append({'macos': version[1], 'arch': 'arm64', 'runtime': 'passed',
                        'gatekeeper_exit': policy_exit, 'gatekeeper_output': policy.strip(),
                        'gatekeeper_download_approval': 'not_verified'})
    result = {'release_mode': 'unsigned', 'signature': 'ad-hoc', 'archive': archive.name,
              'sha256': checksum, 'source_commit': env.get('GITHUB_SHA'),
              'run_url': env.get('GITHUB_SERVER_URL', 'https://github.com') + '/' + env.get('GITHUB_REPOSITORY', '') + '/actions/runs/' + env.get('GITHUB_RUN_ID', ''),
              'targets': targets, 'coverage': ['extract and relocate complete app',
              'fresh HOME and system PATH without development tools', 'create both vjsx templates',
              'startup failure and retry', 'cross-include publish and restart effectiveness',
              'persistent history and restore'],
              'not_verified': ['Finder first launch', 'target-system GUI and browser interaction',
                               'Gatekeeper approval after browser download']}
    (download / 'acceptance.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    (download / '验收说明.txt').write_text(
        'vhttpd Mac 工作台 — 无 Apple 证书的开发者预览\n\n'
        + '下载包：' + archive.name + '\nSHA256：' + checksum + '\n'
        + '源码提交：' + (result['source_commit'] or 'unknown') + '\nCI：' + result['run_url'] + '\n\n'
        + '此下载包已在 macOS ' + ' / '.join(t['macos'] for t in targets) + ' arm64 上通过运行验收。\n'
        + '覆盖解压搬移、新建项目、启动失败重试、跨 include 发布、重启生效及版本恢复。\n'
        + '运行时禁止访问开发目录与 Homebrew，并禁止执行编译工具。\n\n'
        + '包使用 ad-hoc 签名，没有 Developer ID 或 Apple 公证。运行通过不代表下载后系统自动放行。\n'
        + 'Finder 首次打开、目标系统窗口和浏览器操作尚未由本次 CI 验收。\n'
        + '解压包内的“安装说明.txt”列有首次打开和使用步骤；无需安装 V、Node、Homebrew 或 Xcode。\n'
        + '系统拦截请先核对来源与校验值，再由本人决定是否针对该应用允许打开。\n'
        + '无需关闭全局安全检查或执行清除隔离标记的命令。\n')
    return result


if __name__ == '__main__':
    collect(Path(sys.argv[1]), Path(sys.argv[2]))
