import hashlib
import json
from pathlib import Path
import tempfile
import unittest

from collect_macos_acceptance import collect


class AcceptanceTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        root = Path(self.directory.name)
        self.download, self.evidence = root / 'download', root / 'evidence'
        self.download.mkdir()
        (self.download / 'candidate.zip').write_bytes(b'the same CI-built archive')
        checksum = hashlib.sha256((self.download / 'candidate.zip').read_bytes()).hexdigest()
        (self.download / 'SHA256SUMS').write_text(checksum + '  candidate.zip\n')
        for os, version in [('15', '15.7.9'), ('26', '26.6.2')]:
            report = self.evidence / ('macos-' + os)
            report.mkdir(parents=True)
            (report / 'result.txt').write_text('PASS\n')
            (report / 'environment.txt').write_text('ProductVersion:\t' + version + '\narm64\narchive_sha256=' + checksum + '\n')
            (report / 'gatekeeper-exit.txt').write_text('3\n')
            (report / 'gatekeeper.txt').write_text('rejected\nsource=no usable signature\n')

    def test_runtime_pass_does_not_claim_gatekeeper_approval(self):
        collect(self.download, self.evidence, {})
        result = json.loads((self.download / 'acceptance.json').read_text())
        self.assertEqual(len(result['targets']), 2)
        self.assertTrue(all(t['runtime'] == 'passed' for t in result['targets']))
        self.assertTrue(all(t['gatekeeper_download_approval'] == 'not_verified' for t in result['targets']))
        self.assertEqual(result['signature'], 'ad-hoc')
        self.assertTrue((self.download / '验收说明.txt').exists())

    def test_failure_or_missing_target_never_produces_accepted_download_metadata(self):
        report = self.evidence / 'macos-26/result.txt'
        report.write_text('FAIL exit=1\n')
        with self.assertRaises(ValueError):
            collect(self.download, self.evidence, {})
        report.unlink()
        with self.assertRaises(FileNotFoundError):
            collect(self.download, self.evidence, {})
        self.assertFalse((self.download / 'acceptance.json').exists())

    def test_target_or_candidate_mismatch_is_rejected(self):
        report = self.evidence / 'macos-26/environment.txt'
        for replacement in ['ProductVersion:\t27.0\narm64\n', 'ProductVersion:\t26.6\narm64\narchive_sha256=wrong\n']:
            report.write_text(replacement)
            with self.assertRaises(ValueError):
                collect(self.download, self.evidence, {})
        self.assertFalse((self.download / 'acceptance.json').exists())

    def test_checksum_file_must_work_from_the_download_directory(self):
        sums = self.download / 'SHA256SUMS'
        sums.write_text(sums.read_text().replace('candidate.zip', 'desktop/bin/candidate.zip'))
        with self.assertRaises(ValueError):
            collect(self.download, self.evidence, {})
        self.assertFalse((self.download / 'acceptance.json').exists())


if __name__ == '__main__':
    unittest.main()
