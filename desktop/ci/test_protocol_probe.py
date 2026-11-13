"""Remote stdlib transport conformance: session cleanup on success and RPC failure."""
import http.server
import json
import socket
import base64
import hashlib
import pathlib
import subprocess
import sys
import threading
import unittest
import ssl
import tempfile

SCRIPT = pathlib.Path(__file__).parents[1] / 'host/remote_scripts/protocol_probe.py'

class ProbeTest(unittest.TestCase):
    def check_data(self, host, protocol, secure=False):
        seen = []
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def do_GET(self):
                seen.append(self.headers.get('Host'))
                if secure: assert self.headers.get('Authorization') == 'Bearer private-transport-token'
                if protocol == 'stream':
                    body = b'data: ipv6-probe-event\n\n'
                    self.send_response(200)
                    self.send_header('Content-Type', 'text/event-stream')
                    self.send_header('Content-Length', str(len(body)))
                    self.end_headers()
                    self.wfile.write(body)
                    return
                accept = base64.b64encode(hashlib.sha1((self.headers['Sec-WebSocket-Key'] +
                    '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
                self.send_response(101)
                self.send_header('Upgrade', 'websocket')
                self.send_header('Connection', 'Upgrade')
                self.send_header('Sec-WebSocket-Accept', accept)
                self.end_headers()
                frame = self.rfile.read(2)
                if len(frame) != 2 or frame[0] != 129 or not frame[1] & 128: return
                length = frame[1] & 127
                mask = self.rfile.read(4)
                data = self.rfile.read(length)
                text = bytes(b ^ mask[i % 4] for i, b in enumerate(data))
                self.wfile.write(bytes([129, len(text)]) + text)
                self.wfile.flush()
        class Server(http.server.ThreadingHTTPServer):
            address_family = socket.AF_INET6 if host == '::1' else socket.AF_INET
        server = Server((host, 0), Handler)
        temporary = tempfile.TemporaryDirectory(prefix='probe-secure-transport-') if secure else None
        cert = None
        if secure:
            cert, key = pathlib.Path(temporary.name)/'cert.pem', pathlib.Path(temporary.name)/'key.pem'
            subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1','-keyout',str(key),'-out',str(cert)],check=True,capture_output=True)
            ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(cert,key)
            server.socket=ctx.wrap_socket(server.socket,server_side=True)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            payload = dict(host=host, port=server.server_port, path='/probe', protocol=protocol,
                           listener='web', message='ipv6-echo' if protocol == 'websocket' else '',
                           timeout_ms=2000, max_items=1, secure=secure, ca_file=str(cert) if cert else '', tls_name='localhost', authorization='Authorization: Bearer private-transport-token\r\n' if secure else '')
            code = 'p = ' + repr(payload) + '\n' + SCRIPT.read_text()
            process = subprocess.run([sys.executable, '-c', code], text=True,
                                     capture_output=True, timeout=5, check=True)
            result = json.loads(process.stdout)
            self.assertTrue(result['ok'], result)
            self.assertEqual(result['tls_verified'],secure)
            self.assertNotIn('private-transport-token',process.stdout)
            self.assertEqual(result['address_family'], 'ipv6' if host == '::1' else 'ipv4')
            self.assertEqual(seen, [('[' + host + ']' if host == '::1' else host) + ':' + str(server.server_port)])
            if protocol == 'stream': self.assertEqual(result['result']['events'], ['ipv6-probe-event'])
            else: self.assertEqual(result['result']['messages'], ['ipv6-echo'])
        finally:
            server.shutdown(); server.server_close(); thread.join()
            if temporary: temporary.cleanup()

    def test_ipv4_and_ipv6_stream_and_websocket_data(self):
        for host in ('127.0.0.1', '::1'):
            for protocol in ('stream', 'websocket'):
                with self.subTest(host=host, protocol=protocol): self.check_data(host, protocol)

    def test_authenticated_tls_stream_and_websocket_both_families(self):
        for host in ('127.0.0.1','::1'):
            for protocol in ('stream','websocket'):
                with self.subTest(host=host,protocol=protocol): self.check_data(host,protocol,True)

    def test_tls_auth_success_rejection_identity_trust_and_redaction(self):
        with tempfile.TemporaryDirectory(prefix='vhttpd-probe-tls-') as tmp:
            cert, key = pathlib.Path(tmp)/'cert.pem', pathlib.Path(tmp)/'key.pem'
            subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1',
                '-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1',
                '-keyout',str(key),'-out',str(cert)],check=True,capture_output=True)
            seen=[]
            class Handler(http.server.BaseHTTPRequestHandler):
                def log_message(self,*_): pass
                def do_GET(self):
                    token=self.headers.get('Authorization')
                    seen.append(token)
                    body=b'data: secure-event\n\n' if token=='Bearer private-probe-token' else b'rejected'
                    if self.path=='/echo': body=(token or '').encode()
                    self.send_response(200 if token=='Bearer private-probe-token' else 401)
                    self.send_header('Content-Type','text/event-stream' if self.path!='/echo' else 'text/plain')
                    self.send_header('Content-Length',str(len(body))); self.end_headers(); self.wfile.write(body)
            for host in ('127.0.0.1','::1'):
                class Server(http.server.ThreadingHTTPServer):
                    address_family=socket.AF_INET6 if host=='::1' else socket.AF_INET
                server=Server((host,0),Handler)
                ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER); ctx.load_cert_chain(cert,key)
                server.socket=ctx.wrap_socket(server.socket,server_side=True)
                thread=threading.Thread(target=server.serve_forever,daemon=True); thread.start()
                try:
                    base=dict(host=host,port=server.server_port,path='/probe',protocol='stream',listener='secure',
                        message='',timeout_ms=2000,max_items=1,secure=True,tls_name='localhost',ca_file=str(cert),
                        authorization='Authorization: Bearer private-probe-token\r\n')
                    for updates,expected in [({},''),({'authorization':''},'probe_authentication_rejected_401'),
                            ({'tls_name':'wrong.invalid'},'probe_tls_verification_failed'),
                            ({'ca_file':''},'probe_tls_verification_failed'),({'path':'/echo'},'')]:
                        with self.subTest(host=host,updates=list(updates)):
                            payload=dict(base,**updates)
                            code='p = '+repr(payload)+'\n'+SCRIPT.read_text()
                            process=subprocess.run([sys.executable,'-c',code],text=True,capture_output=True,timeout=5,check=True)
                            result=json.loads(process.stdout)
                            self.assertEqual(result['failure'],expected,result)
                            self.assertEqual(result['ok'],not expected,result)
                            self.assertEqual(result['tls_verified'],expected!='probe_tls_verification_failed')
                            self.assertNotIn('private-probe-token',process.stdout)
                            if not updates: self.assertEqual(result['result']['events'],['secure-event'])
                finally: server.shutdown(); server.server_close(); thread.join()
            # Failed TLS handshakes send neither HTTP nor the credential.
            self.assertEqual(seen,['Bearer private-probe-token',None,'Bearer private-probe-token']*2)

    def check_session(self, fail, host="127.0.0.1"):
        seen = []
        class Handler(http.server.BaseHTTPRequestHandler):
            def log_message(self, *_): pass
            def reply(self, status, body=b'', headers=None):
                self.send_response(status)
                for k, v in (headers or {}).items(): self.send_header(k, v)
                self.send_header('Content-Length', str(len(body)))
                self.end_headers()
                self.wfile.write(body)
            def do_POST(self):
                request = json.loads(self.rfile.read(int(self.headers['Content-Length'])))
                seen.append(request['method'])
                if request['method'] == 'initialize':
                    self.reply(200, b'{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-03-26"}}',
                               {'Content-Type': 'application/json', 'Mcp-Session-Id': 'test-session-private'})
                elif request['method'] == 'notifications/initialized':
                    self.reply(202)
                else:
                    response = {'jsonrpc': '2.0', 'id': 2}
                    response['error' if fail else 'result'] = {'code': -32603} if fail else {'tools': [{'name': 'hello'}]}
                    body = 'data: {"jsonrpc":"2.0","method":"notifications/message"}\n\n' + 'data: ' + json.dumps(response) + '\n\n'
                    self.reply(200, body.encode(), {'Content-Type': 'text/event-stream'})
            def do_DELETE(self):
                seen.append('delete:' + self.headers.get('Mcp-Session-Id', ''))
                self.reply(204)
        class Server(http.server.ThreadingHTTPServer):
            address_family = socket.AF_INET6 if host == '::1' else socket.AF_INET
        server = Server((host, 0), Handler)
        thread = threading.Thread(target=server.serve_forever, daemon=True); thread.start()
        try:
            payload = dict(host=host, port=server.server_port, path='/mcp', protocol='mcp', listener='web',
                           message='', timeout_ms=2000, max_items=2)
            code = 'p = ' + repr(payload) + '\n' + SCRIPT.read_text()
            p = subprocess.run([sys.executable, '-c', code], text=True, capture_output=True, timeout=5, check=True)
            result = json.loads(p.stdout)
            self.assertEqual(result['ok'], not fail, result)
            self.assertEqual(result['address_family'], 'ipv6' if host == '::1' else 'ipv4')
            self.assertNotIn('test-session-private', p.stdout)
            self.assertEqual(seen, ['initialize', 'notifications/initialized', 'tools/list', 'delete:test-session-private'])
            if not fail: self.assertEqual(result['result']['tools'], ['hello'])
        finally:
            server.shutdown(); server.server_close(); thread.join()
    def test_ipv6_session_cleanup_after_tools_list(self): self.check_session(False, '::1')
    def test_ipv6_session_cleanup_after_rpc_error(self): self.check_session(True, '::1')
    def test_session_cleanup_after_tools_list(self): self.check_session(False)
    def test_session_cleanup_after_rpc_error(self): self.check_session(True)

if __name__ == '__main__': unittest.main()
