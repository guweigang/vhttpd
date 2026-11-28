#!/usr/bin/env python3
"""Build a native decoder from SHA256 pinned upstream sources; no Python at runtime."""
import argparse
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tarfile
import tempfile
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / 'desktop/assets/font-decoder.lock.json'

def build(destination, cache=None):
    destination = Path(destination).resolve()
    destination.parent.mkdir(parents=True, exist_ok=True)
    cache = Path(cache or ROOT / '.deps/font-decoder')
    cache.mkdir(parents=True, exist_ok=True)
    lock = json.loads(LOCK.read_text())
    with tempfile.TemporaryDirectory(prefix='font-decoder-') as stage:
        work = Path(stage)
        sources = {}
        for item in lock['sources']:
            archive = cache / (item['name'] + '-' + item['revision'] + '.tar.gz')
            if not archive.is_file() or hashlib.sha256(archive.read_bytes()).hexdigest() != item['sha256']:
                with urlopen(item['url'], timeout=90) as response:
                    data = response.read(item['bytes'] + 1)
                if len(data) != item['bytes'] or hashlib.sha256(data).hexdigest() != item['sha256']:
                    raise RuntimeError('Decoder source checksum mismatch: ' + item['name'])
                archive.write_bytes(data)
            with tarfile.open(archive) as tar:
                tar.extractall(work, filter='data')
            sources[item['name']] = work / (item['name'] + '-' + item['revision'])
        woff, brotli = sources['woff2'], sources['brotli']
        includes = [woff / 'include', woff / 'src', brotli / 'c/include']
        files = sorted((brotli / 'c/common').glob('*.c')) + sorted((brotli / 'c/dec').glob('*.c'))
        files += [woff / 'src' / (n + '.cc') for n in ['table_tags','variable_length','woff2_common','woff2_dec','woff2_out']]
        files += [ROOT / 'desktop/font_decoder/main.cpp']
        windows = platform.system() == 'Windows'
        def compile(source):
            obj = work / (source.parent.name + '_' + source.name + ('.obj' if windows else '.o'))
            if windows:
                args = ['cl','/nologo','/O2','/MT','/DNDEBUG','/c',str(source),'/Fo'+str(obj)]
                args += ['/I'+str(p) for p in includes]
                if source.suffix != '.c': args += ['/std:c++17','/EHsc']
            else:
                args = [os.environ.get('CXX','c++') if source.suffix != '.c' else os.environ.get('CC','cc'),'-O2','-fvisibility=hidden','-DNDEBUG']
                if source.suffix != '.c': args += ['-std=c++17']
                args += ['-I'+str(p) for p in includes] + ['-c',str(source),'-o',str(obj)]
            subprocess.run(args, check=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
            return str(obj)
        with concurrent.futures.ThreadPoolExecutor(max_workers=2) as pool:
            objects = list(pool.map(compile,files))
        executable = work / ('fontdecode.exe' if windows else 'fontdecode')
        command = ['cl','/nologo','/MT'] + objects + ['/Fe:'+str(executable)] if windows else [os.environ.get('CXX','c++')] + objects + ['-o',str(executable)]
        subprocess.run(command,check=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
        if not windows: subprocess.run(['strip',str(executable)],check=True)
        shutil.copy2(executable,destination)
        licenses = destination.parent / 'font-decoder-licenses'
        licenses.mkdir(exist_ok=True)
        for name,path in [('WOFF2',woff/'LICENSE'),('Brotli',brotli/'LICENSE')]:
            shutil.copyfile(path,licenses/(name+'.txt'))
        shutil.copyfile(LOCK,licenses/'sources.lock.json')
    return destination

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination',type=Path)
    args = parser.parse_args()
    try: print(build(args.destination))
    except subprocess.CalledProcessError as error:
        print(error.stdout.decode(errors='replace') if isinstance(error.stdout,bytes) else error.stdout)
        raise
