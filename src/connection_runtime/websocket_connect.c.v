module connection_runtime

import net
import socket_runtime
import net.websocket
import time

$if !windows {
#include <netinet/tcp.h>
}

// Attach cancellation before allocating a candidate. Only the connect caller
// touches native client/TLS state; stop shuts down its retained socket alias.
pub fn connect_websocket(mut client websocket.Client, mut run Run) !&Session {
	mut session := &Session{ client: unsafe { &client } }
	if !run.attach(mut session) { return error('websocket_connect_cancelled') }
	mut transferred := false
	defer {
		if !transferred {
			session.request_stop()
			run.detach(session)
			session.release()
		}
	}
	client.connect_with_dialer(fn [mut session] (address string) !&net.TcpConn {
		return session.dial_tcp(address)
	})!
	// Publish the successful candidate identity under the same stop mutex.
	session.mu.@lock()
	if session.stopping {
		session.mu.unlock()
		return error('websocket_connect_cancelled')
	}
	session.native = client.conn
	session.mu.unlock()
	transferred = true
	return session
}

fn (mut session Session) retain_native(fd int) ! {
	session.mu.@lock()
	defer { session.mu.unlock() }
	if session.stopping { return error('websocket_connect_cancelled') }
	if session.interrupt != none { return error('websocket_socket_already_retained') }
	duplicate := socket_runtime.retain(fd) or {
		return error(if err.msg() == 'socket_interrupt_dup_failed' { 'websocket_interrupt_dup_failed' } else { 'websocket_native_cloexec_failed' })
	}
	session.interrupt = duplicate
}

// Failed address candidates are serial and unpublished. Remove the alias under
// the stop mutex before closing the native candidate or trying the next address.
fn (mut session Session) discard_connect_candidate() {
	session.mu.@lock()
	defer { session.mu.unlock() }
	owned := session.interrupt
	session.interrupt = none
	if fd := owned { net.close(fd) or {} }
}

fn (mut session Session) dial_tcp(address string) !&net.TcpConn {
	if session.stopped() { return error('websocket_connect_cancelled') }
	// The system resolver is synchronous; check cancellation again before any
	// allocation. Do not leave detached resolver/dial threads behind on stop.
	addresses := net.resolve_addrs_fuzzy(address, .tcp)!
	mut last_error := 'no resolved TCP address'
	for addr in addresses {
		if session.stopped() { return error('websocket_connect_cancelled') }
		candidate := session.dial_address(addr) or {
			last_error = err.msg()
			continue
		}
		return candidate
	}
	if session.stopped() { return error('websocket_connect_cancelled') }
	return error('websocket_tcp_dial_failed:${last_error}')
}

fn (mut session Session) dial_address(address net.Addr) !&net.TcpConn {
	fd := net.socket_error(C.socket(i32(address.family()), i32(net.SocketType.tcp), 0))!
	mut transferred := false
	mut retained := false
	defer {
		if !transferred {
			if retained { session.discard_connect_candidate() }
			net.close(fd) or {}
		}
	}
	session.retain_native(fd)!
	retained = true
	// Preserve SDK TCP defaults while owning every option/setup failure.
	one := i32(1)
	net.socket_error(C.setsockopt(i32(fd), C.SOL_SOCKET, C.SO_REUSEADDR, &one, u32(sizeof(one))))!
	$if macos {
		net.socket_error(C.setsockopt(i32(fd), C.SOL_SOCKET, C.SO_NOSIGPIPE, &one, u32(sizeof(one))))!
	}
	net.socket_error(C.setsockopt(i32(fd), C.IPPROTO_TCP, C.TCP_NODELAY, &one, u32(sizeof(one))))!
	net.set_blocking(fd, false)!
	if session.stopped() { return error('websocket_connect_cancelled') }
	result := C.connect(i32(fd), voidptr(&address), address.len())
	if result < 0 {
		code := net.error_code()
		if !socket_runtime.connect_pending(code) {
			return error_with_code('websocket_tcp_connect_failed:${code}', code)
		}
		session.wait_connected(fd)!
	}
	if session.stopped() { return error('websocket_connect_cancelled') }
	mut blocking := false
	$if !net_nonblocking_sockets ? {
		net.set_blocking(fd, true)!
		blocking = true
	}
	mut conn := &net.TcpConn{
		sock:        net.tcp_socket_from_handle_raw(fd)
		is_blocking: blocking
	}
	conn.set_read_timeout(net.tcp_default_read_timeout)
	conn.set_write_timeout(net.tcp_default_write_timeout)
	transferred = true
	return conn
}

fn (mut session Session) wait_connected(fd int) ! {
	deadline := time.now().add(5 * time.second)
	for {
		if session.stopped() { return error('websocket_connect_cancelled') }
		if time.now() >= deadline { return error('websocket_tcp_connect_timeout') }
		ready := socket_runtime.wait_writable(fd, 20) or { return error('websocket_tcp_poll_failed') }
		if !ready { continue }
		if session.stopped() { return error('websocket_connect_cancelled') }
		socket_error := socket_runtime.connect_error(fd)!
		if socket_error != 0 {
			return error_with_code('websocket_tcp_connect_failed:${socket_error}', socket_error)
		}
		return
	}
}
