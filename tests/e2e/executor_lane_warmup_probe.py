#!/usr/bin/env python3
"""Exercise real lane bootstrap under bounded, process-local scheduling delay."""
import argparse
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import threading
import time


PAUSE_SECONDS = 0.70
RUN_WINDOW_SECONDS = 0.02
MAX_PAUSES_PER_BOOTSTRAP = 3


class BootstrapPauseBudget:
    """Bound injected delay per decode, independently of its execution speed."""

    def __init__(self, limit=MAX_PAUSES_PER_BOOTSTRAP):
        self.limit = limit
        self.claimed = {}

    def claim(self, phase):
        count = self.claimed.get(phase, 0)
        if self.limit is not None and count >= self.limit:
            return False
        self.claimed[phase] = count + 1
        return True


def active_decode_phase(text):
    if text.rfind('embedded gzip decode begin') <= text.rfind('embedded gzip decode done'):
        return None
    return text.count('embedded gzip decode begin')


def pause_owned_child(pid, stop, send_signal=os.kill):
    if stop.is_set():
        return None
    started = time.monotonic()
    send_signal(pid, signal.SIGSTOP)
    try:
        stop.wait(PAUSE_SECONDS)
    finally:
        # Also resume when waiting raises or cancellation arrives mid-pause.
        send_signal(pid, signal.SIGCONT)
    return time.monotonic() - started


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--expect-timeout', action='store_true',
                        help='opt-in unbounded scheduling stress for the historical decoder control')
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[2]
    binary = Path(os.environ.get('VHTTPD_BIN', str(repo / 'vhttpd'))).resolve()
    root = Path(tempfile.mkdtemp(prefix='vhttpd-lane-warmup-'))
    process = None
    throttler = None
    stop = threading.Event()
    pauses = []
    # Unbounded stress is an explicit diagnostic mode, not the default E2E
    # workload. Otherwise small CPU scheduling differences multiply into an
    # arbitrary number of 700 ms pauses and can consume the entire lane deadline.
    budget = BootstrapPauseBudget(None if args.expect_timeout else MAX_PAUSES_PER_BOOTSTRAP)
    throttle_errors = []
    start = time.monotonic()
    try:
        with socket.socket() as listener:
            listener.bind(('127.0.0.1', 0))
            port = listener.getsockname()[1]
        # JSON quoted paths are valid TOML basic strings on the POSIX E2E hosts.
        quote = lambda path: json.dumps(str(path))
        config = f'''version = 2
[server]
pid_file = {quote(root / 'server.pid')}
[observability]
log_level = "debug"
event_log = {quote(root / 'events.ndjson')}
[listeners.ws]
protocol = "websocket"
transport = "tcp"
host = "127.0.0.1"
port = {port}
[engines.ws]
kind = "vjsx"
entry = {quote(repo / 'examples/ws-min/app.mts')}
runtime_profile = "node"
thread_count = 1
websocket_dispatch = true
[adapters.ws]
kind = "http-handler"
engine = "engine:ws"
[[pipelines]]
id = "websocket/dispatch"
ingress = "listener:ws"
match.paths = ["*"]
egress = "adapter:ws"
'''
        (root / 'config.toml').write_text(config)
        log_file = root / 'server.log'
        with log_file.open('w') as log:
            process = subprocess.Popen(
                [str(binary), '--config', str(root / 'config.toml')],
                stdout=log, stderr=subprocess.STDOUT,
                env=dict(os.environ, VHTTPD_LOG_LEVEL='debug'),
            )

            def delay_bootstrap():
                try:
                    while not stop.is_set() and process.poll() is None:
                        text = log_file.read_text(errors='replace')
                        # Delay only compiler-asset bootstrap, for every lane.
                        # Never signal an unrelated PID or change machine policy.
                        phase = active_decode_phase(text)
                        if phase is not None and budget.claim(phase):
                            duration = pause_owned_child(process.pid, stop)
                            if duration is not None:
                                pauses.append({'phase': phase, 'duration_seconds': duration})
                            stop.wait(RUN_WINDOW_SECONDS)
                        else:
                            stop.wait(0.002)
                except ProcessLookupError:
                    pass
                except Exception as error:
                    throttle_errors.append(str(error))
                    stop.set()

            throttler = threading.Thread(target=delay_bootstrap, daemon=True)
            throttler.start()
            while time.monotonic() - start < 45:
                text = log_file.read_text(errors='replace')
                if 'warmup failed' in text:
                    if args.expect_timeout and 'lane_warmup_timeout' in text:
                        print('PASS: old lane warmup timeout reproduced under scheduling delay')
                        return
                    raise AssertionError('lane warmup exceeded its phase deadline; see server log')
                if process.poll() is not None:
                    raise AssertionError(f'server exited during bootstrap: {process.returncode}')
                if throttle_errors:
                    raise AssertionError(f'delay fixture failed: {throttle_errors}')
                if 'listening on ' in text:
                    if args.expect_timeout:
                        raise AssertionError('negative control did not reproduce warmup timeout')
                    completed = text.count('warmup request done lane=')
                    if (completed < 2 or text.count('embedded gzip decode done') < 2 or
                            not all(any(pause['phase'] == phase for pause in pauses)
                                    for phase in range(1, completed + 1))):
                        raise AssertionError('fixture did not exercise both executor bootstraps')
                    print(f'PASS: {completed} executor lane warmups finish under scheduling delay')
                    print(json.dumps({'elapsed_seconds': round(time.monotonic() - start, 3),
                                      'pauses': len(pauses), 'warmups': completed,
                                      'pause_counts_by_phase': budget.claimed,
                                      'requested_pause_limit_per_phase':
                                          MAX_PAUSES_PER_BOOTSTRAP * PAUSE_SECONDS,
                                      'paused_seconds': round(sum(p['duration_seconds'] for p in pauses), 3)}))
                    return
                stop.wait(0.01)
            raise AssertionError('lane warmup probe deadline expired')
    except Exception:
        print((root / 'server.log').read_text(errors='replace') if (root / 'server.log').exists() else '')
        raise
    finally:
        stop.set()
        if throttler is not None:
            throttler.join(timeout=1)
        if process is not None:
            # Always resume our child before termination, including failures.
            try:
                os.kill(process.pid, signal.SIGCONT)
            except ProcessLookupError:
                pass
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=8)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        if os.environ.get('VHTTPD_E2E_KEEP_TMP') == '1':
            print(f'Lane warmup artifacts retained: {root}')
        else:
            shutil.rmtree(root)


if __name__ == '__main__':
    main()
