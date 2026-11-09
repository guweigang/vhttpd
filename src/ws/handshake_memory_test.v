module ws

import net
import time

#include "@VMODROOT/src/ws/handshake_native_test.h"

fn C.vhttpd_test_allocator_in_use() u64

fn handshake_memory_batch(count int, verify_release bool) ! {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	defer { listener.close() or {} }
	address := listener.addr()!.str()
	for _ in 0 .. count {
		mut peer := net.dial_tcp(address)!
		peer.set_read_timeout(time.second)
		mut conn := listener.accept()!
		conn.set_read_timeout(time.second)
		// The HTTP layer has already consumed the upgrade request. Queue a
		// masked normal-close frame for the upgraded reader.
		peer.write([u8(0x88), 0x82, 1, 2, 3, 4, 2, 234])!
		mut server, captured := managed_server()
		managed_handshake(mut server, mut conn, 'dGhlIHNhbXBsZSBub25jZQ==', captured) or {}
		mut response := []u8{len: 1024}
		n := peer.read(mut response)!
		if !response[..n].bytestr().contains('101 Switching Protocols') {
			panic('Handshake did not return an upgrade response')
		}
		peer.close() or {}
		if verify_release {
			if captured.client != none { panic('Handshake capture retained a client') }
		}
	}
	time.sleep(20 * time.millisecond)
}

fn test_completed_handshakes_release_clients_and_native_accept_callbacks() ! {
	handshake_memory_batch(16, false)!
	gc_collect()
	before := gc_memory_use()
	before_native := C.vhttpd_test_allocator_in_use()
	// Include enough connections to catch small uncollectable shared wrappers.
	handshake_memory_batch(4096, false)!
	gc_collect()
	after := gc_memory_use()
	after_native := C.vhttpd_test_allocator_in_use()
	// Production builds remove asserts; keep resource gates active in that mode.
	if gc_is_enabled() && after > before + 1024 * 1024 {
		panic('Completed handshakes retained clients: ${before} -> ${after}')
	}
	if before_native != 0 && after_native > before_native + 2 * 1024 * 1024 {
		panic('Terminal handshakes retained native TLS allocations: ${before_native} -> ${after_native}')
	}
}

fn handshake_memory_parallel(done chan bool) {
	handshake_memory_batch(16, true) or {
		done <- false
		return
	}
	done <- true
}

fn test_handshake_capture_is_cleared_and_parallel_threads_are_isolated() {
	done := chan bool{cap: 2}
	spawn handshake_memory_parallel(done)
	spawn handshake_memory_parallel(done)
	first := <-done
	second := <-done
	if !first || !second { panic('Parallel handshake cleanup failed') }
}
