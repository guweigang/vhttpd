#!/usr/bin/env python3
"""Apply fractional text advances in a build-local module, never in V's checkout."""
import os
from pathlib import Path
import shutil
import subprocess
import sys

def prepare(destination, compiler=None):
    destination = Path(destination).resolve()
    executable = compiler or os.environ.get('VHTTPD_DESKTOP_V', 'v')
    found = shutil.which(executable)
    if not found: raise RuntimeError('V compiler not found: ' + executable)
    vroot = Path(found).resolve().parent
    source = vroot / 'vlib/fontstash'
    if not source.is_dir(): raise RuntimeError('V fontstash module missing: ' + str(vroot))
    shutil.copytree(source,destination)
    thirdparty = destination / 'thirdparty/fontstash'
    shutil.copytree(vroot/'thirdparty/fontstash',thirdparty)
    patch = Path(__file__).resolve().parent/'patches/fontstash-fractional-advances.patch'
    subprocess.run(['git','apply','--no-index','--check',str(patch)],cwd=destination,check=True)
    subprocess.run(['git','apply','--no-index',str(patch)],cwd=destination,check=True)
    if 'float xadv;' not in (thirdparty/'fontstash.h').read_text():
        raise RuntimeError('Fractional font advance patch did not apply')
    binding = destination/'fontstash.c.v'
    binding.write_text(binding.read_text().replace('@VEXEROOT/thirdparty/fontstash',thirdparty.as_posix()).replace('@VEXEROOT/vlib/fontstash/fontstash_impl.c',(destination/'fontstash_impl.c').as_posix()))
    return destination

if __name__ == '__main__': print(prepare(sys.argv[1]))
