#!/usr/bin/env python3
"""Stage identical, verified font files on every build host. No runtime download."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import tempfile
import time
from urllib.request import urlopen

ROOT = Path(__file__).resolve().parent.parent
LOCK = ROOT / 'desktop/assets/fonts.lock.json'
UI2_FONTS = ROOT / '.deps/ui2/assets/fonts'
SUPPLEMENTAL = ('RobotoMono-Regular.ttf', 'RobotoMono-Bold.ttf', 'RobotoMono-OFL.txt',
                'NotoSansSymbols2-Regular.ttf', 'NotoSansSymbols2-OFL.txt',
                'NotoEmoji-Regular.ttf', 'NotoEmoji-OFL.txt',
                'MaterialIcons-Regular.ttf', 'MaterialIcons-LICENSE.txt')


def valid(path, asset):
    return path.is_file() and path.stat().st_size == asset['bytes'] and hashlib.sha256(path.read_bytes()).hexdigest() == asset['sha256']


def package(destination, cache=None, offline=False):
    destination = Path(destination)
    cache = Path(cache or os.environ.get('VHTTPD_FONT_CACHE', ROOT / '.deps/workbench-fonts'))
    cache.mkdir(parents=True, exist_ok=True)
    destination.mkdir(parents=True, exist_ok=True)
    lock = json.loads(LOCK.read_text())
    for asset in lock['assets']:
        source = cache / asset['file']
        if not valid(source, asset):
            if offline:
                raise RuntimeError(f"Missing or corrupt cached font: {asset['file']}")
            for attempt in range(3):
                try:
                    with urlopen(asset['url'], timeout=90) as response:
                        data = response.read(asset['bytes'] + 1)
                    if len(data) != asset['bytes'] or hashlib.sha256(data).hexdigest() != asset['sha256']:
                        raise RuntimeError(f"Font checksum mismatch: {asset['file']}")
                    with tempfile.NamedTemporaryFile(dir=cache, delete=False) as output:
                        temporary = Path(output.name)
                        output.write(data)
                    temporary.replace(source)
                    break
                except Exception:
                    if attempt == 2:
                        raise
                    time.sleep(attempt + 1)
        if source.resolve() != (destination / asset['file']).resolve():
            shutil.copyfile(source, destination / asset['file'])
    for name in SUPPLEMENTAL:
        shutil.copyfile(UI2_FONTS / name, destination / name)
    shutil.copyfile(LOCK, destination / 'fonts.lock.json')
    return destination


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('destination', type=Path)
    parser.add_argument('--offline', action='store_true')
    args = parser.parse_args()
    package(args.destination, offline=args.offline)
