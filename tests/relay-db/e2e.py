#!/usr/bin/env python3
"""Two real vhttpd/vjsx processes, authenticated WebSocket relay and MySQL 8.
No Node runtime and no production configuration or credentials are used.
"""
import concurrent.futures
import json
import os
import pathlib
import shlex
import socket
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
from fault_link import FaultLink

ROOT = pathlib.Path(__file__).resolve().parents[2]
BINARY = pathlib.Path(os.environ.get('VHTTPD_BIN', ROOT / 'vhttpd')).resolve()
CONTAINER = os.environ.get('RELAY_DB_TEST_CONTAINER', 'vhttpd-relay-db-e2e-20261029')
DOCKER = shlex.split(os.environ.get('RELAY_DB_DOCKER_COMMAND', 'docker'))
DATABASE_HOST = os.environ.get('RELAY_DB_TEST_HOST', '127.0.0.1')
REMOTE_COMMAND = shlex.split(os.environ.get('RELAY_DB_REMOTE_COMMAND', ''))
REMOTE_BINARY = os.environ.get('RELAY_DB_REMOTE_BINARY', str(BINARY))
RELAY_HOST = os.environ.get('RELAY_DB_REMOTE_HOST', '127.0.0.1')
RELAY_LISTEN_HOST = os.environ.get('RELAY_DB_LISTEN_HOST', '127.0.0.1')

def port():
    with socket.socket() as s:
        s.bind(('127.0.0.1', 0))
        return s.getsockname()[1]

def sql(statement):
    result = subprocess.run(DOCKER + ['exec', '-e', 'MYSQL_PWD=relay-fixture-only', CONTAINER,
                             'mysql', '-h127.0.0.1', '-uroot', '-Drelay_test', '-N', '-e', statement],
                            text=True, capture_output=True, check=True)
    return result.stdout.strip()

def request(url, payload=None):
    req = urllib.request.Request(url, data=None if payload is None else json.dumps(payload).encode(),
                                 headers={'Content-Type': 'application/json'})
    try:
        with urllib.request.urlopen(req, timeout=12) as response:
            return response.status, json.load(response)
    except urllib.error.HTTPError as error:
        return error.code, json.loads(error.read())

def wait(predicate, timeout=60):
    end = time.monotonic() + timeout
    while time.monotonic() < end:
        try:
            if predicate():
                return
        except (OSError, ValueError, subprocess.CalledProcessError):
            pass
        time.sleep(.1)
    raise AssertionError('readiness timeout')

