import io
import json
import plistlib
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import zipfile

import publish_release as release


class StableReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.download = self.root / 'downloads'
        self.download.mkdir()
        self.version = release.re.search(r"version:\s*'([^']+)'", (release.ROOT / 'v.mod').read_text())[1]
        self.env = {'GITHUB_REF_NAME': 'v' + self.version, 'GITHUB_REF_TYPE': 'tag',
                    'GITHUB_SHA': 'a' * 40, 'GITHUB_REPOSITORY': 'example/vhttpd',
                    'GITHUB_EVENT_NAME': 'push', 'GITHUB_RUN_ID': '42'}
        self.lock = dict(line.split('=', 1) for line in (release.ROOT / 'scripts/ci/toolchain.env').read_text().splitlines()
                         if line and not line.startswith('#'))
        for platform in ['macos-amd64', 'macos-arm64', 'linux-amd64', 'linux-arm64', 'windows-amd64']:
            self.archive(platform)

    def archive(self, platform, **changes):
        manifest = {'source_commit': 'a' * 40, 'platform': platform,
                    'v_commit': self.lock['V_COMMIT'], 'vjsx_commit': self.lock['VJSX_COMMIT'],
                    'build_info': {'version': self.version, 'gc': 'boehm', 'gc_enabled': True}, **changes}
        payload = json.dumps(manifest).encode()
        name = 'vhttpd-' + platform
        if platform.startswith('windows'):
            path = self.download / (name + '.zip')
            with zipfile.ZipFile(path, 'w') as archive:
                archive.writestr(name + '/runtime-manifest.json', payload)
        else:
            path = self.download / (name + '.tar.gz')
            with tarfile.open(path, 'w:gz') as archive:
                member = tarfile.TarInfo(name + '/runtime-manifest.json')
                member.size = len(payload)
                archive.addfile(member, io.BytesIO(payload))
        Path(str(path) + '.sha256').write_text(release.digest(path) + '  ' + path.name + '\n')
        return path

    def test_stable_tags_match_independent_source_versions(self):
        self.assertEqual(release.plan(self.env), ('runtime', self.version))
        desktop = (release.ROOT / 'desktop/version.txt').read_text().strip()
        self.assertEqual(release.plan(dict(self.env, GITHUB_REF_NAME='desktop-v' + desktop)), ('desktop', desktop))
        for tag in ['main', 'v9.9.9', 'v' + self.version + '-rc.1', 'desktop-v9.9.9']:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                release.plan(dict(self.env, GITHUB_REF_NAME=tag))

    def test_complete_runtime_assets_have_all_platforms_and_checksums(self):
        product, version, assets = release.prepare(self.download, self.root / 'output', self.env)
        self.assertEqual((product, version), ('runtime', self.version))
        self.assertEqual(sum(p.name.endswith(('.tar.gz', '.zip')) for p in assets), 5)
        for line in (self.root / 'output/SHA256SUMS').read_text().splitlines():
            checksum, name = line.split('  ')
            self.assertEqual(checksum, release.digest(self.root / 'output' / name))

    def test_missing_corrupt_or_wrong_source_asset_blocks_staging(self):
        path = self.download / 'vhttpd-windows-amd64.zip'
        original = path.read_bytes()
        path.write_bytes(b'corrupt')
        with self.assertRaises(ValueError):
            release.prepare(self.download, self.root / 'corrupt', self.env)
        path.write_bytes(original)
        path.unlink()
        with self.assertRaises(ValueError):
            release.prepare(self.download, self.root / 'missing', self.env)
        self.archive('windows-amd64', source_commit='b' * 40)
        with self.assertRaises(ValueError):
            release.prepare(self.download, self.root / 'wrong-source', self.env)

    def test_wrong_version_sdk_or_disabled_gc_is_rejected(self):
        for index, changes in enumerate([
            {'vjsx_commit': 'b' * 40}, {'v_commit': 'b' * 40},
            {'build_info': {'version': '9.9.9', 'gc': 'boehm', 'gc_enabled': True}},
            {'build_info': {'version': self.version, 'gc': 'none', 'gc_enabled': False}},
        ]):
            self.archive('windows-amd64', **changes)
            with self.subTest(changes=changes), self.assertRaises(ValueError):
                release.prepare(self.download, self.root / str(index), self.env)

    def github_mock(self, calls, output, complete=True, existing=False):
        draft = {'id': 123, 'tag_name': self.env['GITHUB_REF_NAME'], 'draft': True,
                 'target_commitish': 'a' * 40, 'body': '<!-- vhttpd-stable-ci sha=' + 'a' * 40 + ' -->'}
        def github(args):
            calls.append(args)
            if args[0] == 'api' and '/git/ref/tags/' in args[1]:
                data = {'object': {'type': 'commit', 'sha': 'a' * 40}}
            elif args[0] == 'api' and '/releases?' in args[1]:
                created = any(a[:2] == ['release', 'create'] for a in calls)
                data = [[draft]] if existing or created else [[]]
            elif args[0] == 'api' and args[1].endswith('/releases/123'):
                assets = [{'name': p.name, 'size': p.stat().st_size} for p in output.iterdir()] if complete else []
                data = dict(draft, assets=assets)
            elif args[0] == 'api':
                raise AssertionError('Draft must be read by ID, never by tag: ' + repr(args))
            else:
                return subprocess.CompletedProcess(args, 0, '', '')
            return subprocess.CompletedProcess(args, 0, json.dumps(data), '')
        return github

    def test_incomplete_upload_never_publishes_draft(self):
        calls = []; output = self.root / 'publish'
        with self.assertRaises(ValueError):
            release.publish(self.download, output, self.env, command=self.github_mock(calls, output, complete=False))
        self.assertTrue(any(a[:2] == ['release', 'upload'] for a in calls))
        self.assertFalse(any(a[:2] == ['release', 'edit'] for a in calls))

    def test_complete_verified_upload_is_published_after_tag_recheck(self):
        calls = []; output = self.root / 'publish'
        release.publish(self.download, output, self.env, command=self.github_mock(calls, output))
        writes = [a for a in calls if a[0] == 'release']
        self.assertEqual([a[1] for a in writes], ['create', 'upload', 'edit'])
        self.assertIn('--draft', writes[0])
        self.assertIn('--draft=false', writes[-1])
        self.assertIn('--prerelease=false', writes[-1])
        self.assertIn('--latest=true', writes[-1])
        self.assertEqual(sum(a[0] == 'api' and '/git/ref/tags/' in a[1] for a in calls), 2)

    def test_failed_publication_reuses_owned_draft_without_creating_duplicate(self):
        calls = []; output = self.root / 'publish'
        release.publish(self.download, output, self.env, command=self.github_mock(calls, output, existing=True))
        self.assertEqual([a[1] for a in calls if a[0] == 'release'], ['upload', 'edit'])

    def test_resume_reuses_its_owned_draft_without_creating_another(self):
        calls = []
        output = self.root / 'publish'
        release.publish(self.download, output, self.env,
                        command=self.github_mock(calls, output, existing=True))
        self.assertEqual([a[1] for a in calls if a[0] == 'release'], ['upload', 'edit'])
        self.assertFalse(any('/releases/tags/' in a[1] for a in calls if a[0] == 'api'))

    def test_resume_requires_all_platform_acceptance_and_unchanged_tag(self):
        env = dict(self.env, GITHUB_ENV=str(self.root / 'job-env'))
        jobs = [{'id': index + 1, 'name': name, 'conclusion': 'success'} for index, name in enumerate([
            'plan', 'runtime / macos-arm64', 'runtime / macos-amd64', 'runtime / linux-amd64',
            'runtime / linux-arm64', 'runtime-windows / windows-amd64'])]
        run = {'event': 'push', 'path': '.github/workflows/release.yml', 'status': 'completed',
               'repository': {'full_name': env['GITHUB_REPOSITORY']},
               'head_branch': env['GITHUB_REF_NAME'], 'head_sha': env['GITHUB_SHA']}
        ref = {'object': {'type': 'commit', 'sha': env['GITHUB_SHA']}}
        def github(args):
            data = ([{'jobs': jobs}] if '/jobs?' in args[1] else
                    ref if '/git/ref/' in args[1] else run)
            return subprocess.CompletedProcess(args, 0, json.dumps(data), '')
        jobs[-1]['conclusion'] = 'failure'
        with self.assertRaises(ValueError):
            release.resume('42', env, command=github)
        self.assertFalse((self.root / 'job-env').exists())
        jobs[-1]['conclusion'] = 'success'
        ref['object']['sha'] = 'b' * 40
        with self.assertRaises(ValueError):
            release.resume('42', env, command=github)
        ref['object']['sha'] = env['GITHUB_SHA']
        release.resume('42', env, command=github)
        self.assertIn('ACCEPTED_GITHUB_SHA=' + env['GITHUB_SHA'], (self.root / 'job-env').read_text())
        run['event'] = 'pull_request'
        with self.assertRaises(ValueError):
            release.resume('42', env, command=github)

    def desktop_archives(self):
        for path in self.download.iterdir():
            path.unlink()
        version = (release.ROOT / 'desktop/version.txt').read_text().strip()
        self.env['GITHUB_REF_NAME'] = 'desktop-v' + version
        accepted = self.download / 'workbench-macos-arm64-unsigned-verified'
        accepted.mkdir()
        archive = accepted / f'vhttpd-workbench-macos-arm64-{version}.zip'
        with zipfile.ZipFile(archive, 'w') as z:
            z.writestr('安装说明.txt', '解压 ' + archive.name)
            z.writestr('vhttpd-workbench.app/Contents/Info.plist', plistlib.dumps({
                'CFBundleShortVersionString': version, 'VHTTPDReleaseVersion': version}))
        (accepted / 'acceptance.json').write_text(json.dumps({
            'archive': archive.name, 'sha256': release.digest(archive), 'source_commit': 'a' * 40,
            'release_mode': 'unsigned', 'signature': 'ad-hoc', 'targets': [
                {'macos': '15.8', 'runtime': 'passed', 'arch': 'arm64'},
                {'macos': '26.7', 'runtime': 'passed', 'arch': 'arm64'}]}))
        (accepted / 'SHA256SUMS').write_text(release.digest(archive) + '  ' + archive.name)
        (accepted / '验收说明.txt').write_text('15/26 passed; Finder approval not verified')
        for platform in ['linux-amd64', 'linux-arm64', 'windows-amd64']:
            if platform.startswith('windows'):
                path = self.download / f'vhttpd-workbench-{platform}-{version}.zip'
                with zipfile.ZipFile(path, 'w') as z:
                    z.writestr('app/VERSION.txt', 'Desktop ' + version)
                    z.writestr('app/build-info.json', json.dumps({
                        'commit': 'a' * 40, 'version': version, 'v': self.lock['V_COMMIT']}))
            else:
                path = self.download / f'vhttpd-workbench-{platform}-{version}.tar.gz'
                with tarfile.open(path, 'w:gz') as z:
                    payload = ('Desktop ' + version).encode()
                    entry = tarfile.TarInfo('app/VERSION.txt'); entry.size = len(payload)
                    z.addfile(entry, io.BytesIO(payload))
            Path(str(path) + '.sha256').write_text(release.digest(path) + '  ' + path.name)
        return version

    def test_desktop_publishes_four_platform_archives_with_independent_version(self):
        version = self.desktop_archives()
        product, actual, assets = release.prepare(self.download, self.root / 'desktop', self.env)
        self.assertEqual((product, actual), ('desktop', version))
        self.assertEqual(sum(p.name.endswith(('.tar.gz', '.zip')) for p in assets), 4)

    def test_failed_mac_acceptance_blocks_the_entire_desktop_release(self):
        self.desktop_archives()
        path = self.download / 'workbench-macos-arm64-unsigned-verified/acceptance.json'
        data = json.loads(path.read_text()); data['targets'][0]['runtime'] = 'failed'
        path.write_text(json.dumps(data))
        with self.assertRaises(ValueError):
            release.prepare(self.download, self.root / 'desktop', self.env)


if __name__ == '__main__':
    unittest.main()
