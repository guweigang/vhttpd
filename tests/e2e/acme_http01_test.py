"""Run built-in ACME against Pebble with actual HTTP-01 and short-lived certificates."""

import argparse
import contextlib
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time

from tls_reload_test import (
    connect_tls, fingerprint, free_port, fresh_fingerprint, read_frame,
    read_headers, send_message, serve_config, upgrade_websocket,
)

DOMAIN = "acme-probe.example.test"


@contextlib.contextmanager
def running(command, directory, log_name, env=None):
    log_path = directory / log_name
    with log_path.open("w") as log:
        process = subprocess.Popen(command, cwd=directory, env=env, stdout=log, stderr=log)
        try:
            yield process
        except Exception:
            print(log_path.read_text(), flush=True)
            raise
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


def reserve_ports(count):
    with contextlib.ExitStack() as stack:
        sockets = [stack.enter_context(socket.socket()) for _ in range(count)]
        for sock in sockets:
            sock.bind(("127.0.0.1", 0))
        return [sock.getsockname()[1] for sock in sockets]


def wait_port(port, process, deadline):
    while time.monotonic() < deadline and process.poll() is None:
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=1):
                return
        except OSError:
            time.sleep(0.05)
    raise AssertionError(f"service did not start on port {port}: {process.poll()}")


def pebble_config(directory, acme_port, management_port, challenge_port):
    pem = directory / "pebble.pem"
    key = directory / "pebble.key"
    subprocess.run(
        ["openssl", "req", "-x509", "-newkey", "rsa:2048", "-nodes", "-days", "1",
         "-subj", "/CN=localhost", "-addext", "subjectAltName=DNS:localhost,IP:127.0.0.1",
         "-keyout", key, "-out", pem], check=True, capture_output=True,
    )
    config = directory / "pebble.json"
    config.write_text(json.dumps({"pebble": {
        "listenAddress": f"127.0.0.1:{acme_port}",
        "managementListenAddress": f"127.0.0.1:{management_port}",
        "certificate": str(pem), "privateKey": str(key),
        "httpPort": challenge_port, "tlsPort": challenge_port,
        "retryAfter": {"authz": 1, "order": 1},
        "keyAlgorithm": "ecdsa",
        "profiles": {"default": {"description": "Short integration-test lifetime", "validityPeriod": 18}},
    }}))
    return config, pem


def verify_live_renewal(process, state, port, challenge_port, directory):
    wait_port(port, process, time.monotonic() + 45)
    first = fresh_fingerprint(port)
    with (connect_tls(port) as ws, ws.makefile("rb") as frames,
          connect_tls(port) as sse, sse.makefile("rb") as events):
        assert fingerprint(ws) == fingerprint(sse) == first
        upgrade_websocket(ws, frames)
        assert read_frame(frames, 1) == b"echo:connected"
        sse.sendall(b"GET /events/sse HTTP/1.1\r\nHost: localhost\r\n\r\n")
        status, _ = read_headers(events)
        assert status.startswith(b"HTTP/1.1 200 "), status
        assert [events.readline() for _ in range(4)] == [
            b"event: tick\n", b"data: before\n", b"data: multiline\n", b"\n",
        ]
        deadline = time.monotonic() + 35
        second = first
        while time.monotonic() < deadline:
            second = fresh_fingerprint(port)
            if second != first:
                break
            time.sleep(0.15)
        assert second != first, "timed renewal never switched the listener"
        assert [fresh_fingerprint(port) for _ in range(5)] == [second] * 5
        (directory / "release-sse").touch()
        assert [events.readline() for _ in range(3)] == [
            b"event: tick\n", b"data: after\n", b"\n",
        ]
        send_message(ws, b"renewed")
        assert read_frame(frames, 1) == b"echo:renewed"
        assert fingerprint(ws) == fingerprint(sse) == first
        assert process.poll() is None
    with socket.create_connection(("127.0.0.1", challenge_port), timeout=2) as challenge:
        challenge.sendall(f"GET /.well-known/acme-challenge/unknown HTTP/1.1\r\nHost: {DOMAIN}\r\n\r\n".encode())
        assert challenge.recv(80).startswith(b"HTTP/1.1 404 ")
    stored = json.loads((state / "acme" / "account.json").read_text())
    assert stored["kid"] and stored["directory"].startswith("https://localhost:")
    assert (state.stat().st_mode & 0o077) == 0
    assert (state / "acme" / "tls.json").is_file()
    return second


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("vhttpd", type=Path)
    parser.add_argument("pebble", type=Path)
    parser.add_argument("challtestsrv", type=Path)
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix="va-", dir="/tmp") as root:
        directory = Path(root)
        dns, dns_control, ca, ca_control, challenge, https, admin = reserve_ports(7)
        config, ca_pem = pebble_config(directory, ca, ca_control, challenge)
        instance_config = serve_config(directory, https, admin)
        # The TLS paths are provided by ACME after the first successful order.
        text = instance_config.read_text()
        start = text.index("[server.ssl]")
        finish = text.index("[files]", start)
        instance_config.write_text(text[:start] + text[finish:])
        fixture = directory / "combined.php"
        fixture.write_text(fixture.read_text().replace("microtime(true) + 10", "microtime(true) + 40"))
        dns_cmd = [args.challtestsrv.resolve(), "-dnsserver", f"127.0.0.1:{dns}",
                   "-management", f"127.0.0.1:{dns_control}", "-defaultIPv6", "",
                   "-http01", "", "-https01", "", "-tlsalpn01", "", "-doh", ""]
        pebble_cmd = [args.pebble.resolve(), "-config", config, "-dnsserver", f"127.0.0.1:{dns}"]
        env = dict(os.environ, PEBBLE_VA_NOSLEEP="1", PEBBLE_AUTHZREUSE="0", PEBBLE_WFE_NONCEREJECT="0")
        env.pop("PEBBLE_VA_ALWAYS_VALID", None)
        state = directory / "acme-state"
        command = [args.vhttpd.resolve(), "--config", instance_config, "--acme-domain", DOMAIN,
                   "--acme-directory", f"https://localhost:{ca}/dir", "--acme-ca-file", ca_pem,
                   "--acme-http-port", str(challenge), "--acme-state-dir", state,
                   "--acme-renew-before-seconds", "5"]
        with running(dns_cmd, directory, "dns.log") as dns_process:
            wait_port(dns_control, dns_process, time.monotonic() + 5)
            with running(pebble_cmd, directory, "pebble.log", env) as pebble:
                wait_port(ca, pebble, time.monotonic() + 5)
                with running(command, directory, "vhttpd.log") as vhttpd:
                    renewed = verify_live_renewal(vhttpd, state, https, challenge, directory)
                assert (directory / "vhttpd.log").read_text().count("[acme] installed certificate") == 2
                with running(command, directory, "restart.log") as restarted:
                    wait_port(https, restarted, time.monotonic() + 10)
                    assert fresh_fingerprint(https) == renewed
                assert "[acme] installed certificate" not in (directory / "restart.log").read_text()
    print("Pebble HTTP-01 passed: first issuance, scheduled renewal, hot replacement, restart reuse, WSS and SSE survived")


if __name__ == "__main__":
    main()