def run():
    database_port = int(subprocess.check_output(DOCKER + ['port', CONTAINER, '3306/tcp'], text=True).strip().rsplit(':', 1)[1])
    wait(lambda: sql('SELECT 1') == '1', timeout=180)
    sql('DROP TABLE IF EXISTS wcf_documents')
    sql((ROOT / 'examples/wechat-cloud-functions/schema-cloud-mysql.sql').read_text())
    sql('CREATE TABLE IF NOT EXISTS relay_effects (id INT PRIMARY KEY, n INT NOT NULL); REPLACE INTO relay_effects VALUES (1,0)')
    sql("INSERT INTO wcf_documents VALUES ('relay-fixture','relay-fixture','relay_probe','seed',JSON_OBJECT('_id','seed','value','remote-only'))")
    with tempfile.TemporaryDirectory(prefix='vhttpd-relay-db-', dir=os.environ.get('RELAY_DB_WORK_ROOT')) as tmp:
        work = pathlib.Path(tmp)
        hub_port, local_port, admin_hub, admin_local = port(), port(), port(), port()
        remote = work / 'remote.toml'
        local = work / 'local.toml'
        remote.write_text(f'''version=2
[server]
pid_file="{work}/remote.pid"
[observability]
event_log="{work}/remote.events"
[listeners.relay]
protocol="websocket"
transport="tcp"
host="{RELAY_LISTEN_HOST}"
port={hub_port}
[listeners.admin]
protocol="http"
transport="tcp"
host="127.0.0.1"
port={admin_hub}
[control]
listener="listener:admin"
token="relay-fixture-admin"
[resources.db.test]
kind="mysql"
host="{DATABASE_HOST}"
port={database_port}
database="relay_test"
username="relay_test"
password="relay-test-only"
pool_size=2
init_sql=["SET SESSION TRANSACTION ISOLATION LEVEL REPEATABLE READ", "CREATE TABLE relay_export_must_not_initialize (id INT)"]
[relays.database]
mode="hub"
carrier="websocket"
listener="listener:relay"
path="/relay"
node_id="fixture-hub"
token="fixture-relay-secret"
[adapters.database]
kind="db-resource"
options.resource="db/test"
options.access="read-write"
[[pipelines]]
id="resource/database"
ingress="relay:database"
egress="adapter:database"
''')
        link = FaultLink(RELAY_HOST, hub_port)
        local.write_text(f'''version=2
[server]
pid_file="{work}/local.pid"
[observability]
event_log="{work}/local.events"
[listeners.web]
protocol="http"
transport="tcp"
host="127.0.0.1"
port={local_port}
[listeners.admin]
protocol="http"
transport="tcp"
host="127.0.0.1"
port={admin_local}
[control]
listener="listener:admin"
token="relay-fixture-admin"
[resources.db.test]
kind="mysql"
options.relay="relay:database"
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
[engines.app]
kind="vjsx"
entry="{ROOT}/tests/relay-db/app.mts"
module_root="{ROOT}/tests/relay-db"
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
''')
        assert 'password' not in local.read_text() and 'username' not in local.read_text()
        processes = []
        logs = []
        def start(config, name):
            log = (work / (name + '.log')).open('ab')
            logs.append(log)
            command = REMOTE_COMMAND + [REMOTE_BINARY] if config == remote else [str(BINARY)]
            proc = subprocess.Popen(command + ['--config', str(config)], cwd=ROOT, stdout=log, stderr=log)
            processes.append(proc)
            return proc
        def stop(proc):
            proc.terminate()
            try: proc.wait(timeout=8)
            except subprocess.TimeoutExpired: proc.kill(); proc.wait()
        def registrations():
            count = 0
            for line in (work / 'local.events').read_text().splitlines():
                try: event = json.loads(line)
                except ValueError: continue
                if event.get('type') == 'relay.agent.handshake' and 'agent_handshake.registered' in line:
                    count += 1
            return count
        def raw(operation, session='', statement=''):
            return request(url + '/raw-database', {'op': operation, 'session_id': session, 'sql': statement})
        def insert_document(identifier):
            return "INSERT INTO wcf_documents VALUES ('relay-fixture','relay-fixture','relay_probe','" + identifier + "',JSON_OBJECT('_id','" + identifier + "'))"
        def reconnect(previous):
            link.resume()
            wait(lambda: registrations() > previous)
            # The FIRST database request after registration must work. Do not
            # hide a retired-backend error by retrying this request in wait().
            status, body = request(url, {'id': 'seed'})
            assert status == 200 and body['data']['value'] == 'remote-only', (status, body)
        try:
            hub = start(remote, 'remote')
            agent = start(local, 'local')
            url = f'http://127.0.0.1:{local_port}'
            wait(lambda: request(url + '/fixture-ready')[0] == 200)
            wait(lambda: registrations() > 0)
            status, body = request(url, {'id': 'seed'})
            assert status == 200 and body['data']['value'] == 'remote-only', (status, body)
            print('PASS unchanged cloud.database() reads remote MySQL through Relay', flush=True)
            status, body = request(url, {'action': 'write', 'id': 'written', 'value': 'via-relay'})
            assert status == 200 and body['value'] == 'via-relay', (status, body)
            assert sql("SELECT JSON_UNQUOTE(JSON_EXTRACT(body,'$.value')) FROM wcf_documents WHERE doc_id='written'") == 'via-relay'
            print('PASS cloud.database() writes persist in remote MySQL', flush=True)
            status, body = request(url, {'action': 'transaction', 'id': 'committed', 'value': 42})
            assert status == 200 and body['committed'], (status, body)
            assert sql("SELECT COUNT(*) FROM wcf_documents WHERE doc_id IN ('committed','committed-second')") == '2'
            status, body = request(url, {'action': 'rollback', 'id': 'rolled-back', 'value': 42})
            assert status == 500, (status, body)
            assert sql("SELECT COUNT(*) FROM wcf_documents WHERE doc_id='rolled-back'") == '0'
            print('PASS transaction commit and rollback use remote connection leases', flush=True)
            assert sql('SELECT @@GLOBAL.transaction_isolation') == 'READ-COMMITTED'
            assert sql("SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='relay_test' AND table_name='relay_export_must_not_initialize'") == '0'
            print('PASS Relay preserves required session isolation without running schema initialization', flush=True)
            status, body = request(url + '/orphan-begin', {})
            assert status == 200 and body['ok'], (status, body)
            wait(lambda: int(sql('SELECT COUNT(*) FROM information_schema.innodb_trx')) > 0, timeout=1)
            assert sql("SELECT COUNT(*) FROM wcf_documents WHERE doc_id IN ('expired','expired-second')") == '0'
            wait(lambda: sql('SELECT COUNT(*) FROM information_schema.innodb_trx') == '0', timeout=5)
            print('PASS idle transaction deadline rolls back and releases remote lease', flush=True)
            with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
                results = list(pool.map(lambda _: request(url, {'id': 'seed'}), range(8)))
            assert all(status == 200 for status, _ in results), results
            print('PASS concurrent requests have correlated Relay responses', flush=True)
            local_pid = agent.pid
            previous = registrations()
            link.cut()
            assert request(url, {'id': 'seed'})[0] == 500
            reconnect(previous)
            assert agent.pid == local_pid and agent.poll() is None
            print('PASS first request after Relay reconnect succeeds without local restart', flush=True)

            status, old = raw('begin')
            assert status == 200 and old['session_id'].endswith(':1'), (status, old)
            assert raw('execute', old['session_id'], insert_document('old-generation'))[0] == 200
            previous = registrations()
            link.cut()
            wait(lambda: sql('SELECT COUNT(*) FROM information_schema.innodb_trx') == '0', timeout=8)
            assert sql("SELECT COUNT(*) FROM wcf_documents WHERE doc_id='old-generation'") == '0'
            reconnect(previous)
            status, new = raw('begin')
            assert status == 200 and new['session_id'].endswith(':1'), (status, new)
            assert old['session_id'] != new['session_id']
            for operation in ['execute', 'commit', 'rollback']:
                status, body = raw(operation, old['session_id'], insert_document('stale-write') if operation == 'execute' else '')
                assert status == 500 and 'relay_db_transaction_connection_lost' in body['error'], (status, body)
            assert raw('execute', new['session_id'], insert_document('new-generation'))[0] == 200
            assert raw('commit', new['session_id'])[0] == 200
            assert sql("SELECT COUNT(*) FROM wcf_documents WHERE doc_id='new-generation'") == '1'
            assert sql("SELECT COUNT(*) FROM wcf_documents WHERE doc_id IN ('old-generation','stale-write')") == '0'
            status, body = request(url, {'action': 'transaction', 'id': 'recovered-cloud', 'value': 8})
            assert status == 200 and body['committed'], (status, body)
            print('PASS old transaction fails safely even when new transaction reuses remote ID 1', flush=True)

            # Let MySQL COMMIT an increment, then lose its response on the wire.
            # Recovery must not replay that effect, even though its caller failed.
            previous = registrations()
            link.hold_responses.set()
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
                pending = executor.submit(request, url + '/effect', {})
                wait(lambda: sql('SELECT n FROM relay_effects WHERE id=1') == '1', timeout=5)
                link.cut()
                assert pending.result(timeout=12)[0] == 500
            reconnect(previous)
            assert sql('SELECT n FROM relay_effects WHERE id=1') == '1'
            assert agent.pid == local_pid and agent.poll() is None
            print('PASS committed SQL with lost response is not replayed after recovery', flush=True)
            # Kill only our fixture agent after a real transaction has begun.
            # The remote gateway must release its pinned connection and roll back.
            wait(lambda: sql('SELECT COUNT(*) FROM information_schema.innodb_trx') == '0', timeout=5)
            with concurrent.futures.ThreadPoolExecutor(max_workers=1) as executor:
                pending = executor.submit(request, url, {'action': 'hold', 'id': 'disconnected', 'value': 9})
                wait(lambda: int(sql('SELECT COUNT(*) FROM information_schema.innodb_trx')) > 0, timeout=5)
                agent.kill()
                agent.wait(timeout=5)
                # SIGKILL cannot run the fixture process's PID-file cleanup.
                (work / 'local.pid').unlink(missing_ok=True)
                try:
                    status, _ = pending.result(timeout=12)
                    assert status >= 400
                except (OSError, ValueError):
                    pass
            wait(lambda: sql('SELECT COUNT(*) FROM information_schema.innodb_trx') == '0', timeout=8)
            assert sql("SELECT COUNT(*) FROM wcf_documents WHERE doc_id IN ('disconnected','disconnected-second')") == '0'
            print('PASS carrier disconnect rolls back remote transaction and releases lease', flush=True)
            remote.write_text(remote.read_text().replace('options.access="read-write"', 'options.access="read-only"'))
            stop(hub)
            hub = start(remote, 'remote-readonly')
            agent = start(local, 'local-readonly')
            wait(lambda: request(url + '/fixture-ready')[0] == 200)
            time.sleep(.5)
            wait(lambda: request(url, {'id': 'seed'})[0] == 200)
            assert request(url, {'action': 'write', 'id': 'denied', 'value': 1})[0] == 500
            assert sql("SELECT COUNT(*) FROM wcf_documents WHERE doc_id='denied'") == '0'
            assert request(url + '/query-write', {})[0] == 500
            assert sql("SELECT COUNT(*) FROM wcf_documents WHERE doc_id='query-write'") == '0'
            print('PASS read-only enforced by MySQL, including writes disguised as query()', flush=True)
            print('Relay MySQL E2E passed', flush=True)
        except BaseException:
            for f in work.glob('*.log'):
                print(f.name + ':\n' + f.read_text()[-7000:])
            raise
        finally:
            link.close()
            for proc in reversed(processes):
                if proc.poll() is None: stop(proc)
            for log in logs: log.close()

if __name__ == '__main__':
    run()
