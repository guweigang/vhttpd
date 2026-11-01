"""Loopback-only SSH fixture. Python/Paramiko are CI tools, never package files."""
import base64
import hashlib
import http.server
import json
from pathlib import Path
import socket
import sys
import threading
import time

import paramiko

PASSWORD = "CI-only $ quote' \" test password"

class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = b'vhttpd-windows-ssh-fixture'
        self.send_response(200)
        self.send_header('Content-Length', str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *_):
        pass

web = http.server.ThreadingHTTPServer(('127.0.0.1', 0), Handler)
threading.Thread(target=web.serve_forever, daemon=True).start()
key = paramiko.RSAKey.generate(2048)

class SSH(paramiko.ServerInterface):
    def __init__(self):
        self.forwards = {}
    def get_allowed_auths(self, username):
        return 'password'
    def check_auth_password(self, username, password):
        return paramiko.AUTH_SUCCESSFUL if username == 'fixture' and password == PASSWORD else paramiko.AUTH_FAILED
    def check_channel_request(self, kind, chanid):
        return paramiko.OPEN_SUCCEEDED if kind == 'session' else paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
    def check_channel_direct_tcpip_request(self, chanid, origin, destination):
        if destination != ('127.0.0.1', web.server_port):
            return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED
        self.forwards[chanid] = destination
        return paramiko.OPEN_SUCCEEDED
    def check_channel_exec_request(self, channel, command):
        def execute():
            if b'VHTTPD_SSH_READY' in command:
                channel.sendall(b'VHTTPD_SSH_READY\n')
                while not channel.closed:
                    time.sleep(.05)
                return
            if command != b'/bin/sh -s':
                channel.send_exit_status(1)
                channel.close()
                return
            data = b''
            while b'\nexit\n' not in data and len(data) < 16384:
                chunk = channel.recv(4096)
                if not chunk:
                    break
                data += chunk
            if b'VHTTPD_FIXTURE_COMMAND' in data:
                channel.sendall(b'VHTTPD_FIXTURE_COMMAND\n')
                channel.send_exit_status(0)
            else:
                channel.send_exit_status(1)
            channel.close()
        threading.Thread(target=execute, daemon=True).start()
        return True

def forward(channel, destination):
    upstream = socket.create_connection(destination, timeout=5)
    def upload():
        try:
            while data := channel.recv(65536):
                upstream.sendall(data)
        except OSError:
            pass
        finally:
            try: upstream.shutdown(socket.SHUT_WR)
            except OSError: pass
    threading.Thread(target=upload, daemon=True).start()
    try:
        while data := upstream.recv(65536):
            channel.sendall(data)
    finally:
        channel.close()
        upstream.close()

def serve(connection):
    transport = paramiko.Transport(connection)
    transport.add_server_key(key)
    server = SSH()
    try:
        transport.start_server(server=server)
        while transport.is_active():
            channel = transport.accept(.25)
            if channel is not None and channel.get_id() in server.forwards:
                threading.Thread(target=forward, args=(channel, server.forwards[channel.get_id()]), daemon=True).start()
    except (EOFError, OSError, paramiko.SSHException):
        pass
    finally:
        transport.close()

listener = socket.socket()
listener.bind(('127.0.0.1', 0))
listener.listen(8)
metadata = {'port': listener.getsockname()[1], 'http_port': web.server_port,
            'fingerprint': 'SHA256:' + base64.b64encode(hashlib.sha256(key.asbytes()).digest()).decode().rstrip('=')}
Path(sys.argv[1]).write_text(json.dumps(metadata), encoding='utf-8')
while True:
    connection, _ = listener.accept()
    threading.Thread(target=serve, args=(connection,), daemon=True).start()
