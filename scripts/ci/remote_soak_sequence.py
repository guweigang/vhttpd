#!/usr/bin/env python3
"""Validate a fixed runtime before starting a fresh, bounded 24-hour soak.

Stage this beside remote_soak.py, ws_client.py, paseo.mts and
paseo-component.toml. Execute in a fresh directory inside MemoryMax=512M.
"""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import statistics
import subprocess
import time

RETAINED_RSS_BUDGET_KIB = 16 * 1024


def save(path, value):
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(value, indent=2) + '\n')
    temporary.replace(path)


def assess(result, rows, workload):
    if result['status'] != 'completed':
        raise ValueError('Workload did not complete successfully')
    if result['http_errors'] or result['paseo_errors']:
        raise ValueError('Workload reported request errors')
    if workload != 'paseo' and not result['http_ok']:
        raise ValueError('No successful HTTP traffic')
    if workload != 'http' and not result['paseo_ok']:
        raise ValueError('No successful Paseo traffic')
    load = [r for r in rows if r['phase'] == 'load']
    cool = [r for r in rows if r['phase'] == 'cooldown']
    if len(load) < 6 or len(cool) < 2:
        raise ValueError('Insufficient load/cooldown samples')
    baseline = statistics.median(r['runtime']['VmRSS'] for r in load[:3])
    settled = statistics.median(r['runtime']['VmRSS'] for r in cool[-3:])
    peak = max(r['runtime']['VmRSS'] for r in load)
    if settled > baseline + RETAINED_RSS_BUDGET_KIB:
        raise ValueError(f'Retained RSS grew more than 16 MiB: {baseline} -> {settled} KiB')
    if peak > 256*1024:
        raise ValueError(f'Load RSS exceeded 256 MiB: {peak} KiB')
    if max(r['runtime']['fd_count'] for r in load) > load[0]['runtime']['fd_count'] + 8:
        raise ValueError('File descriptor growth exceeded the eight-FD budget')
    return {'baseline_rss_kib': baseline, 'settled_rss_kib': settled,
            'max_load_rss_kib': peak, 'http_ok': result['http_ok'], 'paseo_ok': result['paseo_ok']}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary', required=True, type=Path)
    parser.add_argument('--observe-pid', required=True, type=int)
    parser.add_argument('--full-unit', required=True)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent
    if (root/'sequence.json').exists():
        raise RuntimeError('Use a fresh sequence directory')
    assets = ['remote_soak.py','ws_client.py','paseo.mts','paseo-component.toml']
    report = {'status':'validating','started_utc':time.strftime('%Y-%m-%dT%H:%M:%SZ',time.gmtime()),
              'binary':str(args.binary), 'binary_sha256':hashlib.sha256(args.binary.read_bytes()).hexdigest(),
              'retained_rss_budget_kib':RETAINED_RSS_BUDGET_KIB, 'max_load_rss_kib':256*1024,
              'asset_sha256':{name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in assets},
              'cases':[]}
    save(root/'sequence.json',report)
    try:
        for workload, duration in [('paseo',240),('http',240),('mixed',900)]:
            case = root/workload
            case.mkdir(mode=0o700)
            for asset in assets:
                shutil.copy2(root/asset,case/asset)
            command = ['/usr/bin/python3',str(case/'remote_soak.py'),'--binary',str(args.binary),
                       '--observe-pid',str(args.observe_pid),'--workload',workload,
                       '--signature-mode','isolated','--duration',str(duration)]
            report['current_case'] = workload
            save(root/'sequence.json',report)
            completed = subprocess.run(command)
            result = json.loads((case/'result.json').read_text())
            rows = [json.loads(line) for line in (case/'samples.ndjson').read_text().splitlines()]
            assessment = assess(result,rows,workload)
            if completed.returncode:
                raise ValueError(f'{workload} exited {completed.returncode}')
            report['cases'].append({'workload':workload,**assessment})
            save(root/'sequence.json',report)
        full = root/'full24'
        full.mkdir(mode=0o700)
        for asset in assets:
            shutil.copy2(root/asset,full/asset)
        command = ['systemd-run','--unit='+args.full_unit,'--property=MemoryMax=512M',
                   '--property=MemorySwapMax=0','--property=CPUQuota=100%','--property=TasksMax=128',
                   '--property=Nice=10','--property=IOWeight=10','--property=RuntimeMaxSec=90000',
                   '--property=TimeoutStopSec=30','--property=UMask=0077',
                   '/usr/bin/python3',str(full/'remote_soak.py'),'--binary',str(args.binary),
                   '--observe-pid',str(args.observe_pid),'--workload','mixed',
                   '--signature-mode','isolated','--duration','87600']
        subprocess.run(command,check=True)
        # systemd-run success alone does not prove the child has started.
        deadline = time.monotonic()+90
        while time.monotonic() < deadline:
            if (full/'state.json').exists():
                state = json.loads((full/'state.json').read_text())
                if state['status'] == 'failed':
                    raise ValueError('Full soak failed during startup')
                if state['status'] == 'running':
                    report.update(status='full_soak_running',full_unit=args.full_unit,
                                  full_state=state,full_command=command)
                    save(root/'sequence.json',report)
                    return 0
            time.sleep(1)
        raise ValueError('Full soak did not reach running state within 90 seconds')
    except Exception as error:
        report.update(status='failed',failure=str(error))
        save(root/'sequence.json',report)
        raise


if __name__ == '__main__':
    raise SystemExit(main())
