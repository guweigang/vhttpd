module main

import json2 as json
import sync.stdatomic
import time

struct Gate {
mut:
	open u64
}

enum Kind {
	hello
	hello_ack
}

struct Frame {
	version        int
	kind           Kind
	id             string
	request_id     string
	trace_id       string
	parent_id      string
	channel_id     string
	correlation_id string
	route          string
	exchange_kind  string
	metadata       map[string]string
	headers        map[string]string
	body           string
}

struct Fixture {
	gate  &Gate
	ready chan bool
}

fn decode_worker(fixture Fixture) string {
	mut gate := fixture.gate
	ready := fixture.ready
	ready <- true
	for stdatomic.load_u64(&gate.open) == 0 { time.sleep(time.microsecond) }
	raw := '{"version":1,"kind":"hello","id":"hello-0","request_id":"req","trace_id":"trace","parent_id":"parent","channel_id":"channel","correlation_id":"correlation","route":"route","exchange_kind":"request","metadata":{"node_id":"agent-after","relay_id":"edge","mode":"agent","carrier":"websocket","max_channels":"1024"},"headers":{"authorization":"Bearer test"},"body":"body"}'
	for _ in 0 .. 10 {
		frame := json.decode[Frame](raw) or { return err.msg() }
		if frame.version != 1 || frame.id != 'hello-0' || frame.metadata['relay_id'] != 'edge' || frame.body != 'body' {
			return 'wrong fields: ${frame}'
		}
	}
	return ''
}

fn main() {
	mut gate := &Gate{}
	ready := chan bool{cap: 8}
	mut workers := []thread string{}
	fixture := Fixture{ gate: gate, ready: ready }
	for _ in 0 .. 8 { workers << spawn decode_worker(fixture) }
	for _ in 0 .. 8 {
		assert <-ready
	}
	eprintln('ready')
	stdatomic.store_u64(&gate.open, 1)
	eprintln('released')
	mut failures := 0
	for worker in workers {
		result := worker.wait()
		if result != '' {
			eprintln(result)
			failures++
		}
	}
	if failures > 0 { exit(1) }
}
