"""Exercise the production TLS reload endpoint with real WSS and SSE clients."""

import argparse
import base64
import hashlib
import http.client
import json
import os
from pathlib import Path
import socket
import ssl
import subprocess
import tempfile
import time

REPO = Path(__file__).resolve().parents[2]
ADMIN_TOKEN = "local-tls-reload-test"

APP = r"""<?php

$websocket = require __DIR__ . '/websocket-echo.php';
return [
    'websocket' => $websocket['websocket'],
    'stream' => static function (array $frame): array {
        $event = $frame['event'] ?? '';
        if (($frame['path'] ?? '') !== '/events/sse' || $event === 'close') {
            return ['handled' => false, 'done' => true];
        }
        $metadata = [
            'headers' => ['cache-control' => 'no-cache'],
            'state' => ['stream_id' => (string) ($frame['id'] ?? 'fixture')],
        ];
        if ($event === 'open') {
            return $metadata + ['handled' => true, 'done' => false, 'chunks' => [
                ['event' => 'tick', 'data' => "before\nmultiline"],
            ]];
        }
        $gate = __DIR__ . '/release-sse';
        $deadline = microtime(true) + 10;
        while (!is_file($gate) && microtime(true) < $deadline) {
            clearstatcache(true, $gate);
            usleep(20000);
        }
        return $metadata + ['handled' => true, 'done' => true, 'chunks' => [
            ['event' => 'tick', 'data' => is_file($gate) ? 'after' : 'gate timeout'],
        ]];
    },
];
"""


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def create_certificates(directory):
    fingerprints = {}
    for name, serial in (("a", "0xa1"), ("b", "0xb2")):
        cert = directory / f"{name}.pem"
        subprocess.run(
            ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes",
             "-days", "2", "-sha256", "-subj", "/CN=localhost", "-set_serial", serial,
             "-keyout", directory / f"{name}.key", "-out", cert],
            check=True, capture_output=True,
        )
        fingerprints[name] = hashlib.sha256(ssl.PEM_cert_to_DER_cert(cert.read_text())).digest()
    assert fingerprints["a"] != fingerprints["b"]
    return fingerprints


def replace_tls_files(directory, certificate, key):
    for name, suffix in ((certificate, "pem"), (key, "key")):
        candidate = directory / f"candidate.{suffix}"
        candidate.touch(mode=0o600)
        candidate.write_bytes((directory / f"{name}.{suffix}").read_bytes())
        candidate.replace(directory / f"active.{suffix}")


def connect_tls(port):
    context = ssl.SSLContext(ssl.PROTOCOL_TLS_CLIENT)
    context.check_hostname = False
    context.verify_mode = ssl.CERT_NONE  # The test pins the exact test certificate.
    with socket.create_connection(("127.0.0.1", port), timeout=5) as raw:
        tls = context.wrap_socket(raw, server_hostname="localhost")
        assert not tls.session_reused
        return tls


def fingerprint(tls):
    return hashlib.sha256(tls.getpeercert(binary_form=True)).digest()


def fresh_fingerprint(port):
    with connect_tls(port) as tls:
        return fingerprint(tls)


def reload_certificates(admin_port, token=ADMIN_TOKEN, body=None):
    conn = http.client.HTTPConnection("127.0.0.1", admin_port, timeout=5)
    headers = {"Content-Type": "application/json"}
    if token is not None:
        headers["X-VHTTPD-Admin-Token"] = token
    try:
        conn.request("POST", "/admin/runtime/tls/reload", json.dumps(body if body is not None else {}), headers)
        response = conn.getresponse()
        raw = response.read()
        try:
            return response.status, json.loads(raw)
        except ValueError as exc:
            raise AssertionError(f"TLS reload returned {response.status} with body {raw!r}") from exc
    finally:
        conn.close()


def read_headers(reader):
    status = reader.readline().strip()
    headers = {}
    while True:
        line = reader.readline()
        if line == b"\r\n":
            return status, headers
        assert line, "incomplete HTTP response"
        name, value = line.split(b":", 1)
        headers[name.lower()] = value.strip()


