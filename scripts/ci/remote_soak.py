#!/usr/bin/env python3
"""Bounded, isolated Linux HTTP/Paseo soak; requires adjacent test assets.

Run inside a systemd cgroup with MemoryMax/CPUQuota. Never targets an existing
application or database. A completed run is evidence, not proof of no leaks.
"""
import argparse
import concurrent.futures
import hashlib
import http.client
import json
import os
from pathlib import Path
import signal
import shutil
import socket
import subprocess
import threading
import time
import traceback

from ws_client import verify_paseo


def save(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def port():
    with socket.socket() as sock:
        sock.bind(('127.0.0.1', 0))
        return sock.getsockname()[1]


def process(pid):
    root = Path('/proc') / str(pid)
    result = {}
    for line in (root / 'status').read_text().splitlines():
        key, _, value = line.partition(':')
        if key in ('VmRSS', 'VmHWM', 'RssAnon', 'Threads', 'VmSwap'):
            result[key] = int(value.split()[0])
    result['fd_count'] = len(list((root / 'fd').iterdir()))
    fields = (root / 'stat').read_text().rpartition(') ')[2].split()
    result['cpu_ticks'] = int(fields[11]) + int(fields[12])
    result['start_ticks'] = int(fields[19])
    return result


def available_kib():
    for line in Path('/proc/meminfo').read_text().splitlines():
        if line.startswith('MemAvailable:'):
            return int(line.split()[1])
    raise RuntimeError('MemAvailable missing')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--duration', type=int, default=87600)
    parser.add_argument('--observe-pid', type=int)
    parser.add_argument('--workload', choices=('mixed', 'http', 'paseo'), default='mixed')
    parser.add_argument('--http-variant', choices=('json', 'small', 'native'), default='json')
    parser.add_argument('--signature-mode', choices=('isolated', 'churn'), default='isolated')
    args = parser.parse_args()
    if args.duration < 30:
        parser.error('duration must be at least 30 seconds')
    root = Path(__file__).resolve().parent
    os.chdir(root)
    if (root / 'state.json').exists():
        raise RuntimeError('Use a fresh directory for each run')
    info = json.loads(subprocess.check_output([str(args.binary), '--build-info'], text=True, timeout=15))
    if info.get('gc') != 'boehm' or info.get('gc_enabled') is not True:
        raise RuntimeError('Actual runtime must have Boehm GC enabled')
    http_port, ws_port = port(), port()
    while ws_port == http_port:
        ws_port = port()
    component = (root / 'paseo-component.toml').read_text().replace('port = 19901', f'port = {ws_port}')
    component = component.replace('entry = "./app.mts"', 'entry = "./paseo.mts"')
    if args.signature_mode == 'isolated':
        component = component.replace('signature_root = "."', 'signature_root = "."\nsignature_include = ["paseo.mts"]')
    (root / 'paseo.toml').write_text(component)
    (root / 'http.mjs').write_text('''export default function(ctx) {
      const payload = Array.from({length:64}, (_,i)=>({i,text:"x".repeat(96)}));
      return ctx.json({ok:true,path:ctx.path,payload},ctx.path==="/expected-error"?503:200);
    };\n''')
    if args.http_variant == 'small':
        (root / 'http.mjs').write_text('export default c=>c.json({ok:true},c.path==="/expected-error"?503:200);\n')
    config = f'''version=2
include={json.dumps(['paseo.toml'] if args.workload != 'http' else [])}
[server]
pid_file="{root}/runtime.pid"
[observability]
log_level="error"
[listeners.http]
protocol="http"
host="127.0.0.1"
port={http_port}
[engines.http]
kind="vjsx"
entry="http.mjs"
runtime_profile="script"
thread_count=2
{('signature_include=["http.mjs"]' if args.signature_mode == 'isolated' else '')}
[adapters.http]
kind="http-handler"
engine="engine:http"
[[pipelines]]
id="soak.http"
ingress="listener:http"
match.paths=["*"]
egress="adapter:http"
'''
    if args.workload == 'paseo':
        config = config.split('[listeners.http]')[0]
    elif args.http_variant == 'native':
        config = config.split('[engines.http]')[0] + '''[adapters.http]
kind="fixed-response"
options.status="200"
options.body='{"ok":true}'
[[pipelines]]
id="soak.http"
ingress="listener:http"
match.paths=["*"]
egress="adapter:http"
'''
    (root / 'vhttpd.toml').write_text(config)
    state = {'status': 'starting', 'started_utc': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
             'duration_seconds': args.duration, 'build_info': info,
             'binary': str(args.binary), 'binary_sha256': hashlib.sha256(args.binary.read_bytes()).hexdigest(),
             'scope': 'isolated HTTP JSON and Paseo reconnect/text/binary; no DB/providers/production traffic',
             'workload': args.workload,
             'http_variant': args.http_variant,
             'signature_mode': args.signature_mode,
             'http_target_rps': 0 if args.workload == 'paseo' else 40,
             'http_concurrency': 0 if args.workload == 'paseo' else 4,
             'paseo_cycle_interval_seconds': None if args.workload == 'http' else 2,
             'sample_seconds': 10, 'host_available_min_kib': 256*1024,
             'cgroup_required_memory_max_bytes': 512*1024*1024,
             'http_port': http_port, 'ws_port': ws_port, 'observed_pid': args.observe_pid,
             'http_ok': 0, 'http_errors': 0, 'paseo_ok': 0, 'paseo_errors': 0,
             'latency_buckets_ms': {'10': 0, '50': 0, '100': 0, '500': 0, '1000': 0, 'over1000': 0},
             'max_latency_ms': 0, 'recent_errors': [], 'samples': 0}
    state['log_rotation_count'] = 0
    cg = Path('/sys/fs/cgroup') / Path('/proc/self/cgroup').read_text().strip().split('::', 1)[1].lstrip('/')
    state['cgroup'] = str(cg)
    if (cg / 'memory.max').read_text().strip() != str(512*1024*1024):
        raise RuntimeError('Run in a cgroup with MemoryMax=512M')
    save(root / 'state.json', state)
    stop = threading.Event()
    lock = threading.Lock()
    interrupted = []
    def interrupt(signum, frame):
        interrupted.append(signum)
        stop.set()
    signal.signal(signal.SIGTERM, interrupt)
    signal.signal(signal.SIGINT, interrupt)
    def error(kind, exc):
        with lock:
            state[kind + '_errors'] += 1
            state['recent_errors'] = (state['recent_errors'] + [str(exc)[:400]])[-10:]
    def http_worker(number):
        seq = 0
        while not stop.is_set():
            started = time.monotonic()
            conn = http.client.HTTPConnection('127.0.0.1', http_port, timeout=5)
            try:
                seq += 1
                path = '/expected-error' if seq % 20 == 0 and args.http_variant != 'native' else '/json'
                method = 'POST' if seq % 4 == 0 else 'GET'
                conn.request(method, path, body='x'*4096 if method == 'POST' else None)
                response = conn.getresponse()
                body = response.read(65537)
                expected = 503 if path == '/expected-error' else 200
                if response.status != expected or len(body) > 65536 or not json.loads(body)['ok']:
                    raise RuntimeError(f'HTTP response mismatch: {response.status}, {len(body)} bytes')
                elapsed = (time.monotonic()-started)*1000
                with lock:
                    state['http_ok'] += 1
                    state['max_latency_ms'] = max(state['max_latency_ms'], round(elapsed, 3))
                    key = next((str(b) for b in (10,50,100,500,1000) if elapsed <= b), 'over1000')
                    state['latency_buckets_ms'][key] += 1
            except Exception as exc:
                error('http', exc)
            finally:
                conn.close()
            # One fresh connection per request exercises accept/close cleanup.
            stop.wait(max(0, 0.1-(time.monotonic()-started)))
    def websocket_worker():
        while not stop.is_set():
            try:
                verify_paseo('127.0.0.1', ws_port)
                with lock:
                    state['paseo_ok'] += 1
            except Exception as exc:
                error('paseo', exc)
            stop.wait(2)
    warm = min(600, args.duration//6)
    cool = min(600, args.duration//6)
    state['baseline_seconds'] = warm
    state['cooldown_seconds'] = cool
    state['load_duration_seconds'] = args.duration-warm-cool
    pool = concurrent.futures.ThreadPoolExecutor(max_workers=5)
    runtime = None
    failure = None
    samples = []
    rss_baseline = None
    diagnostic_mark = 0
    start = time.monotonic()
    observed_start = process(args.observe_pid)['start_ticks'] if args.observe_pid else None
    try:
        with (root / 'runtime.log').open('ab') as log:
            runtime = subprocess.Popen([str(args.binary), '--config', str(root/'vhttpd.toml'), '--manual-restart'],
                                       stdout=log, stderr=log, start_new_session=True)
            state['runtime_pid'] = runtime.pid
            deadline = time.monotonic()+60
            while True:
                if runtime.poll() is not None:
                    raise RuntimeError(f'Runtime exited during startup: {runtime.returncode}')
                conn = http.client.HTTPConnection('127.0.0.1', http_port, timeout=1)
                try:
                    if args.workload != 'paseo':
                        conn.request('GET','/ready'); response=conn.getresponse()
                        assert response.status == 200
                        response.read()
                    if args.workload != 'http':
                        verify_paseo('127.0.0.1', ws_port)
                    break
                except Exception:
                    if time.monotonic() >= deadline:
                        raise
                    time.sleep(.2)
                finally:
                    conn.close()
            start = time.monotonic()
            futures = []
            low_memory = 0
            with (root / 'samples.ndjson').open('w', buffering=1) as output:
                while time.monotonic()-start < args.duration and not interrupted:
                    elapsed = time.monotonic()-start
                    if runtime.poll() is not None:
                        raise RuntimeError(f'Runtime exited: {runtime.returncode}')
                    phase = 'baseline' if elapsed < warm else ('cooldown' if elapsed >= args.duration-cool else 'load')
                    if phase == 'load' and not futures:
                        if args.workload != 'paseo':
                            futures.extend(pool.submit(http_worker,i) for i in range(4))
                        if args.workload != 'http':
                            futures.append(pool.submit(websocket_worker))
                    if phase == 'cooldown':
                        stop.set()
                    available = available_kib()
                    low_memory = low_memory+1 if available < 256*1024 else 0
                    if low_memory >= 3:
                        raise RuntimeError('Host MemAvailable below 256 MiB for three samples; test stopped')
                    sample = {'elapsed_seconds': round(elapsed,2), 'phase': phase,
                              'runtime': process(runtime.pid), 'host_available_kib': available,
                              'cgroup_memory_bytes': int((cg/'memory.current').read_text()),
                              'cgroup_memory_events': (cg/'memory.events').read_text().strip()}
                    if args.observe_pid:
                        sample['existing_runtime'] = process(args.observe_pid)
                        if sample['existing_runtime']['start_ticks'] != observed_start:
                            raise RuntimeError('Existing runtime PID changed identity; test stopped')
                    with lock:
                        for key in ('http_ok','http_errors','paseo_ok','paseo_errors'):
                            sample[key] = state[key]
                        state.update(status='running',phase=phase,elapsed_seconds=round(elapsed,2),samples=state['samples']+1)
                        save(root/'state.json', state)
                    output.write(json.dumps(sample)+'\n')
                    # Capture growth from the first load sample. Waiting ten
                    # more minutes loses evidence if an early OOM occurs.
                    if phase == 'load' and rss_baseline is None:
                        rss_baseline = sample['runtime']['VmRSS']
                    growth = sample['runtime']['VmRSS'] - (rss_baseline or sample['runtime']['VmRSS'])
                    mark = max(0, growth // (64*1024))
                    # Preserve mapping/anonymous memory evidence on each 64 MiB
                    # increase. Growth is a diagnostic trigger, not a leak claim.
                    if mark > diagnostic_mark:
                        diagnostic_mark = mark
                        for name in ('status','smaps_rollup','maps'):
                            try:
                                (root/f'growth-{mark}-{name}.txt').write_text((Path('/proc')/str(runtime.pid)/name).read_text())
                            except OSError:
                                pass
                        with lock:
                            state['rss_growth_diagnostic_kib'] = growth
                    samples.append(sample)
                    if len(samples)>3:
                        samples.pop(0)
                    if any(f.done() for f in futures) and phase == 'load':
                        raise RuntimeError('Load worker exited unexpectedly')
                    if (root/'runtime.log').stat().st_size > 8*1024*1024:
                        # Some bundled websocket libraries emit their own debug
                        # log. Bound disk use while keeping the latest interval.
                        shutil.copyfile(root/'runtime.log',root/'runtime.previous.log')
                        with (root/'runtime.log').open('r+b') as current:
                            current.truncate(0)
                        with lock:
                            state['log_rotation_count'] += 1
                    time.sleep(min(10,max(0,args.duration-(time.monotonic()-start))))
    except BaseException as exc:
        failure = f'{type(exc).__name__}: {exc}'
        (root/'exception.txt').write_text(traceback.format_exc())
    finally:
        stop.set()
        pool.shutdown(wait=True)
        if runtime and runtime.poll() is None:
            for name in ('status','smaps_rollup','maps'):
                try:
                    (root/('final-'+name+'.txt')).write_text((Path('/proc')/str(runtime.pid)/name).read_text())
                except OSError:
                    pass
            os.killpg(runtime.pid,signal.SIGTERM)
            try:
                runtime.wait(timeout=15)
            except subprocess.TimeoutExpired:
                os.killpg(runtime.pid,signal.SIGKILL)
                runtime.wait()
                failure = failure or 'Runtime did not stop within 15 seconds'
        state.update(status='failed' if failure or interrupted else 'completed',failure=failure,
                     interrupted_signals=interrupted,elapsed_seconds=round(time.monotonic()-start,2),
                     ended_utc=time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),last_samples=samples)
        no_http = args.workload != 'paseo' and not state['http_ok']
        no_paseo = args.workload != 'http' and not state['paseo_ok']
        if state['http_errors'] or state['paseo_errors'] or no_http or no_paseo:
            state['status']='failed'
            state['failure']=failure or 'Workload errors or no successful traffic; inspect counters'
        save(root/'state.json',state)
        save(root/'result.json',state)
    return 0 if state['status']=='completed' else 1


if __name__ == '__main__':
    raise SystemExit(main())
