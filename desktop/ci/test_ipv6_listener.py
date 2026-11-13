"""Run a real vhttpd with IPv4 and IPv6 business listeners in one isolated instance."""
import http.client
import os
from pathlib import Path
import secrets
import signal
import socket
import subprocess
import tempfile
import time
import unittest


def free_port(family, host):
    with socket.socket(family, socket.SOCK_STREAM) as connection:
        connection.bind((host, 0))
        return connection.getsockname()[1]


class IPv6ListenerTest(unittest.TestCase):
    def test_real_runtime_serves_both_loopback_families(self):
        binary = Path(os.environ['VHTTPD_TEST_BINARY']).resolve(strict=True)
        ipv4 = free_port(socket.AF_INET, '127.0.0.1')
        ipv6 = free_port(socket.AF_INET6, '::1')
        admin = free_port(socket.AF_INET, '127.0.0.1')
        while admin == ipv4:
            admin = free_port(socket.AF_INET, '127.0.0.1')
        with tempfile.TemporaryDirectory(prefix='vhttpd-ipv6-listener-') as directory:
            root = Path(directory)
            config = 'version = 2\n[server]\npid_file = "runtime.pid"\n'
            for name, host, port in [('web4', '127.0.0.1', ipv4), ('web6', '::1', ipv6), ('admin', '127.0.0.1', admin)]:
                config += f'[listeners.{name}]\nprotocol = "http"\ntransport = "tcp"\nhost = "{host}"\nport = {port}\n'
            config += '[control]\nlistener = "listener:admin"\ntoken = "' + secrets.token_hex(24) + '"\n'
            config += '[adapters.reply]\nkind = "fixed-response"\noptions.status = "200"\noptions.body = "ipv6-listener-ok"\n'
            for name in ('web4', 'web6'):
                config += f'[[pipelines]]\nid = "{name}.reply"\ningress = "listener:{name}"\nmatch.paths = ["/probe"]\negress = "adapter:reply"\n'
            entry = root / 'vhttpd.toml'
            entry.write_text(config)
            with (root / 'runtime.log').open('w+') as log:
                process = subprocess.Popen([str(binary), '--config', str(entry)], cwd=root, stdout=log, stderr=subprocess.STDOUT)
                try:
                    for host, port in [('127.0.0.1', ipv4), ('::1', ipv6)]:
                        deadline = time.monotonic() + 30
                        last_error = None
                        while time.monotonic() < deadline:
                            connection = http.client.HTTPConnection(host, port, timeout=1)
                            try:
                                connection.request('GET', '/probe')
                                response = connection.getresponse()
                                self.assertEqual(response.status, 200)
                                self.assertEqual(response.read(), b'ipv6-listener-ok')
                                break
                            except OSError as error:
                                last_error = error
                                if process.poll() is not None:
                                    self.fail(f'runtime stopped before {host} became ready')
                                time.sleep(.1)
                            finally:
                                connection.close()
                        else:
                            self.fail(f'{host} did not become ready: {last_error}')
                finally:
                    if process.poll() is None:
                        process.terminate()
                    try:
                        process.wait(timeout=10)
                    except subprocess.TimeoutExpired:
                        process.kill()
                        process.wait(timeout=5)
                self.assertIn(process.returncode, (0, -signal.SIGTERM, 128 + signal.SIGTERM))


if __name__ == '__main__':
    unittest.main()
