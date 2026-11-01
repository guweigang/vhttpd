#!/usr/bin/env python3
"""Remote HTTP -> WebSocket -> local vjsx -> remote MySQL, no Node runtime."""
import concurrent.futures
import hashlib
import json
import os
import pathlib
import shutil
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request
sys.path.insert(0,str(pathlib.Path(__file__).resolve().parents[1]/'relay-db'))
from e2e import ROOT, BINARY, CONTAINER, DOCKER, REMOTE_COMMAND, REMOTE_BINARY, DATABASE_HOST, RELAY_HOST, RELAY_LISTEN_HOST, port, sql, wait
from fault_link import FaultLink
sys.path.insert(0,str(ROOT/'tests/multi-app-paseo'))
from ws_client import verify_paseo


def request(url,payload=None,token=None,admin=False):
    headers={'Content-Type':'application/json'}
    if token: headers['x-vhttpd-admin-token' if admin else 'Authorization']=token if admin else 'Bearer '+token
    req=urllib.request.Request(url,data=None if payload is None else json.dumps(payload).encode(),headers=headers)
    try:
        with urllib.request.build_opener(urllib.request.ProxyHandler({})).open(req,timeout=75) as r:return r.status,json.load(r),dict(r.headers)
    except urllib.error.HTTPError as e:return e.code,json.loads(e.read()),dict(e.headers)


