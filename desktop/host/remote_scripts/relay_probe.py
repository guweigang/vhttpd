"""Bounded, non-registering Relay/WebSocket probe; standard library only."""
import base64
import hashlib
import json
import os
import socket
import ssl
import struct
import time
import urllib.parse


def probe(entry):
    started = time.monotonic()
    deadline = started + 7
    stage = '网络 / DNS'
    conn = None

    def read_exact(size):
        data = bytearray()
        while len(data) < size:
            if time.monotonic() >= deadline:
                raise TimeoutError()
            conn.settimeout(max(0.001, deadline - time.monotonic()))
            chunk = conn.recv(size - len(data))
            if not chunk:
                raise EOFError()
            data.extend(chunk)
        return bytes(data)

    def send_frame(op, body=b''):
        mask = os.urandom(4)
        if len(body) > 65535:
            raise ValueError()
        header = bytes([0x80 | op, 0x80 | len(body)]) if len(body) < 126 else bytes([0x80 | op, 0xfe]) + struct.pack('!H', len(body))
        conn.settimeout(max(0.001, deadline - time.monotonic()))
        conn.sendall(header + mask + bytes(b ^ mask[i % 4] for i, b in enumerate(body)))

    try:
        url = urllib.parse.urlsplit(entry['url'])
        native = entry.get('protocol', 'vhttpd') in ('', 'vhttpd')
        token = entry.get('token', '')
        if url.scheme not in ('ws', 'wss') or not url.hostname or url.username or url.password or url.fragment:
            raise ValueError()
        port = url.port or (443 if url.scheme == 'wss' else 80)
        conn = socket.create_connection((url.hostname, port), timeout=3)
        if url.scheme == 'wss':
            stage = 'TLS'
            conn = ssl.create_default_context().wrap_socket(conn, server_hostname=url.hostname)
        stage = 'WebSocket'
        path = (url.path or '/') + ('?' + url.query if url.query else '')
        authority = '[' + url.hostname + ']' if ':' in url.hostname else url.hostname
        key = base64.b64encode(os.urandom(16)).decode()
        auth = 'Authorization: Bearer ' + token + '\r\n' if not native and token else ''
        conn.sendall(('GET ' + path + ' HTTP/1.1\r\nHost: ' + authority + ':' + str(port) + '\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ' + key + '\r\nSec-WebSocket-Version: 13\r\n' + auth + '\r\n').encode())
        header = bytearray()
        while not header.endswith(b'\r\n\r\n'):
            if len(header) >= 16384:
                raise ValueError()
            header.extend(read_exact(1))
        lines = header.decode('latin1').split('\r\n')
        headers = {}
        for line in lines[1:]:
            if ':' in line:
                name, value = line.split(':', 1)
                headers[name.lower()] = value.strip()
        expected = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode()
        if len(lines[0].split()) < 2 or lines[0].split()[1] != '101' or headers.get('sec-websocket-accept') != expected or headers.get('upgrade', '').lower() != 'websocket' or 'upgrade' not in [x.strip().lower() for x in headers.get('connection', '').split(',')]:
            raise ValueError()
        if native:
            stage = 'Relay 认证'
            node = 'workbench-probe-' + os.urandom(12).hex()
            metadata = dict(node_id=node, relay_id=entry['relay_id'], mode='agent', carrier='websocket', max_channels='1', purpose='connection-test-v1')
            frame = dict(version=1, kind='ping', id='relay-hello:' + node, trace_id=node, metadata=metadata, headers={'authorization': 'Bearer ' + token} if token else {})
            send_frame(1, json.dumps(frame).encode())
            for _ in range(8):
                a, b = read_exact(2)
                if not a & 128 or a & 0x70 or b & 128 or b & 127 == 127:
                    raise ValueError()
                size = struct.unpack('!H', read_exact(2))[0] if b & 127 == 126 else b & 127
                body = read_exact(size)
                if a & 15 == 9 and size <= 125:
                    send_frame(10, body)
                    continue
                if a & 15 != 1:
                    raise ValueError()
                ack = json.loads(body)
                meta = ack.get('metadata', {})
                if ack.get('version') != 1 or ack.get('kind') != 'pong' or ack.get('trace_id') != node or any(meta.get(k) != v for k, v in dict(purpose='connection-test-v1', node_id=node, relay_id=entry['relay_id']).items()):
                    raise ValueError()
                break
            else:
                raise ValueError()
        try:
            send_frame(8)
        except OSError:
            pass
        message = '测试通过：WebSocket 与 Relay 认证握手完成；测试会话已断开，不代表项目已连接。' if native else 'WebSocket 握手通过；应用协议和业务认证需由应用验证。测试会话已关闭。'
        return dict(ok=True, stage=stage, message=message, elapsed_ms=int((time.monotonic() - started) * 1000))
    except Exception:
        message = {'TLS': 'TLS 校验或握手失败，请检查证书、域名和系统时间。', 'WebSocket': 'WebSocket 升级失败，请检查服务地址和路径。', 'Relay 认证': 'Relay 认证未通过、协议不匹配或等待超时，请检查 Relay ID、Token 和远端状态。'}.get(stage, '无法连接远端，请检查网络、域名与端口。')
        return dict(ok=False, stage=stage, message=message, elapsed_ms=int((time.monotonic() - started) * 1000))
    finally:
        if conn is not None:
            conn.close()
