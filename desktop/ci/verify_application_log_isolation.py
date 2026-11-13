#!/usr/bin/env python3
"""Exercise real Bodytest HTTP code and Paseo v2 concurrently in one vhttpd.
No production credentials, database writes, external login, or Node process.
"""
import argparse
import concurrent.futures
import importlib.util
import json
import os
from pathlib import Path
import shutil
import socket
import subprocess
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parents[2]
HTTP = urllib.request.build_opener(urllib.request.ProxyHandler({}))
spec = importlib.util.spec_from_file_location('log_isolation_ws', ROOT/'tests/multi-app-paseo/ws_client.py')
ws = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ws)


def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]


def request(number, path, *, method='GET', body=None, identity='', token='application-log-fixture'):
    headers = {'x-vhttpd-admin-token': token}
    if identity:
        headers['x-request-id'] = identity
    req = urllib.request.Request(f'http://127.0.0.1:{number}{path}', data=body, method=method, headers=headers)
    try:
        with HTTP.open(req, timeout=10) as response:
            payload=response.read().decode()
            try: data=json.loads(payload)
            except ValueError: data=payload
            return response.status,data
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode()


def wait(fn, seconds=90):
    end = time.monotonic()+seconds
    last = None
    while time.monotonic()<end:
        try:
            value = fn()
            if value:
                return value
        except (OSError, ValueError, AssertionError) as error:
            last = error
        time.sleep(.1)
    raise AssertionError(f'Runtime did not reach expected state: {last}')