def run():
    dbport=int(subprocess.check_output(DOCKER+['port',CONTAINER,'3306/tcp'],text=True).strip().rsplit(':',1)[1])
    wait(lambda:sql('SELECT 1')=='1',180)
    sql((ROOT/'examples/wechat-cloud-functions/schema-auth-mysql.sql').read_text())
    sql((ROOT/'examples/wechat-cloud-functions/schema-cloud-mysql.sql').read_text())
    with tempfile.TemporaryDirectory(prefix='vhttpd-takeover-',dir=os.environ.get('RELAY_DB_WORK_ROOT')) as tmp:
        work=pathlib.Path(tmp)
        remoteport,localport,remoteadmin,localadmin=port(),port(),port(),port()
        link=FaultLink(RELAY_HOST,remoteport)
        configs=[]
        paseo_port=port() if os.environ.get('RELAY_TAKEOVER_PASEO')=='1' else 0
        for side,web,adm in [('remote',remoteport,remoteadmin),('local',localport,localadmin)]:
            config=work/(side+'.toml')
            base=f'''version=2
[server]
pid_file="{work}/{side}.pid"
[observability]
event_log="{work}/{side}.events"
[listeners.web]
protocol="http"
transport="tcp"
host="{RELAY_LISTEN_HOST if side=='remote' else '127.0.0.1'}"
port={web}
[listeners.admin]
protocol="http"
host="127.0.0.1"
port={adm}
[control]
listener="listener:admin"
token="fixture-admin"
[resources.db.test]
kind="mysql"
'''
            if side=='remote':
                base+=f'''host="{DATABASE_HOST}"
port={dbport}
database="relay_test"
username="relay_test"
password="relay-test-only"
pool_size=4
init_sql=["SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ"]
[relays.database]
mode="hub"
carrier="websocket"
listener="listener:web"
path="/relay"
node_id="fixture-hub"
token="fixture-relay-secret"
[adapters.database]
kind="db-resource"
options.resource="db/test"
options.access="read-write"
[adapters.debug_control]
kind="debug-control"
options.route="debug/http"
[[pipelines]]
id="resource/database"
ingress="relay:database"
egress="adapter:database"
[[pipelines]]
id="debug/control"
ingress="relay:database"
egress="adapter:debug_control"
'''
            else:
                base+=f'''options.relay="relay:database"
options.route="resource/database"
options.remote_resource="db/test"
[relays.database]
mode="agent"
carrier="websocket"
url="ws://127.0.0.1:{link.port}/relay"
node_id="fixture-local"
token="fixture-relay-secret"
autostart=true
reconnect_delay_ms=100
[adapters.local_debug]
kind="debug-http"
engine="engine:app"
[[pipelines]]
id="debug/http"
ingress="relay:database"
egress="adapter:local_debug"
'''
            base+=f'''[engines.app]
kind="vjsx"
entry="{ROOT}/tests/relay-takeover/{side}.mts"
module_root="{ROOT}/tests/relay-takeover"
runtime_profile="node"
thread_count=1
resources=["resource:db/test"]
[adapters.app]
kind="http-handler"
engine="engine:app"
[[pipelines]]
id="app"
ingress="listener:web"
egress="adapter:app"
'''
            if side=='remote' and paseo_port:
                paseo=work/'paseo';paseo.mkdir()
                shutil.copy2(ROOT/'examples/paseo-relay/app.mts',paseo/'app.mts')
                component=(ROOT/'examples/paseo-relay/component.toml').read_text().replace('port = 19901',f'port = {paseo_port}')
                if REMOTE_COMMAND:component=component.replace('host = "127.0.0.1"','host = "0.0.0.0"')
                (paseo/'component.toml').write_text(component)
                base=base.replace('version=2\n','version=2\ninclude=["paseo/component.toml"]\n',1)
            config.write_text(base)
            configs.append(config)
        processes=[];logs=[]
        try:
            for config in configs:
                log=(work/(config.stem+'.log')).open('ab');logs.append(log)
                cmd=REMOTE_COMMAND+[REMOTE_BINARY] if config.stem=='remote' else [str(BINARY)]
                processes.append(subprocess.Popen(cmd+['--config',str(config)],cwd=ROOT,stdout=log,stderr=log,
                    env={**os.environ,'VHTTPD_VJSX_BOOTSTRAP_TIMEOUT_MS':'120000'}))
            remote=f'http://{RELAY_HOST}:{remoteport}'
            local=f'http://127.0.0.1:{localport}'
            control=f'http://127.0.0.1:{localadmin}/admin/runtime/takeover'
            wait(lambda:request(remote+'/fixture-ready')[0]==200,180)
            wait(lambda:request(local+'/fixture-ready')[0]==200,180)
            if paseo_port:
                assert request(f'http://{RELAY_HOST}:{paseo_port}/meta')[1]['app']=='paseo-relay'
                assert verify_paseo(RELAY_HOST,paseo_port)['bidirectional_binary']
            def ctl(action,**kw):return request(control,{'action':action,'relay_id':'database',**kw},'fixture-admin',True)
            wait(lambda:ctl('status')[0]==200,60)
            assert request(control,{'action':'start'})[0]==403
            # More requests than the default 1024-channel capacity: completed
            # resource/control channels must be retired, not accumulated.
            for _ in range(1100):
                assert ctl('status')[0]==200
            print('PASS 1100 control requests without channel exhaustion',flush=True)
            alice=request(remote+'/auth/login',{'code':'alice'})[1]['token']
            bob=request(remote+'/auth/login',{'code':'bob'})[1]['token']
            def call(token,**event):return request(remote+'/functions/probe',event,token)
            result=call(alice,action='write',id='before',value='remote')
            assert result[0]==200 and result[1]['result']['side']=='remote',result
            started=ctl('start',app_id='fixture-app',accounts=['alice'])
            assert started[0]==200 and started[1]['active'],started
            lease=started[1]['lease_id']
            began=time.monotonic()
            assert ctl('start',app_id='fixture-app',accounts=['bob'])[0]!=200
            assert time.monotonic()-began<2, 'Correlated control errors must not wait for timeout'
            assert ctl('stop',lease_id='stale')[0]!=200
            status,result,headers=call(alice,action='write',id='local-write',value='persisted remotely')
            assert status==200 and result['result']['side']=='local' and result['result']['identity']=='alice',(status,result)
            assert any(k.lower()=='x-vhttpd-execution' and v=='local' for k,v in headers.items()),headers
            assert sql("SELECT JSON_UNQUOTE(JSON_EXTRACT(body,'$.side')) FROM wcf_documents WHERE collection_name='takeover_probe' AND doc_id='local-write'")=='local'
            diagnostic=request(f'http://127.0.0.1:{localadmin}/admin/runtime/relay',token='fixture-admin',admin=True)
            assert diagnostic[0]==200,diagnostic
            events=diagnostic[1]['diagnostics']['events']
            executed=[e for e in events if e['kind']=='relay.takeover.execute' and e['fields'].get('phase')=='completed']
            assert executed and executed[-1]['fields']['execution']=='local',events
            assert executed[-1]['fields']['status']=='200',executed[-1]
            linked=[e for e in events if e['kind']=='relay.database.request' and e['fields'].get('request_id')==executed[-1]['fields']['request_id']]
            assert linked, 'Database Relay events must link back to the local HTTP execution'
            for e in events:
                assert not {'sql','params','authorization','token','body'}.intersection(e['fields']),e
            assert request(f'http://127.0.0.1:{localadmin}/admin/runtime/relay')[0]==403
            result=call(bob,action='write',id='bob',value='remote',openid='alice',APPID='fixture-app')
            assert result[0]==200 and result[1]['result']['side']=='remote',result
            assert call('0'*64,action='read',id='local-write',openid='alice')[0]==401
            large={'action':'read','id':'local-write','padding':'x'*(2*1024*1024)}
            assert call(bob,**large)[0]==200, 'Non-selected accounts retain their own body limit'
            assert call(alice,**large)[0]==413, 'Selected oversize requests fail before sending'
            assert ctl('stop',lease_id=lease)[1]['active'] is False
            result=call(alice,action='read',id='local-write')
            assert result[0]==200 and result[1]['result']['side']=='remote' and result[1]['result']['data']['value']=='persisted remotely',result
            assert call(alice,**large)[0]==200, 'Inactive takeover must not limit ordinary requests'
            # Short lease expiry restores remote execution without restarting.
            assert ctl('start',app_id='fixture-app',accounts=['alice'],ttl_ms=1000)[0]==200
            time.sleep(1.1)
            assert call(alice,action='read',id='local-write')[1]['result']['side']=='remote'
            assert ctl('start',app_id='fixture-app',accounts=['alice'])[0]==200
            original_pids=[p.pid for p in processes]
            with concurrent.futures.ThreadPoolExecutor() as pool:
                pending=pool.submit(call,alice,action='write',id='lost-result',value='once',holdResponseMs=3000)
                wait(lambda:sql("SELECT COUNT(*) FROM wcf_documents WHERE collection_name='takeover_effects' AND JSON_UNQUOTE(JSON_EXTRACT(body,'$.operation'))='lost-result'")=='1',20)
                link.cut()
                failed=pending.result(timeout=15)
                assert failed[0]==502 and failed[1]['error']['code']=='DEBUG_RESULT_UNKNOWN',failed
            # While the laptop is offline, NEW requests use the remote engine.
            wait(lambda:call(alice,action='read',id='local-write')[1].get('result',{}).get('side')=='remote',10)
            link.resume()
            wait(lambda:ctl('status')[0]==200,30)
            assert ctl('status')[1]['active'] is False
            assert call(alice,action='read',id='local-write')[1]['result']['side']=='remote'
            assert sql("SELECT COUNT(*) FROM wcf_documents WHERE collection_name='takeover_effects' AND JSON_UNQUOTE(JSON_EXTRACT(body,'$.operation'))='lost-result'")=='1'
            # The old response finishes on its original lane. New requests have
            # already succeeded remotely; do not re-enable a still-busy local lane.
            wait(lambda:ctl('status')[1].get('local_in_flight')==0,10)
            # Explicitly start again on the fresh attachment; no process restart.
            restarted=ctl('start',app_id='fixture-app',accounts=['alice'])
            assert restarted[0]==200,restarted
            assert call(alice,action='read',id='local-write')[1]['result']['side']=='local'
            assert ctl('stop',lease_id=restarted[1]['lease_id'])[1]['active'] is False
            assert [p.pid for p in processes]==original_pids and all(p.poll() is None for p in processes)
            wait(lambda:request(f'http://127.0.0.1:{localadmin}/admin/runtime',token='fixture-admin',admin=True)[1]['relay']['channel_count']==0,5)
            final_diagnostics=request(f'http://127.0.0.1:{localadmin}/admin/runtime/relay',token='fixture-admin',admin=True)[1]['diagnostics']
            assert len(final_diagnostics['events'])<=256
            assert any(e['kind']=='relay.agent.disconnected' for e in final_diagnostics['events'])
            assert any(e['kind']=='relay.takeover.control' and e['fields'].get('action')=='stop' for e in final_diagnostics['events'])
            # Optional, bounded UI review against disposable fixture credentials.
            # This never reads a Desktop login ticket or a production token.
            qa_path=os.environ.get('RELAY_TAKEOVER_QA_STATE')
            if qa_path:
                pathlib.Path(qa_path).write_text(json.dumps({'url':f'http://127.0.0.1:{localadmin}/admin/ui/','ready':True}))
                deadline=time.monotonic()+300
                while time.monotonic()<deadline and pathlib.Path(qa_path).exists():
                    time.sleep(.5)
            print(json.dumps({'passed':True,'remote_http_local_vjsx_remote_mysql':True,'account_filter':True,
                'spoofed_identity_rejected':True,'explicit_end':True,'expiry':True,'disconnect_fallback':True,
                'uncertain_result_no_replay':True,'reconnect_does_not_reenable':True,'processes_unchanged':True,'control_requests':1100,'local_channels_after_completion':0,'non_selected_large_requests_unaffected':True,'diagnostics_request_database_link':True,'diagnostics_connection_history':True,'diagnostics_authenticated_and_bounded':True,'paseo_same_remote_process':bool(paseo_port)}))
        except BaseException:
            for log in logs:log.flush()
            for f in work.glob('*.log'):print(f.name,f.read_text(errors='replace')[-16000:],file=sys.stderr)
            raise
        finally:
            link.close()
            for p in processes:
                p.terminate()
                try:p.wait(timeout=10)
                except subprocess.TimeoutExpired:p.kill();p.wait()
            for log in logs:log.close()

if __name__=='__main__':run()
