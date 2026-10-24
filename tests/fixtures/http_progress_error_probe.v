module main

import io
import net
import net.http
import time

struct CallbackAbort {
	token string
}

fn (err CallbackAbort) msg() string { return err.token }

fn (_ CallbackAbort) code() int { return 7331 }

@[heap]
struct CallbackProbe {
mut:
	calls int
}

struct CallbackResult {
	token string
	code  int
}

fn read_head(mut conn net.TcpConn) {
	mut raw := ''
	mut buffer := []u8{len: 4096}
	for !raw.contains('\r\n\r\n') {
		n := conn.read(mut buffer) or { panic(err) }
		assert n > 0
		raw += buffer[..n].bytestr()
	}
}

fn exercise_callback_abort(method http.Method, warm bool, raw_callback bool, direct bool) {
	http.close_idle_connections()
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	address := listener.addr() or { panic(err) }
	ready := chan bool{cap: 1}
	release := chan bool{cap: 1}
	closed := chan bool{cap: 1}
	worker := spawn fn [mut listener, warm, ready, release, closed] () {
		defer { listener.close() or {} }
		mut conn := listener.accept() or { panic(err) }
		defer { conn.close() or {} }
		conn.set_read_timeout(time.second)
		if warm {
			read_head(mut conn)
			conn.write_string('HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n') or { panic(err) }
		}
		read_head(mut conn)
		conn.write_string('HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n4\r\ndata\r\n') or { panic(err) }
		ready <- true
		_ := <-release
		mut buffer := []u8{len: 1}
		mut eof := false
		n := conn.read(mut buffer) or {
			eof = err is io.Eof
			-1
		}
		closed <- (eof || n == 0)
	}()
	url := 'http://${address}/probe'
	if warm { http.get(url) or { panic(err) } }
	mut probe := &CallbackProbe{}
	done := chan CallbackResult{cap: 1}
	client := spawn fn [url, method, raw_callback, direct, mut probe, done] () {
		mut cfg := http.FetchConfig{ url: url, method: method, disable_connection_reuse: direct }
		if raw_callback {
			cfg.on_progress = fn [mut probe] (_ &http.Request, _ []u8, _ u64) ! {
				probe.calls++
				return CallbackAbort{ token: 'owned-abort' }
			}
		} else {
			cfg.on_progress_body = fn [mut probe] (_ &http.Request, chunk []u8, _ u64, _ u64, _ int) ! {
				if chunk.len == 0 { return }
				probe.calls++
				return CallbackAbort{ token: 'owned-abort' }
			}
		}
		http.fetch(cfg) or {
			done <- CallbackResult{ token: if err is CallbackAbort { err.token } else { err.msg() }, code: err.code() }
			// A different error with identical text must not satisfy type preservation.
			assert err is CallbackAbort
			return
		}
		done <- CallbackResult{ token: 'unexpected success' }
	}()
	select {
		_ := <-ready {
		}
		3 * time.second {
			panic('origin readiness deadline')
		}
	}
	mut prompt := false
	mut result := CallbackResult{}
	select {
		value := <-done {
			prompt = true
			result = value
		}
		300 * time.millisecond {
		}
	}
	release <- true
	peer_closed := <-closed
	if !prompt { result = <-done }
	client.wait()
	worker.wait()
	assert prompt, 'callback abort replayed or retained the HTTP request'
	assert result.token == 'owned-abort'
	assert result.code == 7331
	assert probe.calls == 1
	assert peer_closed, 'callback abort leaked the upstream descriptor'
}

fn main() {
	mut cases := 0
	for method in [http.Method.get, http.Method.post] {
		for raw_callback in [false, true] {
			for mode in ['fresh', 'reused', 'direct'] {
				exercise_callback_abort(method, mode == 'reused', raw_callback, mode == 'direct')
				cases++
			}
		}
	}
	println('PASS: ${cases} HTTP callback abort ownership cases')
}
