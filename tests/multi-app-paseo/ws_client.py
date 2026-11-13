"""Small stdlib-only WebSocket client for isolated integration checks."""
import base64
import hashlib
import json
import os
import socket
import ssl
import struct

class WebSocket:
    def __init__(self, host, port, path, tls=False):
        self.sock=socket.create_connection((host,port),timeout=8)
        if tls:self.sock=ssl.create_default_context().wrap_socket(self.sock,server_hostname=host)
        self.sock.settimeout(8)
        self.buffer=b''
        key=base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((f'GET {path} HTTP/1.1\r\nHost: {host}:{port}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: {key}\r\nSec-WebSocket-Version: 13\r\n\r\n').encode())
        while b'\r\n\r\n' not in self.buffer:
            data=self.sock.recv(4096)
            if not data:raise RuntimeError('closed during upgrade')
            self.buffer+=data
            if len(self.buffer)>32768:raise RuntimeError('oversize handshake')
        raw,self.buffer=self.buffer.split(b'\r\n\r\n',1)
        assert raw.split(b'\r\n',1)[0].split()[1]==b'101',raw[:200]
        headers=dict(line.decode().lower().split(':',1) for line in raw.split(b'\r\n')[1:])
        expected=base64.b64encode(hashlib.sha1((key+'258EAFA5-E914-47DA-95CA-C5AB0DC85B11').encode()).digest()).decode().lower()
        assert headers['sec-websocket-accept'].strip()==expected
    def read(self,n):
        while len(self.buffer)<n:
            chunk=self.sock.recv(max(4096,n-len(self.buffer)))
            if not chunk:raise EOFError('websocket closed')
            self.buffer+=chunk
        out,self.buffer=self.buffer[:n],self.buffer[n:]
        return out
    def send(self,data,opcode=1):
        payload=data.encode() if isinstance(data,str) else data
        mask=os.urandom(4);n=len(payload)
        length=bytes([n|128]) if n<126 else (bytes([126|128])+struct.pack('!H',n) if n<65536 else bytes([127|128])+struct.pack('!Q',n))
        self.sock.sendall(bytes([128|opcode])+length+mask+bytes(x^mask[i%4] for i,x in enumerate(payload)))
    def recv(self,timeout=8):
        self.sock.settimeout(timeout)
        while True:
            a,b=self.read(2);opcode=a&15;n=b&127
            if n==126:n=struct.unpack('!H',self.read(2))[0]
            elif n==127:n=struct.unpack('!Q',self.read(8))[0]
            if n>1048576:raise RuntimeError('oversize fixture frame')
            mask=self.read(4) if b&128 else None
            data=self.read(n)
            if mask:data=bytes(x^mask[i%4] for i,x in enumerate(data))
            if opcode==9:self.send(data,10);continue
            if opcode==10:continue
            if opcode==8:raise EOFError('close frame')
            assert a&128,'fixture expects complete frames'
            return opcode,data
    def json(self):
        opcode,data=self.recv();assert opcode==1
        return json.loads(data)
    def close(self):
        try:
            self.send(struct.pack('!H',1000),8)
            # Complete the close handshake before discarding the TCP socket.
            # Immediate TCP close races server cleanup on fast reconnects.
            while True:self.recv(timeout=2)
        except (OSError,EOFError):pass
        finally:self.sock.close()

def verify_paseo(host,port,tls=False):
    sockets=[]
    def connect(path):
        ws=WebSocket(host,port,path,tls=tls);sockets.append(ws);return ws
    try:
        base='/ws?serverId=multi-app-fixture&v=2&'
        control=connect(base+'role=server')
        assert control.json()['type']=='sync'
        client=connect(base+'role=client&connectionId=fixture-connection')
        notice=control.json();assert notice['type']=='connected' and notice['connectionId']=='fixture-connection'
        client.send('buffered-before-server-data')
        data=connect(base+'role=server&connectionId=fixture-connection')
        assert data.recv()==(1,b'buffered-before-server-data')
        data.send('reply-from-server');assert client.recv()==(1,b'reply-from-server')
        client.send(b'\x00\xff\x01',2);assert data.recv()==(2,b'\x00\xff\x01')
        data.send(b'\x02\x00\xfe',2);assert client.recv()==(2,b'\x02\x00\xfe')
        return {'control_sync':True,'pending_buffer_flush':True,'bidirectional_text':True,'bidirectional_binary':True}
    finally:
        for ws in reversed(sockets):ws.close()
