#!/usr/bin/env python3
"""Sign a CI-built app, notarize it, staple its ticket, then archive it again."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import secrets
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from package_macos import archive as package_archive


class ReleaseError(Exception):
    pass


def signing_config(env):
    required = ['APPLE_CERTIFICATE', 'APPLE_CERTIFICATE_PASSWORD', 'APPLE_SIGNING_IDENTITY', 'APPLE_TEAM_ID']
    api = ['APPLE_API_KEY', 'APPLE_API_ISSUER', 'APPLE_API_KEY_P8']
    required += api if any(env.get(key) for key in api) else ['APPLE_ID', 'APPLE_PASSWORD']
    missing = [key for key in required if not env.get(key)]
    if missing:
        raise ReleaseError('Missing signing configuration: ' + ', '.join(missing))
    config = {key: env[key] for key in required}
    identity, team = config['APPLE_SIGNING_IDENTITY'], config['APPLE_TEAM_ID']
    if not re.fullmatch(r'[A-Z0-9]{10}', team):
        raise ReleaseError('APPLE_TEAM_ID must be the 10-character Apple team ID')
    if not identity.startswith('Developer ID Application: ') or not identity.endswith('(' + team + ')'):
        raise ReleaseError('APPLE_SIGNING_IDENTITY must be a Developer ID Application identity for APPLE_TEAM_ID')
    try:
        if not base64.b64decode(''.join(config['APPLE_CERTIFICATE'].split()), validate=True):
            raise ValueError('empty certificate')
    except ValueError:
        raise ReleaseError('APPLE_CERTIFICATE must contain the Base64-encoded .p12 certificate') from None
    if 'APPLE_API_KEY_P8' in config and not config['APPLE_API_KEY_P8'].strip().startswith('-----BEGIN PRIVATE KEY-----'):
        raise ReleaseError('APPLE_API_KEY_P8 must contain the raw multiline .p8 private key')
    return config


def run(arguments, check=True):
    result = subprocess.run(arguments, text=True, capture_output=True)
    if not check:
        return result
    if check and result.returncode:
        # Commands can contain passwords. Do not expose argv or raw auth errors.
        raise ReleaseError(Path(arguments[0]).name + ' failed (exit ' + str(result.returncode) + ')')
    return result.stdout + result.stderr


def release(source, output, checksum, config, command=run, archive=package_archive):
    if hashlib.sha256(source.read_bytes()).hexdigest() != checksum:
        raise ReleaseError('CI candidate checksum mismatch')
    output.mkdir(parents=True, exist_ok=True)
    final = output / (source.stem + '-signed-notarized.zip')
    if final.exists():
        raise ReleaseError('Refusing to replace an existing signed candidate')
    with tempfile.TemporaryDirectory(prefix='vhttpd-sign-', dir=os.environ.get('RUNNER_TEMP')) as directory:
        private = Path(directory)
        private.chmod(0o700)
        keychain = private / 'signing.keychain-db'
        password = secrets.token_hex(32)
        if os.environ.get('GITHUB_ACTIONS') == 'true':
            print('::add-mask::' + password, flush=True)
        try:
            certificate = private / 'certificate.p12'
            certificate.write_bytes(base64.b64decode(''.join(config['APPLE_CERTIFICATE'].split()), validate=True))
            certificate.chmod(0o600)
            command(['/usr/bin/security', 'create-keychain', '-p', password, str(keychain)])
            command(['/usr/bin/security', 'set-keychain-settings', '-lut', '21600', str(keychain)])
            command(['/usr/bin/security', 'unlock-keychain', '-p', password, str(keychain)])
            command(['/usr/bin/security', 'import', str(certificate), '-k', str(keychain), '-P', config['APPLE_CERTIFICATE_PASSWORD'], '-T', '/usr/bin/codesign'])
            command(['/usr/bin/security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:', '-s', '-k', password, str(keychain)])
            installed = private / 'Installed'
            command(['/usr/bin/ditto', '-x', '-k', str(source), str(installed)])
            app = installed / 'vhttpd-workbench.app'
            guide = app / 'Contents/Resources/INSTALL-zh.txt'
            text = guide.read_text()
            start, end = text.index('首次打开的系统限制'), text.index('第一次使用')
            text = text[:start] + ('正式签名包的系统检查\n'
                '此构建产物由 CI 从源码构建；signed-notarized 包只有在 Developer ID 签名、\n'
                'Apple 公证接受、App 票据装订以及系统策略检查全部成功后才会生成。\n'
                '目标系统自动化运行与下载策略检查结果见对应 CI 记录。实体 Mac 的 Finder、\n'
                '窗口和浏览器首次使用流程仍单独验收。若系统阻止打开，请保留具体提示，\n'
                '不要关闭系统安全保护或清除下载隔离标记。\n\n') + text[end:]
            text = text.replace('- macOS 15 的构建与依赖检查不等于旧系统实机验证；当前运行验收在 macOS 27.0.1。', '- 目标系统自动化验收结果以本次 CI 记录为准；不代替实体 Mac 的图形流程验收。')
            guide.write_text(text)
            runtime = app / 'Contents/Resources/runtime'
            objects = [*sorted((runtime / 'lib').glob('*.dylib')), runtime / 'vhttpd', app]
            for obj in objects:
                command(['/usr/bin/codesign', '--force', '--timestamp', '--options', 'runtime', '--keychain', str(keychain), '--sign', config['APPLE_SIGNING_IDENTITY'], str(obj)])
                signature = command(['/usr/bin/codesign', '-d', '--verbose=4', str(obj)])
                if (not re.search(r'^TeamIdentifier=' + re.escape(config['APPLE_TEAM_ID']) + r'$', signature, re.M)
                        or not re.search(r'^Authority=Developer ID Application:', signature, re.M)
                        or not re.search(r'^CodeDirectory .*flags=.*\bruntime\b', signature, re.M)
                        or not re.search(r'^Timestamp=', signature, re.M)):
                    raise ReleaseError('Developer ID, team or hardened runtime verification failed: ' + obj.name)
            command(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
            submission = private / 'notary-submission.zip'
            archive(app, submission)
            if 'APPLE_API_KEY_P8' in config:
                key = private / 'notary.p8'
                key.write_text(config['APPLE_API_KEY_P8'])
                key.chmod(0o600)
                auth = ['--key', str(key), '--key-id', config['APPLE_API_KEY'], '--issuer', config['APPLE_API_ISSUER']]
            else:
                auth = ['--apple-id', config['APPLE_ID'], '--password', config['APPLE_PASSWORD'], '--team-id', config['APPLE_TEAM_ID']]
            response = command(['/usr/bin/xcrun', 'notarytool', 'submit', str(submission), *auth, '--wait', '--timeout', '20m', '--output-format', 'json'], check=False)
            try:
                result = json.loads(response.stdout)
            except (ValueError, TypeError):
                raise ReleaseError('notarytool did not return a valid JSON result; no signed archive created') from None
            submission_id = result.get('id', '')
            if not re.fullmatch(r'[0-9a-fA-F-]{36}', submission_id):
                raise ReleaseError('Notarization submission ID is missing or invalid')
            (output / 'notarization.json').write_text(json.dumps({'id': submission_id, 'status': result.get('status'), 'exit_code': response.returncode}, indent=2) + '\n')
            if response.returncode or result.get('status') != 'Accepted':
                command(['/usr/bin/xcrun', 'notarytool', 'log', submission_id, *auth, str(output / 'notary-log.json')], check=False)
                raise ReleaseError('Notarization did not complete successfully; inspect notarization.json and notary-log.json')
            command(['/usr/bin/xcrun', 'stapler', 'staple', str(app)])
            command(['/usr/bin/xcrun', 'stapler', 'validate', str(app)])
            command(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)])
            assessment = command(['/usr/sbin/spctl', '--assess', '--type', 'execute', '--verbose=4', str(app)])
            if 'source=Notarized Developer ID' not in assessment:
                raise ReleaseError('Gatekeeper did not report Notarized Developer ID')
            # ZIPs cannot be stapled: rebuild the download from the stapled app.
            staged = private / 'final.zip'
            archive(app, staged)
            final_sha = hashlib.sha256(staged.read_bytes()).hexdigest()
            # The output may be on another volume. Publish only a complete ZIP.
            with tempfile.NamedTemporaryFile(dir=output, prefix='.signed-', suffix='.zip', delete=False) as file:
                pending = Path(file.name)
            try:
                shutil.copyfile(staged, pending)
                pending.replace(final)
            finally:
                pending.unlink(missing_ok=True)
            (output / 'SHA256SUMS').write_text(final_sha + '  ' + final.name + '\n')
            return final, final_sha
        finally:
            command(['/usr/bin/security', 'delete-keychain', str(keychain)], check=False)


if __name__ == '__main__':
    try:
        config = signing_config(os.environ)
        if sys.argv[1:] == ['--check-config']:
            print('Required signing settings are present; certificate and Apple service validation still required')
        elif len(sys.argv) == 4:
            final, checksum = release(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve(), sys.argv[3], config)
            if os.environ.get('GITHUB_OUTPUT'):
                with open(os.environ['GITHUB_OUTPUT'], 'a') as out:
                    out.write('sha256=' + checksum + '\narchive=' + final.name + '\n')
            print('Signed, accepted, stapled and verified: ' + final.name)
        else:
            raise ReleaseError('Usage: sign_notarize_macos.py ZIP OUTPUT_DIR EXPECTED_SHA256 | --check-config')
    except ReleaseError as error:
        print(str(error), file=sys.stderr)
        raise SystemExit(1)
