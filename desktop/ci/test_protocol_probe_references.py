"""Target-owned references and Basic/X-API-Key transport contracts."""
import base64,http.server,json,os,pathlib,socket,ssl,subprocess,sys,tempfile,threading,unittest
ROOT=pathlib.Path(__file__).parents[1]/'host/remote_scripts'
FUNCTIONS=(ROOT/'protocol_probe_config.py').read_text().split('\ntry:\n    inventory,p=')[0]
TRANSPORT=(ROOT/'protocol_probe.py').read_text()
def ref(name): return chr(36)+'{'+name+'}'

class ReferenceTest(unittest.TestCase):
    def scope(self,env):
        scope={};exec(FUNCTIONS,scope);scope['runtime_environment']=lambda _:env;return scope

    def fixture(self,tmp,options,cert='cert.pem'):
        root=pathlib.Path(tmp);child=root/'component.toml';config=root/'vhttpd.toml'
        config.write_text('version=2\ninclude=["component.toml"]\n[control]\nlistener="listener:admin"\n')
        child.write_text('[listeners.web]\nprotocol="http"\nhost="::1"\nport=12345\n[listeners.web.tls]\nenabled=true\ncert='+json.dumps(cert)+'\n'
            '[listeners.admin]\nprotocol="http"\nhost="127.0.0.1"\nport=12346\n'
            '[adapters.auth]\noptions={'+','.join(k+'='+json.dumps(v) for k,v in options.items())+'}\n'
            '[[pipelines]]\ningress="listener:web"\negress="adapter:auth"\n')
        return dict(config_path=str(config),sources={str(config):config.read_text(),str(child):child.read_text()},
            args=dict(listener='web',protocol='stream',path='/probe',message='',auth_ref='auth',
                tls_trust='listener_certificate',tls_server_name='localhost',timeout_ms=2000,max_items=1))

    def test_resolution_missing_defaults_cycles_and_snapshot(self):
        with tempfile.TemporaryDirectory() as tmp:
            env={'SECRET':'remote-only-value','CERT':'cert.pem'};s=self.scope(env)
            q=self.fixture(tmp,{'probe_bearer_token':ref('env.SECRET')},ref('config.dir')+'/'+ref('env.CERT'))
            _,p=s['resolve_probe_config'](q)
            self.assertEqual(p['authorization'],'Authorization: Bearer remote-only-value\r\n')
            self.assertEqual(p['ca_file'],str(pathlib.Path(tmp)/'cert.pem'))
            q['options_only']=True;inv,_=s['resolve_probe_config'](q)
            self.assertNotIn('remote-only-value',json.dumps(inv));self.assertNotIn(tmp,json.dumps(inv))
            self.assertEqual([i['listener'] for i in inv['listeners']],['web'])
            self.assertEqual(inv['listeners'][0]['auth_refs'],['auth'])
            self.assertEqual(s['expand'](ref('env.ABSENT:-fallback'),tmp,lambda:env),'fallback')
            for expr in (ref('env.ABSENT'),ref('unknown'),ref('env.LOOP')):
                with self.assertRaises(s['ConfigFailure']): s['expand'](expr,tmp,lambda:dict(env,LOOP=ref('env.LOOP')))
            pathlib.Path(q['config_path']).write_text('version=2\n')
            with self.assertRaisesRegex(s['ConfigFailure'],'configuration_changed'):s['resolve_probe_config'](q)

    def test_credentials_header_injection_and_no_desktop_fallback(self):
        s=self.scope({})
        with tempfile.TemporaryDirectory() as tmp:
            os.environ['VHTTPD_DESKTOP_ONLY']='must-never-substitute'
            try:
                q=self.fixture(tmp,{'probe_auth_kind':'api_key','probe_api_key':ref('env.VHTTPD_DESKTOP_ONLY')})
                with self.assertRaisesRegex(s['ConfigFailure'],'reference_unavailable'): s['resolve_probe_config'](q)
                q['options_only']=True;inv,_=s['resolve_probe_config'](q)
                self.assertEqual(inv['listeners'][0]['auth_refs'],[])
                self.assertNotIn('must-never-substitute',json.dumps(inv))
            finally: del os.environ['VHTTPD_DESKTOP_ONLY']
            for options in [
                {'probe_auth_kind':'basic','probe_basic_username':'u:bad','probe_basic_password':'p'},
                {'probe_auth_kind':'basic','probe_basic_username':'u','probe_basic_password':'p\r\nX-Forged: yes'},
                {'probe_auth_kind':'api_key','probe_api_key':'key\n'},
                {'probe_auth_kind':'oauth','probe_bearer_token':'unused'}]:
                with self.assertRaises(s['ConfigFailure']): s['resolve_probe_config'](self.fixture(tmp,options))

    def test_basic_api_tls_success_refusal_redaction_restore_both_families(self):
        with tempfile.TemporaryDirectory() as tmp:
            cert=pathlib.Path(tmp)/'cert.pem';key=pathlib.Path(tmp)/'key.pem'
            subprocess.run(['openssl','req','-x509','-newkey','rsa:2048','-nodes','-days','1','-subj','/CN=localhost',
                '-addext','subjectAltName=DNS:localhost,IP:127.0.0.1,IP:::1','-keyout',str(key),'-out',str(cert)],capture_output=True,check=True)
            for host in ('127.0.0.1','::1'):
                for kind in ('basic','api_key'):
                    with self.subTest(host=host,kind=kind):
                        expected='Basic '+base64.b64encode(b'private-user:private-password').decode() if kind=='basic' else 'private-api-key';seen=[]
                        class Handler(http.server.BaseHTTPRequestHandler):
                            def log_message(self,*_):pass
                            def do_GET(self):
                                auth=self.headers.get('Authorization' if kind=='basic' else 'X-API-Key');seen.append(auth)
                                body=(auth or 'none').encode() if self.path=='/echo' else b'data: reference-event\n\n'
                                self.send_response(200 if auth==expected else 401)
                                self.send_header('Content-Type','text/plain' if self.path=='/echo' else 'text/event-stream')
                                self.send_header('Content-Length',str(len(body)));self.end_headers();self.wfile.write(body)
                        class Server(http.server.ThreadingHTTPServer):address_family=socket.AF_INET6 if host=='::1' else socket.AF_INET
                        server=Server((host,0),Handler);ctx=ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER);ctx.load_cert_chain(cert,key);server.socket=ctx.wrap_socket(server.socket,server_side=True)
                        thread=threading.Thread(target=server.serve_forever,daemon=True);thread.start()
                        try:
                            options={'probe_auth_kind':kind,'probe_basic_username':ref('env.PROBE_USER'),'probe_basic_password':ref('env.PROBE_PASSWORD')} if kind=='basic' else {'probe_auth_kind':kind,'probe_api_key':ref('env.PROBE_KEY')}
                            q=self.fixture(tmp,options,ref('env.PROBE_CERT'))
                            child=pathlib.Path(tmp)/'component.toml';text=child.read_text().replace('port=12345','port='+str(server.server_port)).replace('host="::1"','host='+json.dumps(host));child.write_text(text);q['sources'][str(child)]=text
                            env=dict(PROBE_USER='private-user',PROBE_PASSWORD='private-password',PROBE_KEY='private-api-key',PROBE_CERT=str(cert))
                            for updates,failure in [({},''),({'auth_ref':''},'probe_authentication_rejected_401'),({'tls_server_name':'wrong.invalid'},'probe_tls_verification_failed'),({'path':'/echo'},''),({},'')]:
                                request=dict(q,args=dict(q['args'],**updates))
                                code=FUNCTIONS+'\nruntime_environment=lambda _: '+repr(env)+'\n_,p=resolve_probe_config('+repr(request)+')\n'+TRANSPORT
                                run=subprocess.run([sys.executable,'-c',code],capture_output=True,text=True,check=True,timeout=6);result=json.loads(run.stdout)
                                self.assertEqual(result['failure'],failure,result);self.assertEqual(result['ok'],not failure,result)
                                for secret in ('private-user','private-password','private-api-key',expected):self.assertNotIn(secret,run.stdout)
                                if not updates:self.assertEqual(result['result']['events'],['reference-event'])
                            self.assertEqual(len(seen),4)
                        finally:server.shutdown();server.server_close();thread.join()
if __name__=='__main__':unittest.main()
