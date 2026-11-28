module ws

import net
import net.websocket
import sync
import time

// TLS handoff preserves bytes already read by the HTTP parser. OpenSSL calls
// on the borrowed session must be serialized even with one reader and writer.
pub interface TlsIngressSocket {
mut:
	read_with_timeout(mut buf []u8, timeout time.Duration) !int
	write(buf []u8) !int
	close() !
}

@[heap]
struct TlsIngressTransport {
mut:
	socket TlsIngressSocket
	mu     sync.Mutex
}

fn (mut transport TlsIngressTransport) read(mut buf []u8) !int {
	for {
		transport.mu.@lock()
		n := transport.socket.read_with_timeout(mut buf, 25 * time.millisecond) or {
			transport.mu.unlock()
			if err.code() == net.err_timed_out.code() {
				// Give pending hub writes access while the other peer is idle.
				time.sleep(time.millisecond)
				continue
			}
			return err
		}
		transport.mu.unlock()
		return n
	}
	return 0
}

fn (mut transport TlsIngressTransport) write(buf []u8) !int {
	transport.mu.@lock()
	defer { transport.mu.unlock() }
	return transport.socket.write(buf)
}

fn (mut transport TlsIngressTransport) close() ! {
	transport.mu.@lock()
	defer { transport.mu.unlock() }
	transport.socket.close()!
}

@[heap]
pub struct IngressConnection {
mut:
	tcp ?&net.TcpConn
	tls ?&TlsIngressTransport
}

pub fn IngressConnection.tcp(conn &net.TcpConn) &IngressConnection {
	return &IngressConnection{tcp: conn}
}

pub fn IngressConnection.tls(socket TlsIngressSocket) &IngressConnection {
	return &IngressConnection{tls: &TlsIngressTransport{socket: socket}}
}

pub fn (mut conn IngressConnection) close() ! {
	if mut tls := conn.tls {
		tls.close()!
	} else if mut tcp := conn.tcp {
		tcp.close()!
	}
}

// V versions without an owned server transport still support ordinary TCP.
fn handshake_tls_transport[T](mut server T, mut tls TlsIngressTransport, key string) ! {
	$for method in T.methods {
		$if method.name == 'handle_transport_handshake' {
			server.$method(tls, true, key)!
			return
		}
	}
	return error('WebSocket TLS transport is unavailable in this V toolchain')
}

fn (mut conn IngressConnection) handshake(mut server websocket.Server, key string) ! {
	if mut tls := conn.tls {
		handshake_tls_transport[websocket.Server](mut server, mut tls, key)!
	} else if mut tcp := conn.tcp {
		server.handle_handshake(mut tcp, key)!
	} else {
		return error('WebSocket connection is unavailable')
	}
}
