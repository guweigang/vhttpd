"""Exercise the exact stdlib probe sent over SSH, without production credentials."""
import base64
import hashlib
import importlib.util
import json
import os
import ssl
import subprocess
import tempfile
import time
import urllib.request
from pathlib import Path
import socket
import struct
import threading
import unittest

SCRIPT = Path(__file__).parents[1] / 'host/remote_scripts/relay_probe.py'
spec = importlib.util.spec_from_file_location('relay_draft_probe', SCRIPT)
probe_module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(probe_module)


def read_exact(conn, size):
    data = b''
    while len(data) < size:
        chunk = conn.recv(size - len(data))
        if not chunk:
            raise EOFError()
        data += chunk
    return data


def read_frame(conn):
    a, b = read_exact(conn, 2)
    assert b & 128, 'Client frames must be masked'
    size = struct.unpack('!H', read_exact(conn, 2))[0] if b & 127 == 126 else b & 127
    mask = read_exact(conn, 4)
    data = read_exact(conn, size)
    return a & 15, bytes(x ^ mask[i % 4] for i, x in enumerate(data))


class Fixture:
    def __init__(self, mode='websocket'):
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.listener.listen(1)
        self.port = self.listener.getsockname()[1]
        self.mode = mode
        self.frames = []
        self.header = ''
        self.error = None
        self.thread = threading.Thread(target=self.serve, daemon=True)

    def __enter__(self):
        self.thread.start()
        return self

    def __exit__(self, *_):
        self.thread.join(timeout=10)
        self.listener.close()
        assert not self.thread.is_alive(), 'Probe did not release its connection'
        if self.error:
            raise self.error

    def serve(self):
        try:
            self.listener.settimeout(8)
            with self.listener.accept()[0] as conn:
                conn.settimeout(8)
                header = b''
                while not header.endswith(b'\r\n\r\n'):
                    header += read_exact(conn, 1)
                self.header = header.decode()
                key = next(x.split(':', 1)[1].strip() for x in self.header.split('\r\n') if x.lower().startswith('sec-websocket-key:'))
                accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
                if self.mode == 'redirect':
                    conn.sendall(b'HTTP/1.1 302 Found\r\nLocation: http://secret.example/private-fixture-token\r\n\r\n')
                    return
                if self.mode == 'bad_accept':
                    accept = 'bad-key'
                conn.sendall(('HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + '\r\n\r\n').encode())
                if self.mode == 'bad_accept':
                    return
                op, body = read_frame(conn)
                self.frames.append((op, body))
                if self.mode == 'websocket':
                    assert op == 8, 'Plain WebSocket probe must not send business/Relay messages'
                    return
                assert op == 1
                frame = json.loads(body)
                assert frame['kind'] == 'ping' and frame['metadata']['purpose'] == 'connection-test-v1'
                assert frame['metadata']['mode'] == 'agent'
                if frame['headers'].get('authorization') != 'Bearer private-fixture-token':
                    return
                frame['kind'] = 'pong'
                frame['headers'] = {}
                if self.mode == 'wrong_identity':
                    frame['trace_id'] = 'another-probe'
                body = json.dumps(frame).encode()
                conn.sendall(bytes([0x81, 126]) + struct.pack('!H', len(body)) + body)
                try:
                    self.frames.append(read_frame(conn))
                except EOFError:
                    pass
        except Exception as e:
            self.error = e


class RelayDraftProbeTest(unittest.TestCase):
    def entry(self, fixture, protocol='vhttpd', token='private-fixture-token'):
        return dict(id='ab' * 12, name='Unsaved draft', url=f'ws://127.0.0.1:{fixture.port}/relay?test=1' if protocol == 'websocket' else f'ws://127.0.0.1:{fixture.port}/relay', protocol=protocol, relay_id='hub', token=token)

    def test_unsaved_native_draft_authenticates_without_registration(self):
        with Fixture('native') as f:
            result = probe_module.probe(self.entry(f))
        self.assertTrue(result['ok'], result)
        self.assertEqual(result['stage'], 'Relay 认证')
        self.assertIn('不代表项目已连接', result['message'])
        self.assertNotIn('Authorization:', f.header)
        self.assertEqual(f.frames[-1][0], 8)

    def test_bad_authentication_is_redacted(self):
        with Fixture('native') as f:
            result = probe_module.probe(self.entry(f, token='secret-wrong-token'))
        self.assertFalse(result['ok'])
        self.assertEqual(result['stage'], 'Relay 认证')
        self.assertNotIn('secret-wrong-token', json.dumps(result))

    def test_mismatched_probe_identity_fails(self):
        with Fixture('wrong_identity') as f:
            result = probe_module.probe(self.entry(f))
        self.assertFalse(result['ok'])

    def test_websocket_preserves_query_but_sends_no_native_frame(self):
        with Fixture() as f:
            result = probe_module.probe(self.entry(f, 'websocket'))
        self.assertTrue(result['ok'], result)
        self.assertIn('GET /relay?test=1 ', f.header)
        self.assertIn('Authorization: Bearer private-fixture-token\r\n', f.header)
        self.assertIn('业务认证需由应用验证', result['message'])

    def test_redirect_and_invalid_upgrade_never_pass(self):
        for mode in ['redirect', 'bad_accept']:
            with self.subTest(mode=mode), Fixture(mode) as f:
                result = probe_module.probe(self.entry(f))
            self.assertFalse(result['ok'])
            self.assertEqual(result['stage'], 'WebSocket')
            self.assertNotIn('private-fixture-token', json.dumps(result))

    def test_closed_port_is_network_failure(self):
        f = Fixture()
        f.listener.close()
        result = probe_module.probe(self.entry(f))
        self.assertFalse(result['ok'])
        self.assertEqual(result['stage'], '网络 / DNS')


    def test_untrusted_tls_certificate_is_rejected(self):
        with tempfile.TemporaryDirectory(prefix='relay-probe-tls-') as directory:
            cert, key = Path(directory) / 'cert.pem', Path(directory) / 'key.pem'
            subprocess.run(['openssl', 'req', '-x509', '-newkey', 'rsa:2048', '-nodes', '-keyout', str(key), '-out', str(cert), '-days', '1', '-subj', '/CN=localhost'], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
            context.load_cert_chain(cert, key)
            with socket.socket() as listener:
                listener.bind(('127.0.0.1', 0))
                listener.listen(1)
                listener.settimeout(5)
                def serve():
                    with listener.accept()[0] as conn:
                        conn.settimeout(5)
                        try:
                            context.wrap_socket(conn, server_side=True).close()
                        except ssl.SSLError:
                            pass
                thread = threading.Thread(target=serve, daemon=True)
                thread.start()
                result = probe_module.probe(dict(protocol='websocket',url=f'wss://127.0.0.1:{listener.getsockname()[1]}/ws',token='tls-fixture-private'))
                thread.join(timeout=6)
                self.assertFalse(thread.is_alive())
                self.assertFalse(result['ok'])
                self.assertEqual(result['stage'], 'TLS')
                self.assertNotIn('tls-fixture-private', json.dumps(result))


@unittest.skipUnless(os.environ.get('VHTTPD_RELAY_PROBE_RUNTIME'), 'Set VHTTPD_RELAY_PROBE_RUNTIME for real Hub integration')
class RealRelayHubTest(unittest.TestCase):
    def test_real_hub_accepts_draft_rejects_wrong_auth_and_never_registers_carrier(self):
        def free_port():
            with socket.socket() as sock:
                sock.bind(('127.0.0.1', 0))
                return sock.getsockname()[1]
        port, admin = free_port(), free_port()
        while admin == port:
            admin = free_port()
        with tempfile.TemporaryDirectory(prefix='relay-probe-hub-') as directory:
            config = Path(directory) / 'hub.toml'
            config.write_text(f'version=2\n[server]\npid_file="{directory}/hub.pid"\n[listeners.admin]\nprotocol="http"\nhost="127.0.0.1"\nport={admin}\n[control]\nlistener="listener:admin"\ntoken="fixture-admin"\n[listeners.ws]\nprotocol="websocket"\nhost="127.0.0.1"\nport={port}\n[relays.hub]\nmode="hub"\ncarrier="websocket"\nlistener="listener:ws"\npath="/vhttpd/relay"\nnode_id="hub"\ntoken="fixture-relay"\n')
            with (Path(directory) / 'runtime.log').open('w') as log:
                proc = subprocess.Popen([os.environ['VHTTPD_RELAY_PROBE_RUNTIME'], '--config', str(config)], stdout=log, stderr=log)
                try:
                    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
                    request = urllib.request.Request(f'http://127.0.0.1:{admin}/admin/runtime/relay', headers={'x-vhttpd-admin-token':'fixture-admin'})
                    def status():
                        with opener.open(request, timeout=2) as response:
                            return json.load(response)
                    deadline = time.monotonic() + 20
                    while True:
                        try:
                            before = status()
                            with socket.create_connection(('127.0.0.1', port), timeout=1):
                                pass
                            break
                        except Exception:
                            if proc.poll() is not None or time.monotonic() > deadline:
                                self.fail('Hub startup failed: ' + (Path(directory) / 'runtime.log').read_text()[-2000:])
                            time.sleep(0.1)
                    entry = dict(id='ef'*12, name='Unsaved', protocol='vhttpd', url=f'ws://127.0.0.1:{port}/vhttpd/relay', relay_id='hub', token='fixture-relay')
                    good = probe_module.probe(entry)
                    self.assertTrue(good['ok'], good)
                    bad = probe_module.probe(dict(entry,token='wrong-secret'))
                    self.assertFalse(bad['ok'])
                    self.assertEqual(bad['stage'],'Relay 认证')
                    self.assertNotIn('wrong-secret', json.dumps(bad))
                    after = status()
                    self.assertEqual(before['carrier_count'], after['carrier_count'])
                    self.assertEqual(after['carrier_count'], 0)
                finally:
                    proc.terminate()
                    try:
                        proc.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        proc.kill()
                        proc.wait()


if __name__ == '__main__':
    unittest.main()
