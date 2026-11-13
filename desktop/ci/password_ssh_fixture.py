"""Loopback-only password SSH fixture; no OS accounts or SSH settings change.

System OpenSSH authenticates and forwards real Admin traffic over this SSH
endpoint. The synthetic password stays in Python/V memory and an anonymous
stdin pipe; it is never written into test configuration or environment.
"""
import secrets
import select
import socket
import threading

import paramiko


class PasswordSSHFixture:
    def __init__(self, port, admin_port, password):
        self.key = paramiko.RSAKey.generate(2048)
        self.password = password
        self.admin_port = admin_port
        self.auth_attempts = 0
        self.stopped = threading.Event()
        self.transports = []
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', port))
        self.listener.listen()
        self.listener.settimeout(0.2)
        threading.Thread(target=self._accept, daemon=True).start()

    def known_host(self, port):
        return f'[127.0.0.1]:{port} {self.key.get_name()} {self.key.get_base64()}\n'

    def _accept(self):
        while not self.stopped.is_set():
            try:
                connection, _ = self.listener.accept()
            except socket.timeout:
                continue
            except OSError:
                return
            threading.Thread(target=self._session, args=(connection,), daemon=True).start()

    def _session(self, connection):
        fixture = self

        class Authentication(paramiko.ServerInterface):
            def get_allowed_auths(self, username):
                return 'password'

            def check_auth_password(self, username, password):
                fixture.auth_attempts += 1
                return (paramiko.AUTH_SUCCESSFUL if secrets.compare_digest(
                    password.encode(), fixture.password.encode()) else paramiko.AUTH_FAILED)

            def check_channel_direct_tcpip_request(self, chanid, origin, destination):
                if destination == ('127.0.0.1', fixture.admin_port):
                    return paramiko.OPEN_SUCCEEDED
                return paramiko.OPEN_FAILED_ADMINISTRATIVELY_PROHIBITED

        transport = paramiko.Transport(connection)
        self.transports.append(transport)
        transport.add_server_key(self.key)
        try:
            transport.start_server(server=Authentication())
            while transport.is_active() and not self.stopped.is_set():
                channel = transport.accept(0.2)
                if channel is not None:
                    threading.Thread(target=self._forward, args=(channel,), daemon=True).start()
        except (EOFError, OSError, paramiko.SSHException):
            pass
        finally:
            transport.close()

    def _forward(self, channel):
        upstream = None
        try:
            upstream = socket.create_connection(('127.0.0.1', self.admin_port), timeout=3)
            while not self.stopped.is_set():
                for source in select.select([channel, upstream], [], [], 0.2)[0]:
                    data = source.recv(65536)
                    if not data:
                        return
                    (upstream if source is channel else channel).sendall(data)
        except (EOFError, OSError, paramiko.SSHException):
            pass
        finally:
            channel.close()
            if upstream is not None:
                upstream.close()

    def close(self):
        self.stopped.set()
        self.listener.close()
        for transport in self.transports:
            transport.close()
        self.password = ''
