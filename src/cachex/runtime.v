module cachex

import json
import net.unix
import os
import state_store
import sync
import time

pub struct Snapshot {
pub:
	enabled          bool
	socket           string
	started          bool
	started_at_unix  i64
	last_error       string
	total_ops        u64
	failed_ops       u64
	keys             int
	ready            bool
	snapshot_at_unix i64
}

pub struct Runtime {
pub mut:
	enabled         bool
	socket          string
	started         bool
	started_at_unix i64
	last_error      string
	total_ops       u64
	failed_ops      u64
	stop_requested  bool
	listener        &unix.StreamListener = unsafe { nil }
	mu              sync.Mutex
	store           state_store.MemoryStateStore[string]
}

pub struct Request {
pub:
	version        int
	mode           string
	op             string
	namespace      string
	key            string
	value          string
	expected_value string @[json: 'expected_value']
	expected_found bool   @[json: 'expected_found']
	delete_value   bool   @[json: 'delete_value']
	ttl_ms         i64    @[json: 'ttl_ms']
}

pub struct Response {
pub:
	ok       bool
	found    bool
	conflict bool
	value    string
	keys     []string
	error    string
	pong     bool
}

pub fn Runtime.new(enabled bool, socket string) Runtime {
	return Runtime{
		enabled: enabled
		socket:  if socket.trim_space() != '' { socket } else { 'tmp/vhttpd-cache.sock' }
		store:   state_store.MemoryStateStore.new[string]()
	}
}

pub fn (mut rt Runtime) request_stop() &unix.StreamListener {
	rt.stop_requested = true
	listener := rt.listener
	rt.started = false
	return listener
}

pub fn (mut rt Runtime) snapshot_json(ready bool) string {
	return json.encode(Snapshot{
		enabled:          rt.enabled
		socket:           rt.socket
		started:          rt.started
		started_at_unix:  rt.started_at_unix
		last_error:       rt.last_error
		total_ops:        rt.total_ops
		failed_ops:       rt.failed_ops
		keys:             rt.store.keys().len
		ready:            ready
		snapshot_at_unix: time.now().unix()
	})
}

pub fn (mut rt Runtime) get_value(namespace string, key string) ?string {
	if !rt.enabled {
		return none
	}
	cache_key := full_key(namespace, key)
	rt.mu.@lock()
	defer {
		rt.mu.unlock()
	}
	return rt.store.get(cache_key) or { none }
}

pub fn (mut rt Runtime) set_value(namespace string, key string, value string, ttl_ms i64) bool {
	if !rt.enabled {
		return false
	}
	cache_key := full_key(namespace, key)
	rt.mu.@lock()
	defer {
		rt.mu.unlock()
	}
	if ttl_ms > 0 {
		rt.store.set_with_ttl(cache_key, value, ttl_ms * time.millisecond) or {
			rt.failed_ops++
			rt.last_error = err.msg()
			return false
		}
	} else {
		rt.store.set(cache_key, value) or {
			rt.failed_ops++
			rt.last_error = err.msg()
			return false
		}
	}
	rt.total_ops++
	return true
}

pub fn Response.ok() Response {
	return Response{
		ok: true
	}
}

pub fn Response.error(message string) Response {
	return Response{
		error: message
	}
}

pub fn Response.pong() Response {
	return Response{
		ok:   true
		pong: true
	}
}

pub struct FrameCodec {}

fn FrameCodec.write(mut conn unix.StreamConn, payload string) ! {
	size := payload.len
	header := [u8((size >> 24) & 0xff), u8((size >> 16) & 0xff), u8((size >> 8) & 0xff),
		u8(size & 0xff)]
	conn.write_ptr(&header[0], 4)!
	conn.write_string(payload)!
}

fn FrameCodec.read_exact(mut conn unix.StreamConn, size int) ![]u8 {
	mut out := []u8{len: size}
	mut read := 0
	for read < size {
		n := conn.read(mut out[read..])!
		if n <= 0 {
			return error('unexpected EOF')
		}
		read += n
	}
	return out
}

fn FrameCodec.read(mut conn unix.StreamConn) !string {
	header := FrameCodec.read_exact(mut conn, 4)!
	size_u32 := (u32(header[0]) << 24) | (u32(header[1]) << 16) | (u32(header[2]) << 8) | u32(header[3])
	size := int(size_u32)
	if size <= 0 || size > 16 * 1024 * 1024 {
		return error('invalid frame size ${size}')
	}
	body := FrameCodec.read_exact(mut conn, size)!
	return body.bytestr()
}

