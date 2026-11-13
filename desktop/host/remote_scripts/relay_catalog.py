import base64, hashlib, json, os, re, stat, tempfile, zlib
from pathlib import Path


def catalog_operation(encoded):
    try:
        decoder = zlib.decompressobj()
        raw = decoder.decompress(base64.b64decode(encoded), 65537)
        if len(raw) > 65536 or not decoder.eof:
            raise ValueError()
        request = json.loads(raw)
        root = Path.home() / '.local/share/vhttpd-workbench'
        if root.is_symlink():
            raise ValueError()
        root.mkdir(parents=True, exist_ok=True, mode=0o700)
        path = root / 'shared-relays.json'
        def load():
            if path.is_symlink():
                raise ValueError()
            if not path.exists():
                return b'[]', [], ''
            if not path.is_file() or path.stat().st_size > 1048576:
                raise ValueError()
            if stat.S_IMODE(path.stat().st_mode) & 0o077:
                raise ValueError()
            data = path.read_bytes()
            entries = json.loads(data)
            if not isinstance(entries, list) or len(entries) > 128:
                raise ValueError()
            return data, entries, hashlib.sha256(data).hexdigest()
        data, entries, revision = load()
        if request['operation'] != 'load':
            lock = root / '.relay-catalog-lock'
            lock.mkdir(mode=0o700)
            try:
                data, entries, revision = load()
                if revision != request['revision']:
                    print('VHTTPD_ERROR:连接库已由其他操作修改，请刷新后重试。')
                    raise SystemExit(1)
                entry = request['entry']
                if not re.fullmatch('[0-9a-fA-F]{24}', entry['id']):
                    raise ValueError()
                entries = [x for x in entries if x['id'] != entry['id']]
                if request['operation'] == 'save':
                    entries.append(entry)
                elif request['operation'] != 'delete':
                    raise ValueError()
                if len(entries) > 128:
                    raise ValueError()
                data = json.dumps(entries, ensure_ascii=False).encode()
                if len(data) > 1048576:
                    raise ValueError()
                fd, name = tempfile.mkstemp(prefix='.relay-catalog-', dir=root)
                try:
                    with os.fdopen(fd, 'wb') as output:
                        output.write(data)
                        output.flush()
                        os.fsync(output.fileno())
                    os.replace(name, path)
                finally:
                    Path(name).unlink(missing_ok=True)
                revision = hashlib.sha256(data).hexdigest()
            finally:
                lock.rmdir()
        print(json.dumps({'loaded': True, 'entries': entries, 'revision': revision}))
    except Exception:
        print('VHTTPD_ERROR:连接库操作失败；请检查文件权限、格式或并发操作，原有连接未被覆盖。')
        raise SystemExit(1)
