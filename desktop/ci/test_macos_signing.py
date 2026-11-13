import base64
import hashlib
import importlib.util
import json
from pathlib import Path
import subprocess
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('sign_macos', Path(__file__).with_name('sign_notarize_macos.py'))
sign = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sign)


def configuration():
    return {'APPLE_CERTIFICATE': base64.b64encode(b'certificate-with-private-key').decode(),
            'APPLE_CERTIFICATE_PASSWORD': 'p12-private-password',
            'APPLE_SIGNING_IDENTITY': 'Developer ID Application: Example (ABCDEFGHIJ)',
            'APPLE_TEAM_ID': 'ABCDEFGHIJ', 'APPLE_ID': 'test@example.invalid',
            'APPLE_PASSWORD': 'app-specific-private-password'}


class AppleTools:
    def __init__(self, status='Accepted', exit_code=0, fail_staple=False, wrong_team=False):
        self.calls = []
        self.archives = []
        self.status, self.exit_code = status, exit_code
        self.fail_staple, self.wrong_team = fail_staple, wrong_team
        self.stapled = False
        self.private_directory = None

    def command(self, args, check=True):
        self.calls.append(args)
        if args[:2] == ['/usr/bin/security', 'import']:
            certificate = Path(args[2])
            self.private_directory = certificate.parent
            assert certificate.stat().st_mode & 0o777 == 0o600
        if args[:3] == ['/usr/bin/ditto', '-x', '-k']:
            app = Path(args[-1]) / 'vhttpd-workbench.app'
            library = app / 'Contents/Resources/runtime/lib/libexample.dylib'
            library.parent.mkdir(parents=True)
            library.write_bytes(b'library')
            (library.parent.parent / 'vhttpd').write_bytes(b'runtime')
            (app / 'Contents/Resources/INSTALL-zh.txt').write_text('安装\n首次打开的系统限制\n旧的 ad-hoc 提示\n第一次使用\n新建项目\n')
        if args[:2] == ['/usr/bin/codesign', '-d']:
            team = 'WRONGTEAM0' if self.wrong_team else 'ABCDEFGHIJ'
            return 'CodeDirectory v=20500 flags=0x10000(runtime)\nAuthority=Developer ID Application: Example\nTeamIdentifier=' + team + '\nTimestamp=Oct 18 2026\n'
        if args[:3] == ['/usr/bin/xcrun', 'notarytool', 'submit']:
            result = {'id': '11111111-2222-3333-4444-555555555555', 'status': self.status}
            return subprocess.CompletedProcess(args, self.exit_code, json.dumps(result), '')
        if args[:3] == ['/usr/bin/xcrun', 'stapler', 'staple']:
            if self.fail_staple:
                raise sign.ReleaseError('stapler failed')
            self.stapled = True
        if args[0] == '/usr/sbin/spctl':
            return 'accepted\nsource=Notarized Developer ID\n'
        return '' if check else subprocess.CompletedProcess(args, 0, '', '')

    def archive(self, app, output):
        self.archives.append(self.stapled)
        assert '旧的 ad-hoc' not in (app / 'Contents/Resources/INSTALL-zh.txt').read_text()
        output.write_bytes(b'stapled-archive' if self.stapled else b'submission-archive')


class SigningTests(unittest.TestCase):
    def execute(self, tools, config=None):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / 'candidate.zip'
            source.write_bytes(b'CI-built-candidate')
            output = root / 'output'
            config = sign.signing_config(config or configuration())
            try:
                final, checksum = sign.release(source, output, hashlib.sha256(source.read_bytes()).hexdigest(), config,
                                               command=tools.command, archive=tools.archive)
                self.assertEqual(final.read_bytes(), b'stapled-archive')
                self.assertEqual(checksum, hashlib.sha256(final.read_bytes()).hexdigest())
                self.assertEqual(tools.archives, [False, True])
            except sign.ReleaseError:
                self.assertEqual(list(output.glob('*-signed-notarized.zip')), [])
                raise
            finally:
                self.assertFalse(tools.private_directory.exists())
                self.assertTrue(any(call[:2] == ['/usr/bin/security', 'delete-keychain'] for call in tools.calls))

    def test_accepted_ticket_is_stapled_before_final_archive_and_all_code_signed(self):
        tools = AppleTools()
        self.execute(tools)
        signed = [call for call in tools.calls if call[:2] == ['/usr/bin/codesign', '--force']]
        self.assertEqual(len(signed), 3)  # dylib, runtime, outer app / host executable
        self.assertTrue(signed[-1][-1].endswith('.app'))
        for call in signed:
            self.assertIn('--timestamp', call)
            self.assertIn('runtime', call)
            self.assertNotIn('--deep', call)
            self.assertNotIn('--entitlements', call)

    def test_rejected_notarization_never_staples_or_produces_download(self):
        tools = AppleTools(status='Invalid')
        with self.assertRaises(sign.ReleaseError):
            self.execute(tools)
        self.assertFalse(tools.stapled)
        self.assertEqual(tools.archives, [False])

    def test_nonzero_notary_exit_never_accepts_an_accepted_json(self):
        tools = AppleTools(exit_code=69)
        with self.assertRaises(sign.ReleaseError):
            self.execute(tools)
        self.assertFalse(tools.stapled)

    def test_stapling_failure_never_produces_final_download(self):
        tools = AppleTools(fail_staple=True)
        with self.assertRaises(sign.ReleaseError):
            self.execute(tools)
        self.assertEqual(tools.archives, [False])

    def test_wrong_team_stops_before_upload_to_apple(self):
        tools = AppleTools(wrong_team=True)
        with self.assertRaises(sign.ReleaseError):
            self.execute(tools)
        self.assertFalse(any(call[:3] == ['/usr/bin/xcrun', 'notarytool', 'submit'] for call in tools.calls))

    def test_disabled_gatekeeper_is_not_a_notarization_pass(self):
        tools = AppleTools()
        original = tools.command
        def command(args, check=True):
            if args[0] == '/usr/sbin/spctl':
                return 'accepted\noverride=security disabled\n'
            return original(args, check)
        tools.command = command
        with self.assertRaisesRegex(sign.ReleaseError, 'Notarized Developer ID'):
            self.execute(tools)

    def test_missing_secrets_and_partial_api_key_do_not_fall_back(self):
        with self.assertRaises(sign.ReleaseError):
            sign.signing_config({})
        env = configuration()
        env['APPLE_API_KEY'] = 'KEYID'
        with self.assertRaisesRegex(sign.ReleaseError, 'APPLE_API_ISSUER'):
            sign.signing_config(env)

    def test_api_key_auth_uses_restricted_temporary_key_and_cleans_up(self):
        env = configuration()
        del env['APPLE_ID'], env['APPLE_PASSWORD']
        env.update(APPLE_API_KEY='KEYID', APPLE_API_ISSUER='issuer', APPLE_API_KEY_P8='-----BEGIN PRIVATE KEY-----\ntest\n-----END PRIVATE KEY-----')
        tools = AppleTools()
        original = tools.command
        def command(args, check=True):
            if args[:3] == ['/usr/bin/xcrun', 'notarytool', 'submit']:
                key = Path(args[args.index('--key') + 1])
                self.assertEqual(key.stat().st_mode & 0o777, 0o600)
                self.assertEqual(key.read_text(), env['APPLE_API_KEY_P8'])
                self.assertNotIn('--apple-id', args)
            return original(args, check)
        tools.command = command
        self.execute(tools, env)


if __name__ == '__main__':
    unittest.main()
