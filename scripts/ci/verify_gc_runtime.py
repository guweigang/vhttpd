#!/usr/bin/env python3
"""Reject a runtime whose compiler silently omitted or disabled Boehm GC."""
import json
from pathlib import Path
import subprocess
import sys


def verify_gc_runtime(command, **kwargs):
    try:
        info = json.loads(subprocess.check_output(
            [*command, '--build-info'], text=True, timeout=15,
            stderr=subprocess.PIPE, **kwargs))
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        raise ValueError('runtime GC verification failed: cannot read --build-info; use a native compiler with Boehm GC') from error
    if not isinstance(info, dict) or info.get('gc') != 'boehm' or info.get('gc_enabled') is not True:
        raise ValueError('runtime GC verification failed: actual runtime does not have enabled Boehm GC; cross compilation may silently disable it')
    return info


if __name__ == '__main__':
    try:
        verify_gc_runtime([str(Path(sys.argv[1]).resolve())])
    except ValueError as error:
        sys.exit(str(error))
    print('Verified actual runtime: Boehm GC enabled')
