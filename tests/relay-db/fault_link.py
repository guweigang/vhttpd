"""TCP fault injection for tests. Carries opaque WebSocket bytes; no HTTP handling."""
import select
import socket
import threading


class FaultLink:
    def __init__(self, host, port):
        self.target = (host, port)
        self.lock = threading.Lock()
        self.online = True
        self.stopped = threading.Event()
        self.hold_responses = threading.Event()
        self.connections = set()
        self.listener = socket.socket()
        self.listener.bind(('127.0.0.1', 0))
        self.port = self.listener.getsockname()[1]
        self.listener.listen(16)
        self.listener.settimeout(.1)
        self.worker = threading.Thread(target=self.accept, daemon=True)
        self.worker.start()

    @staticmethod
    def release(pair):
        client, server, closed = pair
        closed.set()
        for stream in (client, server):
            try: stream.shutdown(socket.SHUT_RDWR)
            except OSError: pass
            stream.close()

    def accept(self):
        while not self.stopped.is_set():
            try: client, _ = self.listener.accept()
            except socket.timeout: continue
            except OSError: return
            with self.lock:
                online = self.online
            if not online:
                client.close()
                continue
            try: server = socket.create_connection(self.target, timeout=2)
            except OSError:
                client.close()
                continue
            client.settimeout(1)
            server.settimeout(1)
            pair = (client, server, threading.Event())
            with self.lock:
                if not self.online or self.stopped.is_set():
                    self.release(pair)
                    continue
                self.connections.add(pair)
            threading.Thread(target=self.pump, args=(pair,), daemon=True).start()

    def pump(self, pair):
        client, server, closed = pair
        try:
            while not closed.is_set():
                ready, _, _ = select.select([client, server], [], [], .1)
                for source in ready:
                    data = source.recv(65536)
                    if not data: return
                    if source is server:
                        while self.hold_responses.is_set() and not closed.is_set():
                            closed.wait(.01)
                    if closed.is_set(): return
                    (client if source is server else server).sendall(data)
        except (OSError, ValueError):
            pass
        finally:
            self.release(pair)
            with self.lock: self.connections.discard(pair)

    def cut(self):
        with self.lock:
            self.online = False
            pairs = list(self.connections)
        for pair in pairs: self.release(pair)

    def resume(self):
        self.hold_responses.clear()
        with self.lock: self.online = True

    def close(self):
        self.stopped.set()
        self.cut()
        self.listener.close()
        self.worker.join(timeout=2)
