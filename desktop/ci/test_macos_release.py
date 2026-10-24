import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import zipfile

from macos_release import digest, prepare, publish
from workbench_version import version_metadata


class GitHub:
    def __init__(self, existing=None, fail_upload=False, moved=False):
        self.calls = []
        self.existing, self.fail_upload, self.moved = existing, fail_upload, moved
        self.tag_reads = 0

    def __call__(self, args):
        self.calls.append(args)
        if args[0] == 'api' and '/git/ref/tags/' in args[1]:
            self.tag_reads += 1
            sha = 'b' * 40 if self.moved else 'a' * 40
            return subprocess.CompletedProcess(args, 0, json.dumps({'object': {'type': 'commit', 'sha': sha}}), '')
        if args[0] == 'api':
            if self.existing is None:
                return subprocess.CompletedProcess(args, 1, '', 'HTTP 404: Not Found')
            return subprocess.CompletedProcess(args, 0, json.dumps(self.existing), '')
        if args[:2] == ['release', 'upload'] and self.fail_upload:
            return subprocess.CompletedProcess(args, 1, '', 'upload interrupted')
        return subprocess.CompletedProcess(args, 0, '', '')


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.download = self.root / 'download'
        self.download.mkdir()
        self.env = {'GITHUB_EVENT_NAME': 'push', 'GITHUB_REF_TYPE': 'tag', 'GITHUB_REF_NAME': 'v2.3.4-rc.1',
                    'GITHUB_SHA': 'a' * 40, 'GITHUB_REPOSITORY': 'example/vhttpd'}
        self.version = version_metadata(self.env)
        self.archive = self.download / self.version['archive']
        with zipfile.ZipFile(self.archive, 'w') as bundle:
            bundle.writestr('安装说明.txt', 'vhttpd 2.3.4-rc.1\n解压 ' + self.archive.name)
            bundle.writestr('vhttpd-workbench.app/Contents/Info.plist', plistlib.dumps({
                'CFBundleShortVersionString': '2.3.4', 'VHTTPDReleaseVersion': '2.3.4-rc.1'}))
        self.acceptance = {'archive': self.archive.name, 'sha256': digest(self.archive), 'source_commit': 'a' * 40,
                           'release_mode': 'unsigned', 'signature': 'ad-hoc', 'targets': [
                               {'macos': '15.7.9', 'runtime': 'passed', 'arch': 'arm64'},
                               {'macos': '26.6.2', 'runtime': 'passed', 'arch': 'arm64'}]}
        (self.download / 'acceptance.json').write_text(json.dumps(self.acceptance))
        (self.download / 'SHA256SUMS').write_text(digest(self.archive) + '  ' + self.archive.name + '\n')
        (self.download / '验收说明.txt').write_text('15/26 passed; Gatekeeper not verified')

    def test_tag_versions_and_prerelease(self):
        self.assertEqual(self.version['bundle_version'], '2.3.4')
        self.assertEqual(self.version['prerelease'], 'true')
        self.assertEqual(version_metadata(dict(self.env, GITHUB_REF_NAME='v1.2.3'))['prerelease'], 'false')
        for tag in ['v1.2', 'v01.2.3', 'v1.2.3-01', 'not-a-version', 'v1.2.3/../../bad']:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                version_metadata(dict(self.env, GITHUB_REF_NAME=tag))
        with self.assertRaises(ValueError):
            version_metadata(dict(self.env, VHTTPD_WORKBENCH_VERSION='9.9.9'))

    def test_prepared_assets_preserve_tested_archive_and_checksums_cover_all_attachments(self):
        version, assets = prepare(self.download, self.root / 'release', self.env)
        self.assertEqual(version['version'], '2.3.4-rc.1')
        self.assertEqual((self.root / 'release' / self.archive.name).read_bytes(), self.archive.read_bytes())
        sums = assets[-1].read_text().splitlines()
        self.assertEqual(len(sums), 4)
        for line in sums:
            checksum, name = line.split('  ')
            self.assertEqual(checksum, digest(self.root / 'release' / name))

    def test_wrong_source_failed_target_or_changed_archive_blocks_release(self):
        for key, value in [('source_commit', 'b' * 40), ('sha256', 'changed')]:
            original = self.acceptance[key]
            self.acceptance[key] = value
            (self.download / 'acceptance.json').write_text(json.dumps(self.acceptance))
            with self.assertRaises(ValueError):
                prepare(self.download, self.root / 'release', self.env)
            self.acceptance[key] = original
        self.acceptance['targets'][0]['runtime'] = 'failed'
        (self.download / 'acceptance.json').write_text(json.dumps(self.acceptance))
        with self.assertRaises(ValueError):
            prepare(self.download, self.root / 'release', self.env)

    def test_only_tag_push_publishes(self):
        github = GitHub()
        with self.assertRaises(ValueError):
            publish(self.download, self.root / 'release', dict(self.env, GITHUB_EVENT_NAME='pull_request'), github)
        self.assertEqual(github.calls, [])

    def test_upload_finishes_before_draft_is_published(self):
        github = GitHub()
        publish(self.download, self.root / 'release', self.env, github)
        writes = [args for args in github.calls if args[0] == 'release']
        self.assertEqual([args[1] for args in writes], ['create', 'upload', 'edit'])
        self.assertIn('--draft', writes[0])
        self.assertIn('--verify-tag', writes[0])
        self.assertIn('--draft=false', writes[-1])
        self.assertIn('--prerelease=true', writes[-1])
        self.assertEqual(github.tag_reads, 2)

    def test_interrupted_upload_keeps_release_private_and_owned_draft_can_retry(self):
        github = GitHub(fail_upload=True)
        with self.assertRaises(RuntimeError):
            publish(self.download, self.root / 'release', self.env, github)
        self.assertFalse(any(args[:2] == ['release', 'edit'] for args in github.calls))
        draft = {'draft': True, 'target_commitish': 'a' * 40, 'body': '<!-- vhttpd-macos-ci sha=' + 'a' * 40 + ' -->'}
        github = GitHub(existing=draft)
        publish(self.download, self.root / 'retry', self.env, github)
        self.assertFalse(any(args[:2] == ['release', 'create'] for args in github.calls))
        self.assertTrue(any('--draft=false' in args for args in github.calls))

    def test_published_release_unrelated_draft_or_moved_tag_is_never_overwritten(self):
        for i, github in enumerate([GitHub(existing={'draft': False}), GitHub(existing={'draft': True}), GitHub(moved=True)]):
            with self.subTest(i=i), self.assertRaises(ValueError):
                publish(self.download, self.root / str(i), self.env, github)
            self.assertFalse(any(args[0] == 'release' for args in github.calls))


if __name__ == '__main__':
    unittest.main()
