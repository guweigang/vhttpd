#!/usr/bin/env python3
"""Verify that a dedicated MCP Hub can be reclaimed without affecting its neighbor."""

import base64
from contextlib import redirect_stdout
from io import StringIO
import json
from pathlib import Path
import runpy
import socket
import sys
import tempfile


def main():
    root = Path(__file__).resolve().parents[2]
    manage = runpy.run_path(str(root / 'desktop/host/remote_scripts/mcp_hub.py'))['manage']
    template = base64.b64encode((root / 'examples/config/mcp-relay-public-v2.toml').read_bytes())
    binary = str(Path(sys.argv[1]).resolve(strict=True))

    with tempfile.TemporaryDirectory() as directory:
        def request(hub_id, remove=False):
            with redirect_stdout(StringIO()) as output:
                manage(directory, hub_id, binary, 'c' * 64, template, remove)
            return json.loads(output.getvalue())

        first, second = 'a' * 32, 'b' * 32
        try:
            first_ports, second_ports = request(first), request(second)
            assert not set(first_ports.values()).intersection(second_ports.values())
            assert request(first, True) == request(first, True) == {}
            assert not (Path(directory) / 'mcp-hubs' / first).exists()
            for port in second_ports.values():
                with socket.create_connection(('127.0.0.1', port), timeout=2):
                    pass
        finally:
            request(first, True)
            request(second, True)
    print('PASS dedicated Hub startup, idempotent reclamation, and neighbor isolation')


if __name__ == '__main__':
    main()
