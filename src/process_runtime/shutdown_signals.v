module process_runtime

import os
import sync

$if !windows {
@[typedef]
struct C.vhttpd_signal_pipe {
	read_fd  int
	write_fd int
}

fn C.vhttpd_signal_pipe_create() C.vhttpd_signal_pipe
fn C.vhttpd_signal_pipe_ready(int, int) int
fn C.vhttpd_signal_pipe_notify(int, int)
fn C.vhttpd_shutdown_signal_publish(int)
fn C.vhttpd_shutdown_signal_fd() int
fn C.vhttpd_shutdown_signal_notify(int)
fn C.vhttpd_signal_pipe_wait(int) int
fn C.close(int) int

__global (
	g_shutdown_signals ShutdownSignalOwner
)

// This owner lives until process exit. Once published, the pipe and its waiter
// must remain alive: a signal callback on another thread may still use the fd.
struct ShutdownSignalOwner {
mut:
	mu   sync.Mutex
	pipe ?C.vhttpd_signal_pipe
}

type SignalSetter = fn (os.Signal, os.SignalHandler) !os.SignalHandler

// The actual signal callback never allocates, logs or acquires a V mutex.
fn shutdown_signal_notify(sig os.Signal) {
	C.vhttpd_shutdown_signal_notify(int(sig))
}

fn shutdown_signal_loop(read_fd int, handler fn (os.Signal)) {
	for {
		sig := C.vhttpd_signal_pipe_wait(read_fd)
		if sig < 0 { return }
		handler(unsafe { os.Signal(sig) })
	}
}

fn (mut owner ShutdownSignalOwner) install(handler fn (os.Signal), set_signal SignalSetter) ! {
	owner.mu.@lock()
	defer { owner.mu.unlock() }
	if owner.pipe != none { return error('shutdown_signal_handler_already_installed') }
	fds := C.vhttpd_signal_pipe_create()
	if fds.read_fd < 0 { return error('shutdown_signal_pipe_failed') }
	mut published := false
	defer {
		if !published {
			C.close(fds.read_fd)
			C.close(fds.write_fd)
		}
	}
	former := set_signal(.int, shutdown_signal_notify)!
	set_signal(.term, shutdown_signal_notify) or {
		install_error := err
		set_signal(.int, former) or {
			return error('shutdown_signal_restore_failed: ${err}; install: ${install_error}')
		}
		return install_error
	}
	// Until both handlers are installed, callbacks see -1 and never borrow a
	// candidate pipe. Failure therefore cannot publish a subsequently reused fd.
	owner.pipe = fds
	C.vhttpd_shutdown_signal_publish(fds.write_fd)
	published = true
	spawn shutdown_signal_loop(fds.read_fd, handler)
}

pub fn install_shutdown_signal_handler(handler fn (os.Signal)) ! {
	unsafe { g_shutdown_signals.install(handler, os.signal_opt)! }
}

} $else {
pub fn install_shutdown_signal_handler(handler fn (os.Signal)) ! {
 return error("shutdown_signal_platform_unsupported")
}
}
