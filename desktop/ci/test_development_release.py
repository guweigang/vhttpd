import io
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile
import unittest
import zipfile

from development_release import ARTIFACTS, Publisher, digest, eligible, safe_unpack, validate_linux
from workbench_version import version_metadata


SHA = 'a' * 40
REPO = 'guweigang/vhttpd'


class GitHub:
    def __init__(self, uploads=None):
        self.calls, self.ref, self.release = [], None, None
        self.uploads = uploads or {}
        self.fail_upload = False
        self.move_after_upload = False

    def __call__(self, args, output=None):
        self.calls.append(args)
        def result(code=0, value='', error=''):
            return subprocess.CompletedProcess(args, code, json.dumps(value) if not isinstance(value, str) else value, error)
        if args[:3] == ['api', '--method', 'POST']:
            self.ref = {'object': {'type': 'commit', 'sha': SHA}}
            return result(value=self.ref)
        if args[0] == 'api':
            path = args[1]
            if '/git/ref/tags/' in path:
                return result(value=self.ref) if self.ref else result(1, error='HTTP 404')
            if '/releases/tags/' in path:
                return result(value=self.release) if self.release else result(1, error='HTTP 404')
            if '/actions/runs/' in path:
                run_id = int(path.split('/actions/runs/')[1].split('/')[0])
                return result(value={'artifacts': [a for a, _ in self.uploads.values() if a['run'] == run_id]})
            if '/actions/artifacts/' in path:
                artifact_id = int(path.split('/actions/artifacts/')[1].split('/')[0])
                output.write(self.uploads[artifact_id][1].read_bytes())
                return result()
            raise AssertionError(path)
        if args[:2] == ['release', 'create']:
            self.release = {'draft': True, 'prerelease': True, 'target_commitish': SHA,
                'body': Path(args[args.index('--notes-file')+1]).read_text(), 'assets': []}
        if args[:2] == ['release', 'upload']:
            if self.fail_upload:
                return result(1, error='upload interrupted')
            files = [Path(p) for p in args[args.index('--clobber')+1:]]
            self.release['assets'] = [{'name': p.name, 'digest': 'sha256:'+digest(p), 'size': p.stat().st_size} for p in files]
            if self.move_after_upload:
                self.ref['object']['sha'] = 'b' * 40
        if args[:2] == ['release', 'edit']:
            self.release['draft'] = False
        return result()


def linux_package(directory, platform, sha=SHA):
    directory.mkdir()
    archive = directory / ('vhttpd-'+platform+'.tar.gz')
    elf = bytearray(20)
    elf[:6] = b'\x7fELF\x02\x01'
    elf[18:20] = (62 if platform == 'linux-amd64' else 183).to_bytes(2,'little')
    files = {'vhttpd': bytes(elf), 'admin/ui/index.html': b'admin',
             'runtime-manifest.json': json.dumps({'platform':platform,'source_commit':sha}).encode()}
    with tarfile.open(archive, 'w:gz') as bundle:
        for name, data in files.items():
            info = tarfile.TarInfo('vhttpd-'+platform+'/'+name)
            info.size = len(data)
            bundle.addfile(info, io.BytesIO(data))
    (directory/(archive.name+'.sha256')).write_text(digest(archive)+'  '+archive.name+'\n')
    return archive


class DevelopmentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.version = version_metadata({'VHTTPD_DEVELOPMENT_BUILD':'1','GITHUB_SHA':SHA})

    def test_development_version_is_deterministic_and_stable_tags_keep_their_identity(self):
        self.assertEqual(self.version['version'], '0.1.0-dev.g'+SHA[:12])
        stable = version_metadata({'GITHUB_REF_TYPE':'tag','GITHUB_REF_NAME':'v1.2.3','VHTTPD_DEVELOPMENT_BUILD':'1'})
        self.assertEqual(stable['version'],'1.2.3')
        self.assertEqual(stable['prerelease'],'false')
        with self.assertRaises(ValueError):
            version_metadata({'VHTTPD_DEVELOPMENT_BUILD':'1','GITHUB_SHA':'branch; bad'})

    def test_only_successful_own_source_push_or_manual_builds_can_publish(self):
        run = {'status':'completed','conclusion':'success','event':'push','head_branch':'main',
               'head_sha':SHA,'head_repository':{'full_name':REPO}}
        self.assertTrue(eligible(run,REPO,'main'))
        for change in [{'conclusion':'failure'},{'event':'pull_request'},{'head_branch':'feature'},
                       {'head_repository':{'full_name':'attacker/fork'}},{'head_sha':'bad'}]:
            self.assertFalse(eligible(dict(run,**change),REPO,'main'))
        self.assertTrue(eligible(dict(run,event='workflow_dispatch',head_branch='feature'),REPO,'main'))

    def mac_package(self):
        directory = self.root/'mac';directory.mkdir()
        archive = directory/self.version['archive']
        with zipfile.ZipFile(archive,'w') as bundle:
            bundle.writestr('安装说明.txt', '解压 '+archive.name)
            bundle.writestr('vhttpd-workbench.app/Contents/Info.plist',plistlib.dumps({
                'CFBundleShortVersionString':'0.1.0','VHTTPDReleaseVersion':self.version['version']}))
        (directory/'SHA256SUMS').write_text(digest(archive)+'  '+archive.name+'\n')
        (directory/'acceptance.json').write_text(json.dumps({'archive':archive.name,'sha256':digest(archive),
            'source_commit':SHA,'release_mode':'unsigned','signature':'ad-hoc',
            'targets':[{'macos':'15.7','runtime':'passed','arch':'arm64'},{'macos':'26.6','runtime':'passed','arch':'arm64'}]}))
        (directory/'验收说明.txt').write_text('15/26 accepted; Gatekeeper separate')
        return directory

    def publisher(self):
        directories = [self.mac_package()]
        for platform in ['linux-amd64','linux-arm64']:
            linux_package(self.root/platform,platform)
            directories.append(self.root/platform)
        uploads = {}
        for i,(name,directory) in enumerate(zip(ARTIFACTS,directories),1):
            archive = self.root/(name+'.zip')
            with zipfile.ZipFile(archive,'w') as bundle:
                for file in directory.iterdir():bundle.write(file,file.name)
            uploads[i] = ({'id':i,'name':name,'expired':False,'size_in_bytes':archive.stat().st_size,
                'digest':'sha256:'+digest(archive),'run':1 if i==1 else 2},archive)
        github = GitHub(uploads)
        publisher = Publisher(REPO,self.root/'publish',github)
        tag,assets = publisher.assemble([{'id':1,'html_url':'mac'},{'id':2,'html_url':'linux'}],SHA)
        return publisher,github,tag,assets

    def test_collects_same_commit_verified_platforms_and_publishes_prerelease_only_after_upload(self):
        publisher,github,tag,assets = self.publisher()
        publisher.publish(tag,SHA,assets)
        self.assertFalse(github.release['draft'])
        self.assertTrue(github.release['prerelease'])
        count = len(github.calls)
        publisher.publish(tag,SHA,assets)
        self.assertFalse(any(c[:2]==['release','upload'] for c in github.calls[count:]))
        assets[0].write_bytes(b'changed')
        with self.assertRaises(ValueError):publisher.publish(tag,SHA,assets)

    def test_interrupted_upload_or_moved_tag_never_exposes_a_partial_release(self):
        publisher,github,tag,assets = self.publisher()
        github.fail_upload = True
        with self.assertRaises(RuntimeError):publisher.publish(tag,SHA,assets)
        self.assertTrue(github.release['draft'])
        github.fail_upload = False;github.move_after_upload = True
        with self.assertRaises(ValueError):publisher.publish(tag,SHA,assets)
        self.assertTrue(github.release['draft'])

    def test_artifact_digest_mismatch_never_creates_a_release(self):
        publisher,github,_,_ = self.publisher()
        github.uploads[1][0]['digest'] = 'sha256:' + '0'*64
        other = Publisher(REPO,self.root/'bad-digest',github)
        with self.assertRaises(ValueError):other.assemble([{'id':1,'html_url':'mac'},{'id':2,'html_url':'linux'}],SHA)
        self.assertIsNone(github.ref)
        self.assertIsNone(github.release)

    def test_linux_commit_mismatch_and_unsafe_artifacts_are_rejected(self):
        archive = linux_package(self.root/'wrong','linux-arm64','b'*40)
        with self.assertRaises(ValueError):validate_linux(archive.parent,'linux-arm64',SHA)
        unsafe = self.root/'unsafe.zip'
        with zipfile.ZipFile(unsafe,'w') as bundle:bundle.writestr('../escape','bad')
        with self.assertRaises(ValueError):safe_unpack(unsafe,self.root/'unpack')


if __name__ == '__main__':unittest.main()