def run(binary, bodytest, work, hold_seconds=0):
    work.mkdir(parents=True, exist_ok=False)
    # Only application source is copied. Never copy the project's private runtime.
    (work/'server').mkdir()
    shutil.copy2(bodytest/'server/application.mjs', work/'server/application.mjs')
    shutil.copytree(bodytest/'server/lib', work/'server/lib', ignore=shutil.ignore_patterns('*.md','*.mdx','node_modules','__pycache__'))
    shutil.copytree(bodytest/'cloudfunctions', work/'cloudfunctions', ignore=shutil.ignore_patterns('*.md','*.mdx','node_modules','.runtime'))
    (work/'bodytest.mts').write_text('''import {createBodytestApplication} from './server/application.mjs';
const application = createBodytestApplication({WECHAT_APP_ID:'wx-log-fixture',WECHAT_APP_SECRET:'fixture-only',WECHAT_DB_DRIVER:'mysql'});
console.info('BODYTEST_BOOT');
export default async function(ctx) {
  ctx.runtime.log('BODYTEST_REQUEST', ctx.path);
  if (ctx.path === '/__logs/ready') return ctx.json({ok:true});
  if (ctx.path === '/__logs/error') { throw new Error('BODYTEST_EXPECTED_ERROR'); }
  if (ctx.path === '/__logs/async') {
    await new Promise(resolve => setTimeout(resolve,30));
    console.warn('BODYTEST_ASYNC_CONSOLE');
    ctx.runtime.warn('BODYTEST_ASYNC_REQUEST');
    return ctx.json({ok:true});
  }
  if (ctx.path === '/__logs/sentinel') {ctx.runtime.log('BODYTEST_SENTINEL');return ctx.json({ok:true});}
  return application(ctx);
}
''')
    (work/'paseo').mkdir()
    shutil.copy2(ROOT/'examples/paseo-relay/app.mts', work/'paseo/app.mts')
    web, paseo, admin = port(), port(), port()
    component = (ROOT/'examples/paseo-relay/component.toml').read_text().replace('port = 19901',f'port = {paseo}')
    (work/'paseo/component.toml').write_text(component)
    (work/'admin').mkdir()
    (work/'admin/ui').symlink_to(ROOT/'admin/ui',target_is_directory=True)
    config = work/'vhttpd.toml'
    config.write_text(f'''version=2
include=["paseo/component.toml"]
[server]
pid_file="runtime.pid"
[observability]
event_log="events.ndjson"
[listeners.web]
protocol="http"
host="127.0.0.1"
port={web}
[listeners.admin]
protocol="http"
host="127.0.0.1"
port={admin}
[control]
listener="listener:admin"
token="application-log-fixture"
[engines.wechat]
kind="vjsx"
entry="bodytest.mts"
module_root="."
thread_count=2
runtime_profile="node"
[adapters.wechat]
kind="http-handler"
engine="engine:wechat"
[[pipelines]]
id="wechat.http"
group="wechat"
ingress="listener:web"
match.paths=["*"]
egress="adapter:wechat"
''')
    with (work/'runtime.log').open('wb') as log:
        env=os.environ.copy()
        env['VHTTPD_LOG_LEVEL']=os.environ.get('APPLICATION_LOG_TEST_LEVEL','warn')
        process=subprocess.Popen([str(binary),'--config',str(config)],cwd=work,stdout=log,stderr=log,env=env)
        try:
            wait(lambda: request(web,'/__logs/ready')[0]==200)
            wait(lambda: request(paseo,'/meta')[1].get('app')=='paseo-relay')
            assert request(admin,'/admin/logs?application=wechat',token='incorrect')[0]==403
            def body_requests():
                for i in range(30):
                    assert request(web,'/__logs/ready',identity=f'BODYTEST-{i}')[0]==200
                # Runs actual Bodytest's family endpoint authentication, without touching DB.
                assert request(web,'/functions/familyRecords',method='POST',body=b'{}')[0]==401
                assert request(web,'/__logs/async',identity='BODYTEST-ASYNC')[0]==200
                assert request(web,'/__logs/error',identity='BODYTEST-ERROR')[0]>=500
            def paseo_requests():
                for _ in range(3):
                    result=ws.verify_paseo('127.0.0.1',paseo)
                    assert result['bidirectional_text'] and result['bidirectional_binary']
                    time.sleep(.1)
            with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
                tasks=[pool.submit(body_requests),pool.submit(paseo_requests)]
                for task in tasks: task.result()
            def logs(app):
                status,data=request(admin,f'/admin/logs?application={app}&limit=1000')
                assert status==200 and data['version']==1
                assert all(record['app_id']==app for record in data['records'])
                return data
            body=logs('wechat')
            relay=logs('paseo')
            body_text=json.dumps(body['records'])
            relay_text=json.dumps(relay['records'])
            for marker in ['BODYTEST_BOOT','BODYTEST_ASYNC_CONSOLE','BODYTEST_ASYNC_REQUEST','BODYTEST_EXPECTED_ERROR']:
                assert marker in body_text,marker
                assert marker not in relay_text,marker
            assert '[paseo-relay]' in relay_text and '[paseo-relay]' not in body_text
            assert any(r['request_id']=='BODYTEST-ASYNC' and 'BODYTEST_ASYNC_REQUEST' in r['message'] for r in body['records'])
            assert all(not r['request_id'] for r in body['records'] if 'BODYTEST_ASYNC_CONSOLE' in r['message'])
            assert request(web,'/__logs/sentinel')[0]==200
            # More than one application's retention capacity must not evict another's records.
            for i in range(140):
                connection=ws.WebSocket('127.0.0.1',paseo,f'/ws?serverId=log-flood-{i}&role=server&v=2')
                assert connection.json()['type']=='sync'
                connection.close()
                wait(lambda: request(admin,'/admin/runtime/websocket-listeners')[1]['active_connections']==0)
            wait(lambda: request(admin,'/admin/runtime/websocket-listeners')[1]['active_connections']==0)
            body=logs('wechat');relay=logs('paseo')
            assert any('BODYTEST_SENTINEL' in r['message'] for r in body['records'])
            assert relay['dropped']>0 and len(relay['records'])<=256
            assert all('BODYTEST_' not in r['message'] for r in relay['records'])
            assert all('[paseo-relay]' not in r['message'] for r in body['records'])
            # The writer separates files using native app identity, not text.
            for app, batch, forbidden in [('wechat',body,'[paseo-relay]'),('paseo',relay,'BODYTEST_')]:
                path=Path(batch['file'])
                assert path.parent==work/'application-logs' and path.name==f'app-{app}.ndjson'
                assert not batch['storage_error'] and batch['max_file_bytes']==4*1024*1024
                disk=[json.loads(line) for line in path.read_text().splitlines()]
                assert disk and all(row['app_id']==app and forbidden not in row['message'] for row in disk)
                assert path.stat().st_size<=batch['max_file_bytes']
            # Restart the same environment and recover isolated history from disk.
            process.terminate()
            process.wait(timeout=15)
            process=subprocess.Popen([str(binary),'--config',str(config)],cwd=work,stdout=log,stderr=log,env=env)
            wait(lambda: request(web,'/__logs/ready')[0]==200)
            wait(lambda: request(paseo,'/meta')[1].get('app')=='paseo-relay')
            body=logs('wechat');relay=logs('paseo')
            assert any('BODYTEST_SENTINEL' in row['message'] for row in body['records'])
            assert all('BODYTEST_' not in row['message'] for row in relay['records'])
            assert all('[paseo-relay]' not in row['message'] for row in body['records'])
            result={'passed':True,'single_process':True,'bodytest':'real application source: family auth rejection, async output, intentional handler error',
                    'paseo':'real v2 relay: concurrent control/data, text/binary, close/reconnect, 140 connection cycles',
                    'authenticated':True,'cross_application_leaks':0,'wechat_records':len(body['records']),
                    'paseo_records':len(relay['records']),'paseo_dropped':relay['dropped'],'wechat_sentinel_preserved':True,
                    'separate_files':True,'restart_history_preserved':True,
                    'ports':{'wechat':web,'paseo':paseo,'admin':admin}}
            apps=request(admin,'/admin/apps')[1]['apps']
            snapshot={'known':True,'checked_at':'真实联调结果快照','applications':apps,'application_logs':{'wechat':body,'paseo':relay},'websocket_known':True,'websocket_connections':0,'websocket_rooms':0}
            (work/'desktop-workspace.json').write_text(json.dumps(snapshot,ensure_ascii=False,indent=2)+'\n')
            (work/'result.json').write_text(json.dumps(result,indent=2)+'\n')
            print(json.dumps(result),flush=True)
            if hold_seconds: time.sleep(hold_seconds)
        except BaseException:
            for name,path in [('body','/admin/logs?application=wechat&limit=1000'),('paseo','/admin/logs?application=paseo&limit=1000'),('runtime','/admin/runtime')]:
                try: (work/(name+'-failure.json')).write_text(json.dumps(request(admin,path)[1],indent=2))
                except Exception: pass
            raise
        finally:
            process.terminate()
            try: process.wait(timeout=15)
            except subprocess.TimeoutExpired:
                process.kill();process.wait()


if __name__=='__main__':
    parser=argparse.ArgumentParser()
    parser.add_argument('--binary',required=True,type=Path)
    parser.add_argument('--bodytest-root',required=True,type=Path)
    parser.add_argument('--work',required=True,type=Path)
    parser.add_argument('--hold-seconds',type=int,default=0)
    args=parser.parse_args()
    run(args.binary.resolve(),args.bodytest_root.resolve(),args.work.resolve(),args.hold_seconds)
