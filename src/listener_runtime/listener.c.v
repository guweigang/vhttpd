module listener_runtime

import net
import net.unix
import os
import sync
import time

// The SDK listener unlinks before bind and on close. Keep pathname ownership
// here instead: bind must fail on an existing entry, including a stale socket.
@[heap]
pub struct Listener {
	path     string
	identity os.Stat
mut:
	mu     sync.Mutex
	closed bool
	native &unix.StreamListener @[required]
}

pub fn listen(path string) !&Listener {
	// Match net.unix's portable pathname limit, including the terminating NUL.
	if path.len == 0 || path.len >= 104 || path.contains('\x00') {
		return error('invalid Unix listener path')
	}
	// Darwin bind follows a dangling symlink; exists() would miss that entry.
	if _ := os.lstat(path) { return error('listener path already exists: ${path}') }
	addresses := net.resolve_addrs(path, .unix, .tcp)!
	address := addresses[0]
	fd := net.socket_error(C.socket(i32(net.AddrFamily.unix), i32(net.SocketType.tcp), 0))!
	mut bound := false
	mut ready := false
	mut identity := os.Stat{}
	defer {
		if !ready {
			net.close(fd) or {}
			if bound { remove_owned_path(path, identity) }
		}
	}
	net.socket_error_message(C.fcntl(fd, C.F_SETFD, C.FD_CLOEXEC), 'setting listener close-on-exec failed')!
	net.socket_error_message(C.bind(fd, voidptr(&address), address.len()), 'binding to ${path} failed')!
	// Capture the directory entry before publishing this generation.
	identity = os.lstat(path)!
	bound = true
	net.socket_error_message(C.listen(fd, 128), 'listening on ${path} failed')!
	net.set_blocking(fd, false)!
	mut native := &unix.StreamListener{ sock: unix.StreamSocket{ handle: fd } }
	native.set_accept_deadline(time.unix(0))
	native.set_accept_timeout(100 * time.millisecond)
	ready = true
	return &Listener{ path: path, identity: identity, native: native }
}

fn remove_owned_path(path string, identity os.Stat) {
	current := os.lstat(path) or { return }
	if current.get_filetype() == .socket && current.dev == identity.dev && current.inode == identity.inode {
		os.rm(path) or {}
	}
}

pub fn (mut listener Listener) accept() !&unix.StreamConn {
	mut conn := listener.native.accept()!
	// The handler owns this fd. Exec'd workers must not extend its lifetime.
	// Match the listener and stop-interrupt duplicate before publishing it.
	net.socket_error_message(C.fcntl(i32(conn.sock.handle), C.F_SETFD, C.FD_CLOEXEC),
		'setting accepted connection close-on-exec failed') or {
		conn.close() or {}
		return err
	}
	return conn
}

// Only the serving scope closes the native handle, after draining requests.
// Idempotence also prevents a repeated close from touching a recycled fd.
pub fn (mut listener Listener) close() ! {
	listener.mu.@lock()
	defer { listener.mu.unlock() }
	if listener.closed { return }
	listener.closed = true
	defer { remove_owned_path(listener.path, listener.identity) }
	net.close(listener.native.sock.handle)!
}
