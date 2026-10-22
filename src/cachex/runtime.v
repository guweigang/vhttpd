module cachex

import json2 as json
import net.unix
import net
import listener_runtime
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
	listener_owner  listener_runtime.Owner
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

pub fn (mut rt Runtime) request_stop() ?u64 {
	rt.mu.@lock()
	defer { rt.mu.unlock() }
	generation := rt.listener_owner.request_stop()
	rt.started = false
	return generation
}

pub fn (mut rt Runtime) request_shutdown() ?u64 {
	rt.mu.@lock()
	defer { rt.mu.unlock() }
	generation := rt.listener_owner.request_shutdown()
	rt.started = false
	return generation
}

fn (mut rt Runtime) reserve_start() ?u64 {
	rt.mu.@lock()
	defer { rt.mu.unlock() }
	return rt.listener_owner.reserve()
}

// Reserve before spawning, so a subsequent stop also cancels delayed startup.
pub fn (mut rt Runtime) start(socket_path string) bool {
	if socket_path.trim_space() == '' { return false }
	generation := rt.reserve_start() or { return false }
	spawn rt.run_reserved(socket_path, generation)
	return true
}

pub fn (mut rt Runtime) snapshot_json(ready bool) string {
	rt.mu.@lock()
	defer {
		rt.mu.unlock()
	}
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
	}, escape_unicode: true, time_as_unix: true)
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
	ttl := state_store.ttl_from_milliseconds(ttl_ms) or {
		rt.failed_ops++
		rt.last_error = err.msg()
		return false
	}
	rt.store.set_with_ttl(cache_key, value, ttl) or {
		rt.failed_ops++
		rt.last_error = err.msg()
		return false
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
			ttl := state_store.ttl_from_milliseconds(req.ttl_ms) or { return Response.error(err.msg()) }
			rt.store.set_with_ttl(cache_key, req.value, ttl) or { return Response.error(err.msg()) }
			return Response.ok()
		}
		'patch' {
			swapped := if req.delete_value {
				rt.store.compare_and_swap_delete(cache_key, req.expected_found, req.expected_value) or {
					return Response.error(err.msg())
				}
			} else {
				ttl := state_store.ttl_from_milliseconds(req.ttl_ms) or { return Response.error(err.msg()) }
				rt.store.compare_and_swap_set_with_ttl(cache_key, req.expected_found,
					req.expected_value, req.value, ttl) or {
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

fn Runtime.handle_connection(mut rt Runtime, mut conn unix.StreamConn, generation u64, request u64) {
	defer {
		conn.close() or {}
		rt.listener_owner.complete_request(request)
	}
	payload := FrameCodec.read(mut conn) or { return }
	if !rt.listener_owner.begin_request(generation, request) { return }
	req := json.decode[Request](payload) or {
		FrameCodec.write(mut conn, json.encode(Response.error('invalid_json'),
			escape_unicode: true
			time_as_unix:   true
		)) or {}
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
	FrameCodec.write(mut conn, json.encode(resp, escape_unicode: true, time_as_unix: true)) or {}
}

pub fn (mut rt Runtime) run(socket_path string) {
	if socket_path.trim_space() == '' { return }
	generation := rt.reserve_start() or { return }
	rt.run_reserved(socket_path, generation)
}

fn (mut rt Runtime) run_reserved(socket_path string, generation u64) {
	defer {
		rt.listener_owner.drain_requests(generation)
		rt.mu.@lock()
		if rt.listener_owner.finish(generation) { rt.started = false }
		rt.mu.unlock()
	}
	if rt.listener_owner.should_stop(generation) { return }
	os.mkdir_all(os.dir(socket_path)) or {}
	mut listener := listener_runtime.listen(socket_path) or {
		rt.mu.@lock()
		if !rt.listener_owner.should_stop(generation) { rt.last_error = err.msg() }
		rt.mu.unlock()
		return
	}
	rt.mu.@lock()
	published := rt.listener_owner.publish(generation, listener)
	if published {
		rt.started = true
		rt.started_at_unix = time.now().unix()
		rt.last_error = ''
	}
	rt.mu.unlock()
	if !published {
		// Publication failed: the serving loop still owns this candidate.
		listener.close() or {}
		return
	}
	for !rt.listener_owner.should_stop(generation) {
		mut conn := listener.accept() or {
			if rt.listener_owner.should_stop(generation) { break }
			if err.code() == net.err_timed_out_code { continue }
			rt.mu.@lock()
			rt.last_error = err.msg()
			rt.mu.unlock()
			continue
		}
		if rt.listener_owner.should_stop(generation) { conn.close() or {}; break }
		request := rt.listener_owner.accept_request(generation, conn.sock.handle) or { conn.close() or {}; continue }
		go Runtime.handle_connection(mut rt, mut conn, generation, request)
	}
}