fn full_key(namespace string, key string) string {
	ns := namespace.trim_space()
	return '${ns}:${key.trim_space()}'
}

fn (mut rt Runtime) dispatch(req Request) Response {
	if req.mode != '' && req.mode != 'cache' && req.mode != 'session_store' {
		return Response.error('invalid_mode')
	}
	namespace := req.namespace.trim_space()
	key := req.key.trim_space()
	if namespace == '' {
		return Response.error('cache_namespace_missing')
	}
	if key == '' && req.op != 'keys' && req.op != 'ping' {
		return Response.error('cache_key_missing')
	}
	cache_key := full_key(namespace, key)
	match req.op {
		'ping' {
			return Response.pong()
		}
		'get' {
			value := rt.store.get(cache_key) or {
				return Response{
					ok:    true
					found: false
				}
			}
			return Response{
				ok:    true
				found: true
				value: value
			}
		}
		'set' {
			if req.ttl_ms > 0 {
				rt.store.set_with_ttl(cache_key, req.value, req.ttl_ms * time.millisecond) or {
					return Response.error(err.msg())
				}
			} else {
				rt.store.set(cache_key, req.value) or { return Response.error(err.msg()) }
			}
			return Response.ok()
		}
		'patch' {
			swapped := if req.delete_value {
				rt.store.compare_and_swap_delete(cache_key, req.expected_found, req.expected_value) or {
					return Response.error(err.msg())
				}
			} else {
				rt.store.compare_and_swap_set_with_ttl(cache_key, req.expected_found,
					req.expected_value, req.value, req.ttl_ms * time.millisecond) or {
					return Response.error(err.msg())
				}
			}
			if !swapped {
				return Response{
					ok:       false
					conflict: true
				}
			}
			return Response.ok()
		}
		'delete' {
			rt.store.delete(cache_key) or { return Response.error(err.msg()) }
			return Response.ok()
		}
		'exists' {
			return Response{
				ok:    true
				found: rt.store.exists(cache_key)
			}
		}
		'keys' {
			prefix := '${namespace}:'
			keys := rt.store.keys().filter(it.starts_with(prefix)).map(it[prefix.len..])
			return Response{
				ok:    true
				found: keys.len > 0
				keys:  keys
			}
		}
		else {
			return Response.error('unsupported_cache_op:${req.op}')
		}
	}
}

fn Runtime.handle_connection(mut rt Runtime, mut conn unix.StreamConn) {
	defer {
		conn.close() or {}
	}
	payload := FrameCodec.read(mut conn) or { return }
	req := json.decode(Request, payload) or {
		FrameCodec.write(mut conn, json.encode(Response.error('invalid_json'))) or {}
		return
	}
	rt.mu.@lock()
	resp := rt.dispatch(req)
	if resp.ok {
		rt.total_ops++
	} else {
		rt.failed_ops++
		rt.last_error = resp.error
	}
	rt.mu.unlock()
	FrameCodec.write(mut conn, json.encode(resp)) or {}
}

pub fn (mut rt Runtime) run(socket_path string) {
	if socket_path.trim_space() == '' {
		return
	}
	os.mkdir_all(os.dir(socket_path)) or {}
	if os.exists(socket_path) {
		os.rm(socket_path) or {}
	}
	mut listener := unix.listen_stream(socket_path) or {
		rt.mu.@lock()
		rt.last_error = err.msg()
		rt.mu.unlock()
		return
	}
	rt.mu.@lock()
	rt.listener = listener
	rt.started = true
	rt.started_at_unix = time.now().unix()
	rt.last_error = ''
	rt.mu.unlock()
	defer {
		rt.mu.@lock()
		rt.started = false
		rt.listener = unsafe { nil }
		rt.mu.unlock()
	}
	for {
		mut conn := listener.accept() or {
			rt.mu.@lock()
			should_stop := rt.stop_requested
			if !should_stop {
				rt.last_error = err.msg()
			}
			rt.mu.unlock()
			if should_stop {
				break
			}
			continue
		}
		go Runtime.handle_connection(mut rt, mut conn)
	}
}