def upgrade_websocket(tls, reader):
    key = b"dGhlIHNhbXBsZSBub25jZQ=="
    tls.sendall(
        b"GET /ws HTTP/1.1\r\nHost: localhost\r\nConnection: Upgrade\r\n"
        b"Upgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: " + key + b"\r\n\r\n"
    )
    status, headers = read_headers(reader)
    assert status.startswith(b"HTTP/1.1 101 "), status
    assert headers[b"sec-websocket-accept"] == base64.b64encode(
        hashlib.sha1(key + b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11").digest()
    )


def read_frame(reader, opcode):
    header = reader.read(2)
    assert len(header) == 2 and header[0] == (0x80 | opcode) and header[1] < 126, header
    body = reader.read(header[1])
    assert len(body) == header[1]
    return body


def send_message(tls, message):
    mask = os.urandom(4)
    assert len(message) < 126
    tls.sendall(
        bytes([0x81, 0x80 | len(message)]) + mask
        + bytes(byte ^ mask[index % 4] for index, byte in enumerate(message))
    )


def serve_config(directory, port, admin_port):
    (directory / "websocket-echo.php").symlink_to(REPO / "examples/websocket_echo_app.php")
    (directory / "combined.php").write_text(APP)
    conf = directory / "vhttpd.toml"
    worker = REPO / "php/package/bin/vphp-worker"
    worker_command = json.dumps(f'php "{worker}"')
    conf.write_text(f"""
[paths]
root = {json.dumps(str(REPO))}
[server]
host = "127.0.0.1"
port = {port}
[server.ssl]
enabled = true
cert = "{directory / 'active.pem'}"
cert_key = "{directory / 'active.key'}"
[files]
pid_file = "{directory / 'instance.pid'}"
event_log = "{directory / 'events.ndjson'}"
[worker]
autostart = true
read_timeout_ms = 8000
pool_size = 2
stream_dispatch = true
websocket_dispatch = true
socket = "{directory / 'worker.sock'}"
cmd = {worker_command}
[worker.env]
VHTTPD_APP = "{directory / 'combined.php'}"
[executor]
kind = "php"
[php]
worker_entry = "{worker}"
app_entry = "{directory / 'combined.php'}"
[admin]
host = "127.0.0.1"
port = {admin_port}
token = "{ADMIN_TOKEN}"
""")
    return conf


def wait_ready(process, port):
    for _ in range(100):
        if process.poll() is not None:
            raise RuntimeError("vhttpd exited during startup")
        try:
            return fresh_fingerprint(port)
        except OSError:
            time.sleep(0.05)
    raise RuntimeError("TLS listener did not start")


def verify(process, directory, port, admin_port, certificates):
    original, replacement = certificates["a"], certificates["b"]
    assert wait_ready(process, port) == original
    assert reload_certificates(admin_port, token=None)[0] == 403
    assert reload_certificates(admin_port, body={"listener": "127.0.0.1:0"})[0] == 404

    with (connect_tls(port) as ws, ws.makefile("rb") as frames,
          connect_tls(port) as sse, sse.makefile("rb") as events):
        assert fingerprint(ws) == fingerprint(sse) == original
        upgrade_websocket(ws, frames)
        assert read_frame(frames, 1) == b"echo:connected"
        send_message(ws, b"before")
        assert read_frame(frames, 1) == b"echo:before"
        sse.sendall(b"GET /events/sse HTTP/1.1\r\nHost: localhost\r\nAccept: text/event-stream\r\n\r\n")
        status, headers = read_headers(events)
        assert status.startswith(b"HTTP/1.1 200 "), status
        assert headers[b"content-type"] == b"text/event-stream"
        assert [events.readline() for _ in range(4)] == [
            b"event: tick\n", b"data: before\n", b"data: multiline\n", b"\n",
        ]

        replace_tls_files(directory, "b", "a")
        assert reload_certificates(admin_port) == (422, {"error": "tls_certificate_reload_failed"})
        assert fresh_fingerprint(port) == original
        replace_tls_files(directory, "b", "b")
        assert reload_certificates(admin_port, body={"listener": f"127.0.0.1:{port}"}) == (
            200, {"status": "reloaded", "listener": f"127.0.0.1:{port}"},
        )
        for _ in range(10):
            assert fresh_fingerprint(port) == replacement
        (directory / "release-sse").touch()
        assert [events.readline() for _ in range(3)] == [
            b"event: tick\n", b"data: after\n", b"\n",
        ]
        send_message(ws, b"after")
        assert read_frame(frames, 1) == b"echo:after"
        assert fingerprint(ws) == fingerprint(sse) == original
        send_message(ws, b"bye")
        assert read_frame(frames, 8) == b"\x03\xe8bye"
        assert process.poll() is None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("binary", type=Path, help="vhttpd built with the OpenSSL reload hook")
    binary = parser.parse_args().binary.resolve()
    with tempfile.TemporaryDirectory(prefix="vhttpd-tls-") as path:
        directory = Path(path)
        certificates = create_certificates(directory)
        replace_tls_files(directory, "a", "a")
        port, admin_port = free_port(), free_port()
        while port == admin_port:
            admin_port = free_port()
        config = serve_config(directory, port, admin_port)
        log_path = directory / "vhttpd.log"
        with log_path.open("w") as log:
            process = subprocess.Popen([binary, "--config", config], cwd=REPO, stdout=log, stderr=log)
            try:
                verify(process, directory, port, admin_port, certificates)
            except Exception:
                print(log_path.read_text(), flush=True)
                raise
            finally:
                if process.poll() is None:
                    process.terminate()
                    try:
                        process.wait(timeout=5)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
    print("TLS reload passed: mismatched key kept A, 10 new handshakes got B, existing WSS and SSE survived")


if __name__ == "__main__":
    main()
