#!/usr/bin/env python3
"""Reject a runtime whose compiler silently omitted or disabled Boehm GC."""
import json
import os
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
        # Unpackaged macOS bottles retain Homebrew relocation placeholders.
        # Scope the library override to this probe, never the packaged app.
        probe_options = {}
        library_path = os.environ.get('VHTTPD_GC_PROBE_LIBRARY_PATH')
        if sys.platform == 'darwin' and library_path:
            probe_options['env'] = {**os.environ, 'DYLD_LIBRARY_PATH': library_path}
        verify_gc_runtime([str(Path(sys.argv[1]).resolve())], **probe_options)
    except ValueError as error:
        sys.exit(str(error))
    print('Verified actual runtime: Boehm GC enabled')
