#!/usr/bin/env python3
"""Use the same locked fonts as the macOS and Windows packages."""
from pathlib import Path
import sys
from prepare_fonts import package

if __name__ == '__main__':
    package(Path(sys.argv[1]))
