import base64, json, os, stat
from pathlib import Path


def relay_logs(config):
    # Only the discovered Desktop instance and its live stdout/stderr log files.
    project = Path(config).parent
    root = Path.home() / '.local/share/vhttpd-workbench/instances'
    if project.is_symlink() or project.parent != root or project.resolve().parent != root.resolve():
        raise ValueError('invalid instance')
    paths = set()
    for process in Path('/proc').glob('[0-9]*'):
        try:
            if process.stat().st_uid != os.getuid() or (process / 'cwd').resolve() != project.resolve():
                continue
            if (process / 'exe').resolve().name not in ('vhttpd', 'vhttpd (deleted)'):
                continue
            for fd in ('1', '2'):
                candidate = (process / 'fd' / fd).resolve()
                if candidate.name not in ('process.log', 'runtime.log') or project.resolve() not in candidate.parents:
                    continue
                if stat.S_ISREG(candidate.stat().st_mode):
                    paths.add(candidate)
        except (OSError, RuntimeError):
            pass
    if not paths:
        candidate = project / 'process.log'
        if not candidate.is_symlink() and candidate.is_file():
            paths.add(candidate)
    parts = []
    for path in sorted(paths)[:2]:
        with path.open('rb') as stream:
            stream.seek(max(0, path.stat().st_size - 32768))
            parts.append(stream.read(32768).decode('utf-8', errors='replace'))
    print(json.dumps({'text': '\n'.join(parts)}))
