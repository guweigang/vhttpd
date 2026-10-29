#!/usr/bin/env python3
"""Ship the static Simplified Chinese faces; no system fonts needed at runtime."""
from pathlib import Path
import shutil
import sys

from fontTools.ttLib import TTCollection


def package(destination):
    destination.mkdir(parents=True, exist_ok=True)
    for weight in ('Regular', 'Bold'):
        source = Path('/usr/share/fonts/opentype/noto') / f'NotoSansCJK-{weight}.ttc'
        collection = TTCollection(source)
        matches = [font for font in collection.fonts
                   if font['name'].getDebugName(1) == 'Noto Sans CJK SC']
        if len(matches) != 1:
            raise RuntimeError(f'Cannot identify Simplified Chinese face in {source}')
        matches[0].save(destination / f'NotoSansCJKsc-{weight}.otf')
        collection.close()
    shutil.copyfile('/usr/share/doc/fonts-noto-cjk/copyright', destination / 'NotoSansCJK-LICENSE.txt')
    ui2 = Path(__file__).resolve().parent.parent / '.deps/ui2/assets/fonts'
    for filename in ('NotoSansSymbols2-Regular.ttf', 'NotoSansSymbols2-OFL.txt',
                     'NotoEmoji-Regular.ttf', 'NotoEmoji-OFL.txt',
                     'RobotoMono-Regular.ttf', 'RobotoMono-Bold.ttf', 'RobotoMono-OFL.txt',
                     'MaterialIcons-Regular.ttf', 'MaterialIcons-LICENSE.txt'):
        shutil.copyfile(ui2 / filename, destination / filename)


if __name__ == '__main__':
    package(Path(sys.argv[1]))
