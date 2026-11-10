"""Digest challenge bounds and real TLS client-certificate transport."""
import hashlib,http.server,json,pathlib,ssl,subprocess,sys,tempfile,threading,unittest
from urllib.request import parse_http_list,parse_keqv_list
from test_protocol_probe_references import ReferenceTest,FUNCTIONS,TRANSPORT,ref

class DigestMtlsTest(ReferenceTest):
    def transport(self,p):
        code='p='+repr(p)+'\n'+TRANSPORT
        run=subprocess.run([sys.executable,'-c',code],capture_output=True,text=True,timeout=8,check=True)
        return json.loads(run.stdout),run.stdout

    def base(self,port):
        return dict(host='127.0.0.1',port=port,listener='web',protocol='stream',path='/digest',timeout_ms=2500,max_items=1,probe_secrets=[],authorization='',auth_kind='digest',digest_user='qa-user',digest_password='qa-password')

    def test_digest_challenge_success_refusal_recovery_and_reflection(self):
        for algorithm in ('MD5','SHA-256'):
            seen=[]
            class Handler(http.server.BaseHTTPRequestHandler):
                def log_message(self,*_):pass
                def do_GET(self):
                    value=self.headers.get('Authorization','');seen.append(value)
                    fields=parse_keqv_list(parse_http_list(value[7:])) if value.startswith('Digest ') else {}
                    H=lambda x:hashlib.new('md5' if algorithm=='MD5' else 'sha256',x.encode()).hexdigest()
                    expected=H(H('qa-user:qa-realm:qa-password')+':qa-nonce:'+fields.get('nc','')+':'+fields.get('cnonce','')+':auth:'+H('GET:'+self.path))
                    valid=fields.get('response')==expected and fields.get('username')=='qa-user' and fields.get('uri')==self.path and fields.get('nc')=='00000001' and fields.get('qop')=='auth'
                    challenge='Basic realm="refuse"' if self.path=='/unsupported' else 'Digest realm="qa-realm", nonce="qa-nonce", qop="auth, auth-int", algorithm='+algorithm
                    body=('data: '+(value if self.path=='/echo' else 'digest-event')+'\n\n').encode()
                    self.send_response(200 if valid else 401)
                    self.send_header('WWW-Authenticate',challenge);self.send_header('Content-Type','text/event-stream');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
            server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
            try:
                for updates,failure,count in [({},'',2),({'digest_password':'wrong'},'probe_authentication_rejected_401',2),({'auth_kind':'','digest_user':'','digest_password':''},'probe_authentication_rejected_401',1),({'path':'/unsupported'},'probe_digest_challenge_unsupported',1),({'path':'/echo'},'',2),({},'',2)]:
                    before=len(seen);p=self.base(server.server_port);p.update(updates);p['probe_secrets']=[p['digest_user'],p['digest_password']]
                    result,raw=self.transport(p);self.assertEqual(result['failure'],failure,result);self.assertEqual(len(seen)-before,count)
                    for secret in ('qa-user','qa-password','qa-nonce'):
                        self.assertNotIn(secret,raw)
                    if updates.get('path')=='/echo':self.assertNotIn('response="',result['result']['sample'])
            finally:server.shutdown();server.server_close();thread.join()

    def certificates(self,root):
        def openssl(*args):subprocess.run(['openssl',*args],capture_output=True,check=True)
        openssl('req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=localhost','-addext','subjectAltName=DNS:localhost,IP:127.0.0.1','-addext','basicConstraints=critical,CA:TRUE','-keyout',str(root/'server.key'),'-out',str(root/'server.pem'))
        openssl('req','-newkey','rsa:2048','-nodes','-subj','/CN=probe-client','-keyout',str(root/'client.key'),'-out',str(root/'client.csr'))
        (root/'client.ext').write_text('extendedKeyUsage=clientAuth\nbasicConstraints=CA:FALSE\n')
        openssl('x509','-req','-in',str(root/'client.csr'),'-CA',str(root/'server.pem'),'-CAkey',str(root/'server.key'),'-CAcreateserial','-days','1','-extfile',str(root/'client.ext'),'-out',str(root/'client.pem'))
        openssl('req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=untrusted-client','-keyout',str(root/'wrong.key'),'-out',str(root/'wrong.pem'))

    def test_mtls_actual_success_missing_untrusted_identity_and_restore(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=pathlib.Path(tmp);self.certificates(root);seen=[]
            class Handler(http.server.BaseHTTPRequestHandler):
                def log_message(self,*_):pass
                def do_GET(self):
                    seen.append(self.connection.getpeercert()['subject']);body=b'data: mtls-event\n\n'
                    self.send_response(200);self.send_header('Content-Type','text/event-stream');self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
            server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Handler);ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(root/'server.pem',root/'server.key');ctx.load_verify_locations(root/'server.pem');ctx.verify_mode=ssl.CERT_REQUIRED
            # TLS1.2 makes certificate rejection part of the handshake on both backends.
            ctx.maximum_version=ssl.TLSVersion.TLSv1_2
            server.socket=ctx.wrap_socket(server.socket,server_side=True);thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
            try:
                base=self.base(server.server_port);base.update(auth_kind='mtls',digest_user='',digest_password='',secure=True,ca_file=str(root/'server.pem'),tls_name='localhost',client_cert=str(root/'client.pem'),client_key=str(root/'client.key'))
                for updates,failure in [({},''),({'client_cert':'','client_key':''},'probe_tls_verification_failed'),({'client_cert':str(root/'wrong.pem'),'client_key':str(root/'wrong.key')},'probe_tls_verification_failed'),({'tls_name':'wrong.invalid'},'probe_tls_verification_failed'),({'client_key':str(root/'absent.key')},'probe_client_certificate_unavailable'),({},'')]:
                    p=dict(base,**updates);result,raw=self.transport(p);self.assertEqual(result['failure'],failure,result)
                    self.assertNotIn(tmp,raw);self.assertNotIn('PRIVATE KEY',raw)
                    if not failure:self.assertEqual(result['result']['events'],['mtls-event']);self.assertTrue(result['auth_configured'])
                self.assertEqual(len(seen),2)
            finally:server.shutdown();server.server_close();thread.join()

    def test_new_reference_resolution_and_guards(self):
        with tempfile.TemporaryDirectory() as tmp:
            s=self.scope(dict(USER='qa-user',PASSWORD='qa-password',CERT='client.pem',KEY='client.key'))
            q=self.fixture(tmp,dict(probe_auth_kind='mtls',probe_client_cert=ref('config.dir')+'/'+ref('env.CERT'),probe_client_key=ref('env.KEY')))
            _,p=s['resolve_probe_config'](q);self.assertEqual(p['client_key'],str(pathlib.Path(tmp)/'client.key'))
            q['options_only']=True;inv,_=s['resolve_probe_config'](q);self.assertEqual(inv['listeners'][0]['authentication'],[dict(auth_ref='auth',kind='mtls',protocols=['stream','websocket','mcp'])]);self.assertNotIn(tmp,json.dumps(inv))
            q=self.fixture(tmp,dict(probe_auth_kind='digest',probe_digest_username=ref('env.USER'),probe_digest_password=ref('env.PASSWORD')))
            _,p=s['resolve_probe_config'](q);self.assertEqual(p['digest_password'],'qa-password');self.assertEqual(p['authorization'],'')
            q['args']['protocol']='mcp'
            with self.assertRaisesRegex(s['ConfigFailure'],'digest_stream_get_required'):s['resolve_probe_config'](q)
            q=self.fixture(tmp,dict(probe_auth_kind='mtls',probe_client_cert='client.pem',probe_client_key=ref('env.ABSENT')))
            with self.assertRaisesRegex(s['ConfigFailure'],'reference_unavailable'):s['resolve_probe_config'](q)
if __name__=='__main__':unittest.main()
