"""Loopback-only Digest/mTLS peer for native and real-client acceptance.
Owns only its temporary certificates, two listeners and audit counters.
"""
import hashlib,hmac,http.server,json,os,pathlib,signal,ssl,subprocess,sys,threading,time
from urllib.request import parse_http_list,parse_keqv_list
root=pathlib.Path(sys.argv[1]);root.mkdir(exist_ok=True,parents=True);os.chmod(root,0o700)
def openssl(*args):subprocess.run(['openssl',*args],capture_output=True,check=True)
if not (root/'server.pem').exists():
    openssl('req','-x509','-newkey','rsa:2048','-nodes','-days','2','-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost,IP:127.0.0.1','-addext','basicConstraints=critical,CA:TRUE','-keyout',str(root/'server.key'),'-out',str(root/'server.pem'))
    openssl('req','-newkey','rsa:2048','-nodes','-subj','/CN=dedicated-probe-client','-keyout',str(root/'client.key'),'-out',str(root/'client.csr'))
    (root/'client.ext').write_text('extendedKeyUsage=clientAuth\nbasicConstraints=CA:FALSE\n')
    openssl('x509','-req','-in',str(root/'client.csr'),'-CA',str(root/'server.pem'),'-CAkey',str(root/'server.key'),'-CAcreateserial','-days','2','-extfile',str(root/'client.ext'),'-out',str(root/'client.pem'))
    openssl('req','-x509','-newkey','rsa:2048','-nodes','-days','2','-subj','/CN=not-trusted-client','-keyout',str(root/'wrong.key'),'-out',str(root/'wrong.pem'))
for p in root.glob('*.key'):os.chmod(p,0o600)
# Dedicated test values only. Never log Authorization, key material or subject.
user='isolated-digest-user';password='isolated-digest-password';nonce=os.urandom(24).hex();counts={'digest_requests':0,'digest_success':0,'mtls_success':0}
class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self,*_):pass
    def do_GET(self):
        tls=isinstance(self.connection,ssl.SSLSocket)
        valid=tls and bool(self.connection.getpeercert())
        if not tls:
            counts['digest_requests']+=1;value=self.headers.get('Authorization','');f=parse_keqv_list(parse_http_list(value[7:])) if value.startswith('Digest ') else {}
            algo='MD5' if self.path=='/md5' else 'SHA-256';H=lambda v:hashlib.new('md5' if algo=='MD5' else 'sha256',v.encode()).hexdigest()
            expected=H(H(user+':isolated:'+password)+':'+nonce+':'+f.get('nc','')+':'+f.get('cnonce','')+':auth:'+H('GET:'+self.path))
            valid=f.get('username')==user and f.get('nonce')==nonce and f.get('uri')==self.path and f.get('qop')=='auth' and f.get('nc')=='00000001' and hmac.compare_digest(f.get('response',''),expected)
            challenge='Basic realm="unsupported"' if self.path=='/unsupported' else 'Digest realm="isolated", nonce="'+nonce+'", algorithm='+algo+', qop="auth"'
        if valid:counts['mtls_success' if tls else 'digest_success']+=1
        body=('data: '+('mtls-peer-ok' if tls else 'digest-peer-ok')+'\n\n').encode()
        self.send_response(200 if valid else 401)
        if not tls:self.send_header('WWW-Authenticate',challenge)
        self.send_header('Content-Type','text/event-stream');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
servers=[http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler) for _ in range(2)]
ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(root/'server.pem',root/'server.key');ctx.load_verify_locations(root/'server.pem');ctx.verify_mode=ssl.CERT_REQUIRED;ctx.maximum_version=ssl.TLSVersion.TLSv1_2
servers[1].socket=ctx.wrap_socket(servers[1].socket,server_side=True)
for server in servers:threading.Thread(target=server.serve_forever,daemon=True).start()
(root/'ready.json').write_text(json.dumps(dict(pid=os.getpid(),digest_port=servers[0].server_port,mtls_port=servers[1].server_port)))
stop=threading.Event();signal.signal(signal.SIGTERM,lambda *_:stop.set());signal.signal(signal.SIGINT,lambda *_:stop.set())
try:
    while not stop.wait(.2):pass
finally:
    for server in servers:server.shutdown();server.server_close()
    (root/'audit.json').write_text(json.dumps(counts))
