#!/usr/bin/env python3
"""One vhttpd PID: real Bodytest functions + MySQL8 + Paseo WebSockets."""
import json,os,pathlib,shlex,shutil,socket,subprocess,tempfile,time,urllib.request
from ws_client import verify_paseo
ROOT=pathlib.Path(__file__).resolve().parents[2]
BINARY=os.environ['VHTTPD_BIN']
CONTAINER=os.environ['MULTI_APP_DB_CONTAINER']
COMMAND=shlex.split(os.environ.get('MULTI_APP_COMMAND',''))
HOST=os.environ.get('MULTI_APP_HOST','127.0.0.1')
DBHOST=os.environ.get('MULTI_APP_DB_HOST','127.0.0.1')
SOURCE=ROOT/'.runtime/bodytest-desktop-deploy'
HTTP=urllib.request.build_opener(urllib.request.ProxyHandler({}))
def port():
    with socket.socket() as s:s.bind(('127.0.0.1',0));return s.getsockname()[1]
def sql(statement):
    return subprocess.run(['docker','exec','-e','MYSQL_PWD=multi-fixture-only',CONTAINER,'mysql','-h127.0.0.1','-uroot','-N','-Dmulti_test','-e',statement],text=True,capture_output=True,check=True).stdout.strip()
def wait(fn,seconds=120):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        try:
            result=fn()
            if result:return result
        except (OSError,ValueError,subprocess.CalledProcessError):pass
        time.sleep(.2)
    raise AssertionError('fixture readiness timed out')
def http(port,path,data=None,token=None,admin=False):
    if COMMAND and admin:
        code='import urllib.request,json; r=urllib.request.Request('+repr(f'http://127.0.0.1:{port}{path}')+',headers={"x-vhttpd-admin-token":'+repr(token)+'}); print(urllib.request.urlopen(r,timeout=20).read().decode())'
        return json.loads(subprocess.check_output(COMMAND+['python3','-c',code],text=True))
    headers={'content-type':'application/json'}
    if token:headers['x-vhttpd-admin-token' if admin else 'authorization']=token if admin else 'Bearer '+token
    request=urllib.request.Request(f'http://{HOST}:{port}{path}',data=None if data is None else json.dumps(data).encode(),headers=headers)
    with HTTP.open(request,timeout=20) as r:return json.load(r)
def run():
    dbport=int(subprocess.check_output(['docker','port',CONTAINER,'3306/tcp'],text=True).strip().rsplit(':',1)[1])
    wait(lambda:sql('SELECT 1')=='1')
    for name in ['schema-auth-mysql.sql','schema-cloud-mysql.sql']:sql((ROOT/'examples/wechat-cloud-functions'/name).read_text())
    with tempfile.TemporaryDirectory(prefix='multi-bodytest-paseo-',dir=os.environ.get('MULTI_APP_WORK_ROOT')) as temporary:
        work=pathlib.Path(temporary);body=work/'bodytest';body.mkdir();paseo=work/'paseo';paseo.mkdir()
        for directory in ['cloudfunctions','server']:
            shutil.copytree(SOURCE/directory,body/directory,ignore=shutil.ignore_patterns('.runtime','node_modules','*.md','*.mdx','*.log'))
        (body/'server/fixture.mts').write_text("import {createBodytestApplication} from './application.mjs';\nexport default createBodytestApplication("+json.dumps({'WECHAT_APP_ID':'multi-fixture','WECHAT_APP_SECRET':'not-a-wechat-secret','WECHAT_DB_DRIVER':'mysql','WECHAT_CLOUD_ENV':'multi-fixture','WECHAT_STORAGE_ROOT':str(work/'storage')})+",{exchangeCode:async ()=>({openid:'multi-fixture-user',session_key:'fixture-session-key'})});\n")
        shutil.copy2(ROOT/'examples/paseo-relay/app.mts',paseo/'app.mts')
        web,relay,admin=port(),port(),port()
        fragment=(ROOT/'examples/paseo-relay/component.toml').read_text().replace('port = 19901',f'port = {relay}').replace('host = "127.0.0.1"','host = "0.0.0.0"' if COMMAND else 'host = "127.0.0.1"')
        (paseo/'component.toml').write_text(fragment)
        config=work/'vhttpd.toml';config.write_text(f'''version=2
include=["paseo/component.toml"]
[server]
pid_file="{work}/vhttpd.pid"
[observability]
event_log="{work}/events.ndjson"
[listeners.web]
protocol="http"
host="{'0.0.0.0' if COMMAND else '127.0.0.1'}"
port={web}
[listeners.admin]
protocol="http"
host="{'0.0.0.0' if COMMAND else '127.0.0.1'}"
port={admin}
[control]
listener="listener:admin"
token="fixture-admin"
[resources.db.wechat]
kind="mysql"
host="{DBHOST}"
port={dbport}
username="multi_test"
password="multi-fixture-only"
database="multi_test"
pool_size=2
init_sql=["SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ"]
[engines.wechat]
kind="vjsx"
entry="bodytest/server/fixture.mts"
module_root="bodytest"
signature_root="bodytest/cloudfunctions"
runtime_profile="node"
thread_count=1
enable_network=true
resources=["resource:db/wechat"]
[adapters.wechat]
kind="http-handler"
engine="engine:wechat"
[[pipelines]]
id="wechat"
ingress="listener:web"
match.paths=["*"]
egress="adapter:wechat"
''')
        log=(work/'runtime.log').open('wb')
        process=subprocess.Popen(COMMAND+[BINARY,'--config',str(config)],cwd=body,stdout=log,stderr=log)
        try:
            wait(lambda:http(relay,'/meta').get('app')=='paseo-relay')
            login=http(web,'/auth/login',{'code':'fixture'})
            assert login.get('token')
            account=http(web,'/functions/getOpenId',{},login['token']);assert account['result']['openid']=='multi-fixture-user'
            access=http(web,'/functions/familyRecords',{'action':'getAccess','miniProgramEnvVersion':'develop'},login['token'])
            assert access['result']['ok'] is True
            assert verify_paseo(HOST,relay)['bidirectional_binary']
            runtime=http(admin,'/admin/runtime',token='fixture-admin',admin=True)
            assert any(x.get('listener_id')=='paseo' for x in runtime['listeners']),runtime.get('listeners')
            pid=int((work/'vhttpd.pid').read_text().strip());assert process.poll() is None
            if not COMMAND:assert pid==process.pid
            print(json.dumps({'passed':True,'single_vhttpd_pid':pid,'bodytest_real_functions':True,'mysql8_auth_and_family_access':True,'paseo_http_and_websocket':True,'text_and_binary_bidirectional':True,'ports':[web,relay,admin]}),flush=True)
        except BaseException:
            log.flush();print((work/'runtime.log').read_text(errors='replace')[-10000:]);raise
        finally:
            process.terminate()
            try:process.wait(timeout=15)
            except subprocess.TimeoutExpired:process.kill();process.wait()
            log.close()
if __name__=='__main__':run()
