module main

import executor
import worker
import upstream.transport
import net.unix
import time

fn origin_pool(path string, cgi bool, inflight i64) &worker.WorkerState {
	mut state := &worker.WorkerState{
		worker_backend: worker.WorkerBackendRuntime{
			autostart:       true
			sockets:         [path]
			read_timeout_ms: 1000
			env:             {
				'DOCUMENT_ROOT': 'original-root'
			}
			managed_workers: [transport.ManagedWorker{
				id:                1
				socket_path:       path
				inflight_requests: inflight
				next_retry_ts:     time.now().unix_milli() + 60000
			}]
		}
	}
	if cgi { state.logic_executor = executor.PhpCgiExecutor{} }
	return state
}

fn origin_wait(done chan bool) {
	select {
		_ := <-done {
		}
		3 * time.second {
			assert false, 'origin fixture timed out'
		}
	}
}

fn origin_peer(mut listener unix.StreamListener, cgi bool, stream bool, entered chan bool, release chan bool, done chan bool) {
	mut peer := listener.accept() or { panic(err) }
	defer {
		peer.close() or {}
		done <- true
	}
	if cgi {
		for {
			header := worker.WorkerBackendFrameCodec.read_exact(mut peer, 8) or { panic(err) }
			length := (int(header[4]) << 8) | int(header[5])
			if length + int(header[6]) > 0 {
				_ := worker.WorkerBackendFrameCodec.read_exact(mut peer, length + int(header[6])) or { panic(err) }
			}
			if header[1] == 5 && length == 0 { break }
		}
	} else {
		_ := worker.WorkerBackendFrameCodec.read(mut peer) or { panic(err) }
	}
	entered <- true
	_ := <-release
	if cgi {
		body := 'Status: 200 OK\r\nContent-Type: text/plain\r\n\r\noriginal'
		out := transport.FastCgiRecord{ @type: 6, content_length: u16(body.len), content: body.bytes() }.encode()
		peer.write(out) or { panic(err) }
		peer.write(transport.FastCgiRecord{ @type: 3, content_length: 8, content: []u8{len: 8} }.encode()) or { panic(err) }
	} else {
		payload := if stream {
			'{"mode":"stream","event":"start","stream_type":"text","status":200}'
		} else {
			'{"status":200,"body":"original"}'
		}
		worker.WorkerBackendFrameCodec.write(mut peer, payload) or { panic(err) }
	}
}

