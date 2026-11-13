#!/usr/bin/env python3
"""Install the single Workbench Skill and its separate versioned contracts."""

import shutil
import sys
from pathlib import Path


def package_guidance(root: Path, destination: Path) -> None:
    source = root / 'src/development_guidance'
    skill = source / 'vhttpd-workbench'
    target = destination / 'skills' / skill.name
    for relative in ('SKILL.md', 'references/develop.md', 'references/deploy.md',
                     'references/debug.md'):
        if not (skill / relative).is_file():
            raise FileNotFoundError(skill / relative)
    ignore = shutil.ignore_patterns('.ok', '.DS_Store')
    shutil.copytree(skill, target, ignore=ignore)
    shutil.copytree(source / 'contracts', destination / 'guidance', ignore=ignore)


if __name__ == '__main__':
    if len(sys.argv) != 2:
        raise SystemExit('usage: package_guidance.py DESTINATION')
    package_guidance(Path(__file__).resolve().parents[1], Path(sys.argv[1]))
