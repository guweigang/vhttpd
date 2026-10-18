module process_runtime

import os
import time

fn C.fcntl(int, int, ...voidptr) int

__global (
	signal_test_int_calls int
)

fn signal_test_setter(sig os.Signal, handler os.SignalHandler) !os.SignalHandler {
	assert C.vhttpd_shutdown_signal_fd() == -1
	shutdown_signal_notify(sig)
	if os.args[2] == 'int-failure' { return error('injected_int_failure') }
	if sig == .term { return error('injected_term_failure') }
	unsafe {
		signal_test_int_calls++
		if os.args[2] == 'restore-failure' && signal_test_int_calls == 2 {
			return error('injected_restore_failure')
		}
	}
	return os.signal_opt(sig, handler)
}

fn signal_test_previous_handler(_ os.Signal) {
	exit(82)
}

fn signal_test_handler(sig os.Signal) {
	expected := if os.args[2] == 'int-delivery' { os.Signal.int } else { os.Signal.term }
	if sig == expected { exit(0) }
	exit(81)
}

fn signal_test_open_fds() int {
	mut count := 0
	for fd in 0 .. 1024 {
		if C.fcntl(fd, C.F_GETFD, 0) >= 0 { count++ }
	}
	return count
}

// All handler installation and failure injection runs in executed children;
// the test runner's signal dispositions and process-wide owner stay untouched.
fn testsuite_begin() {
	if os.args.len != 3 || os.args[1] != '--shutdown-signal-probe' { return }
	mode := os.args[2]
	before := signal_test_open_fds()
	if mode.ends_with('failure') {
		os.signal_opt(.int, signal_test_previous_handler) or { panic(err) }
		mut failed := false
		unsafe {
			g_shutdown_signals.install(signal_test_handler, signal_test_setter) or {
				failed = true
				if mode == 'restore-failure' {
					assert err.msg().contains('shutdown_signal_restore_failed')
				} else {
					assert err.msg() == 'injected_${if mode == 'int-failure' {
						'int'
					} else {
						'term'
					}}_failure'
				}
			}
			assert g_shutdown_signals.pipe == none
		}
		assert failed
		assert C.vhttpd_shutdown_signal_fd() == -1
		assert signal_test_open_fds() == before
		previous := os.signal_opt(.int, signal_test_previous_handler) or { panic(err) }
		if mode == 'restore-failure' {
			assert voidptr(previous) == voidptr(shutdown_signal_notify)
		} else {
			assert voidptr(previous) == voidptr(signal_test_previous_handler)
		}
		// Even if rollback failed, a remaining callback cannot target a closed fd.
		victim := C.vhttpd_signal_pipe_create()
		assert victim.read_fd >= 0 && victim.write_fd >= 0
		shutdown_signal_notify(.term)
		assert C.vhttpd_signal_pipe_ready(victim.read_fd, 0) == 0
		C.close(victim.read_fd)
		C.close(victim.write_fd)
		assert signal_test_open_fds() == before
	}
	if mode == 'concurrent-term' {
		done := chan bool{cap: 8}
		for _ in 0 .. 8 {
			spawn fn [done] () {
				install_shutdown_signal_handler(signal_test_handler) or {
					assert err.msg() == 'shutdown_signal_handler_already_installed'
					done <- false
					return
				}
				done <- true
			}()
		}
		mut installed := 0
		for _ in 0 .. 8 { if <-done { installed++ } }
		assert installed == 1
	} else {
		install_shutdown_signal_handler(signal_test_handler) or { panic(err) }
	}
	assert signal_test_open_fds() == before + 2
	unsafe {
		fds := g_shutdown_signals.pipe or { panic('missing owned pipe') }
		assert C.vhttpd_shutdown_signal_fd() == fds.write_fd
		assert C.fcntl(fds.read_fd, C.F_GETFD, 0) & C.FD_CLOEXEC != 0
		assert C.fcntl(fds.write_fd, C.F_GETFD, 0) & C.FD_CLOEXEC != 0
		assert C.fcntl(fds.write_fd, C.F_GETFL, 0) & C.O_NONBLOCK != 0
	}
	mut rejected := false
	install_shutdown_signal_handler(signal_test_handler) or {
		assert err.msg() == 'shutdown_signal_handler_already_installed'
		rejected = true
	}
	assert rejected
	assert signal_test_open_fds() == before + 2
	sig := if mode == 'int-delivery' { os.Signal.int } else { os.Signal.term }
	assert C.kill(os.getpid(), int(sig)) == 0
	time.sleep(3 * time.second)
	exit(80)
}

fn run_signal_probe(mode string) {
	mut child := os.new_process(os.executable())
	child.set_args(['--shutdown-signal-probe', mode])
	child.run()
	child.wait()
	code := child.code
	child.close()
	assert code == 0, 'signal probe ${mode}: exit ${code}'
}

fn test_interrupt_install_failure_closes_candidates_and_allows_retry() {
	run_signal_probe('int-failure')
}

fn test_terminate_install_failure_rolls_back_and_allows_retry() {
	run_signal_probe('term-failure')
}

fn test_rollback_failure_keeps_candidate_unpublished_and_allows_retry() {
	run_signal_probe('restore-failure')
}

fn test_real_interrupt_delivery_and_repeated_install_rejection() {
	run_signal_probe('int-delivery')
}

fn test_concurrent_install_has_one_owner_and_real_terminate_delivery() {
	run_signal_probe('concurrent-term')
}
