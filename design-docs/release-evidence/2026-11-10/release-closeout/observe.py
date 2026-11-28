"""Read counters for one verified bodytest process; no requests or injected GC."""
from pathlib import Path
import datetime, hashlib, json, time
from counter import process

root = Path(__file__).resolve().parent
expected = json.loads((root / 'business-identity.json').read_text())
pid = int(expected['pid'])
pid_file = Path('/root/.local/share/vhttpd-workbench/instances/bodytest/runtime.pid')
try:
    while True:
        assert int(pid_file.read_text()) == pid, 'Business PID changed'
        value = process(pid)
        assert value['start_ticks'] == int(expected['start_ticks']), 'Business process replaced'
        assert value['binary_sha256'] == expected['binary_sha256'], 'Business package changed'
        value['utc'] = datetime.datetime.now(datetime.timezone.utc).isoformat()
        value['pid'] = pid
        value['host_available_kib'] = next(int(s.split()[1]) for s in Path('/proc/meminfo').read_text().splitlines() if s.startswith('MemAvailable:'))
        day = datetime.datetime.now(datetime.timezone.utc).strftime('%Y%m%d')
        with (root / ('memory-' + day + '.ndjson')).open('a') as out:
            out.write(json.dumps(value) + '\n')
        tmp = root / 'latest.tmp'
        tmp.write_text(json.dumps(value, indent=2))
        tmp.replace(root / 'latest.json')
        time.sleep(10)
except BaseException as error:
    (root / 'observer-stopped.json').write_text(json.dumps({'reason': str(error), 'utc': datetime.datetime.now(datetime.timezone.utc).isoformat()}))
    raise
