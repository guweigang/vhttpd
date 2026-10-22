"""Single-session TLS/WebSocket peer for the bridge sender lifetime regression."""
import base64
import hashlib
import json
import pathlib
import socket
import ssl
import sys

root = pathlib.Path(sys.argv[1])
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(root / 'cert.pem', root / 'key.pem')
with socket.socket() as listener:
    listener.bind(('127.0.0.1', 0))
    listener.listen(1)
    listener.settimeout(10)
    (root / 'port').write_text(str(listener.getsockname()[1]))
    raw, _ = listener.accept()
    with ctx.wrap_socket(raw, server_side=True) as conn:
        conn.settimeout(10)
        request = b''
        while not request.endswith(b'\r\n\r\n'):
            request += conn.recv(1)
        headers = dict(line.split(':', 1) for line in request.decode().split('\r\n')[1:] if ':' in line)
        key = next(value.strip() for name, value in headers.items() if name.lower() == 'sec-websocket-key')
        accept = base64.b64encode(hashlib.sha1((key + '258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest())
        conn.sendall(b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: ' + accept + b'\r\n\r\n')
        def read_exact(length):
            result = b''
            while len(result) < length:
                part = conn.recv(length - len(result))
                if not part:
                    raise EOFError('truncated websocket frame')
                result += part
            return result
        frames = []
        while True:
            first, second = read_exact(2)
            length = second & 127
            if length == 126:
                length = int.from_bytes(read_exact(2), 'big')
            elif length == 127:
                length = int.from_bytes(read_exact(8), 'big')
            mask = read_exact(4) if second & 128 else b''
            payload = read_exact(length)
            if mask:
                payload = bytes(value ^ mask[i % 4] for i, value in enumerate(payload))
            opcode = first & 15
            if opcode == 8:
                (root / 'frames.json').write_text(json.dumps(frames))
                conn.sendall(bytes([0x88, len(payload)]) + payload)
                break
            frames.append(payload.decode())
