#!/usr/bin/env python3
"""Exercise remote catalog persistence without SSH or production credentials."""
import base64
import contextlib
import importlib.util
import io
import json
import os
from pathlib import Path
import stat
import tempfile
import unittest
import zlib

source = Path(__file__).resolve().parents[1] / 'host/remote_scripts/relay_catalog.py'
spec = importlib.util.spec_from_file_location('relay_catalog', source)
catalog = importlib.util.module_from_spec(spec)
spec.loader.exec_module(catalog)

class CatalogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.previous = os.environ.get('HOME')
        os.environ['HOME'] = self.temp.name
        self.path = Path(self.temp.name) / '.local/share/vhttpd-workbench/shared-relays.json'
        self.entry = dict(id='ab' * 12, protocol='websocket', name='Paseo', url='wss://example/ws?v=2', token='private-test-token')

    def tearDown(self):
        if self.previous is None:
            os.environ.pop('HOME', None)
        else:
            os.environ['HOME'] = self.previous
        self.temp.cleanup()

    def call(self, operation='load', revision='', entry=None):
        encoded = base64.b64encode(zlib.compress(json.dumps(dict(operation=operation, revision=revision, entry=entry or self.entry)).encode())).decode()
        stream = io.StringIO()
        try:
            with contextlib.redirect_stdout(stream):
                catalog.catalog_operation(encoded)
        except SystemExit:
            self.assertNotIn('private-test-token', stream.getvalue())
            raise
        return json.loads(stream.getvalue())

    def test_crud_permissions_and_compare_and_swap(self):
        self.assertEqual(self.call()['entries'], [])
        saved = self.call('save')
        self.assertEqual(saved['entries'], [self.entry])
        self.assertEqual(stat.S_IMODE(self.path.stat().st_mode), 0o600)
        before = self.path.read_bytes()
        with self.assertRaises(SystemExit):
            self.call('delete', revision='stale')
        self.assertEqual(self.path.read_bytes(), before)
        native = dict(self.entry, id='cd'*12, protocol='vhttpd', relay_id='bodytest_database')
        second = self.call('save', saved['revision'], native)
        self.assertEqual(len(second['entries']), 2)
        final = self.call('delete', second['revision'], self.entry)
        self.assertEqual(final['entries'], [native])
        self.assertFalse((self.path.parent / '.relay-catalog-lock').exists())

    def test_corrupt_and_public_files_are_preserved(self):
        self.call('save')
        self.path.write_text('corrupt-private-test-token')
        with self.assertRaises(SystemExit):
            self.call('save')
        self.assertEqual(self.path.read_text(), 'corrupt-private-test-token')
        self.path.write_text('[]')
        self.path.chmod(0o644)
        with self.assertRaises(SystemExit):
            self.call()

    def test_symlink_refused(self):
        self.call('save')
        self.path.unlink()
        target = Path(self.temp.name) / 'target'
        target.write_text('preserve')
        self.path.symlink_to(target)
        with self.assertRaises(SystemExit):
            self.call('save')
        self.assertEqual(target.read_text(), 'preserve')

if __name__ == '__main__':
    unittest.main()
