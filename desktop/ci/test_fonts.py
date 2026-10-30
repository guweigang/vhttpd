#!/usr/bin/env python3
import hashlib
import json
from pathlib import Path
import sys
import tempfile
import unittest
from unittest.mock import patch
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from prepare_fonts import package, LOCK, ROOT

class FontsTest(unittest.TestCase):
    def test_shared_locked_fonts_and_licenses(self):
        with tempfile.TemporaryDirectory() as directory:
            target=package(Path(directory)/'fonts', offline=True)
            for asset in json.loads(LOCK.read_text())['assets']:
                self.assertEqual(hashlib.sha256((target/asset['file']).read_bytes()).hexdigest(),asset['sha256'])
            self.assertTrue((target/'RobotoMono-OFL.txt').is_file())
            self.assertTrue((target/'fonts.lock.json').is_file())

    def test_bad_cache_cannot_be_shipped_offline(self):
        with tempfile.TemporaryDirectory() as directory:
            cache=Path(directory)/'cache';cache.mkdir()
            (cache/'NotoSansCJKsc-Regular.otf').write_bytes(b'not a font')
            with self.assertRaisesRegex(RuntimeError,'Missing or corrupt'):
                package(Path(directory)/'fonts',cache=cache,offline=True)

if __name__=='__main__': unittest.main()
