module socket_runtime

import net
import time

fn test_retained_alias_outlives_original_and_interrupts_the_same_connection() ! {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0')!
	defer { listener.close() or {} }
	mut client := net.dial_tcp(listener.addr()!.str())!
	defer { client.close() or {} }
	mut accepted := listener.accept()!
	client.set_read_timeout(time.second)
	alias := retain(accepted.sock.handle)!
	defer { net.close(alias) or {} }
	assert alias != accepted.sock.handle
	accepted.close()!
	// Closing the original must not close the shared connection.
	client.write_string('still connected')!
	net.shutdown(alias)
	mut buffer := [32]u8{}
	count := client.read(mut buffer) or {
		assert !err.msg().contains('timed out'), err.msg()
		return
	}
	assert count == 0, 'shutdown of the retained alias did not wake the reader'
}

fn test_failed_duplicate_does_not_publish_a_handle() {
	duplicate(-1) or { return }
	assert false, 'invalid descriptor retained'
}
