module relay

fn decode_first_wire_frame(ready chan bool, start chan bool, results chan bool) {
	ready <- true
	_ := <-start
	frame := decode_frame('{"version":1,"kind":"hello","id":"cold-hello","trace_id":"cold-trace","headers":{"authorization":"Bearer test"},"metadata":{"node_id":"cold-node","relay_id":"edge","mode":"agent","carrier":"websocket"}}') or {
		results <- false
		return
	}
	results <- (frame.id == 'cold-hello' && frame.trace_id == 'cold-trace'
		&& frame.headers['authorization'] == 'Bearer test'
		&& frame.metadata['node_id'] == 'cold-node')
}

fn test_concurrent_first_wire_decode_publishes_complete_field_metadata() {
	// Keep this in its own test binary: no earlier decode may warm the cache.
	count := 64
	ready := chan bool{cap: count}
	start := chan bool{}
	results := chan bool{cap: count}
	for _ in 0 .. count {
		spawn decode_first_wire_frame(ready, start, results)
	}
	for _ in 0 .. count {
		assert <-ready
	}
	start.close()
	for _ in 0 .. count {
		assert <-results
	}
}
