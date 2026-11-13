module codex

import json2 as json
import net.websocket as ws
import sync

pub struct HandshakeResult {
pub:
	accepted bool
	failure  string
}

// One attempt owns the response correlation. The client address is compared as
// identity only; this object never closes, dereferences or retains a socket.
@[heap]
pub struct Handshake {
	client_identity voidptr
mut:
	mu     sync.Mutex
	result HandshakeResult
pub:
	id int
}

pub fn (mut h Handshake) outcome() HandshakeResult {
	h.mu.@lock()
	defer { h.mu.unlock() }
	return h.result
}

fn (mut h Handshake) settle(result HandshakeResult) {
	h.mu.@lock()
	h.result = result
	h.mu.unlock()
}

fn (s &CodexState) handshake_runtime_unlocked(instance string) ProviderRuntime {
	return if instance == 'main' {
		s.runtime
	} else {
		s.instances[instance] or { s.runtime.for_instance(instance) }
	}
}

fn (mut s CodexState) publish_handshake_runtime_unlocked(instance string, rt ProviderRuntime) {
	if instance == 'main' { s.runtime = rt } else { s.instances[instance] = rt }
}

pub fn (mut s CodexState) begin_handshake(instance string, client_identity voidptr) &Handshake {
	name := ProviderRuntime.normalize_instance(instance)
	s.mu.@lock()
	defer { s.mu.unlock() }
	mut rt := s.handshake_runtime_unlocked(name)
	if mut old := rt.handshake { old.settle(HandshakeResult{ failure: 'superseded' }) }
	h := &Handshake{ id: rt.next_rpc_id(), client_identity: client_identity }
	rt.handshake = h
	rt.initialized = false
	rt.protocol.checking('initialize')
	s.publish_handshake_runtime_unlocked(name, rt)
	return h
}

pub fn (mut s CodexState) accept_handshake_response(instance string, client_identity voidptr, raw string) bool {
	name := ProviderRuntime.normalize_instance(instance)
	cls := RpcFrame.classify(raw)
	if !cls.is_response { return false }
	s.mu.@lock()
	defer { s.mu.unlock() }
	mut rt := s.handshake_runtime_unlocked(name)
	mut h := rt.handshake or { return false }
	if h.client_identity != client_identity || cls.id_raw != h.id.str() { return false }
	previous := h.outcome()
	if previous.accepted || previous.failure != '' { return true }
	mut failure := ''
	mut error_class := 'protocol_error'
	root := json.decode[map[string]json.Any](raw) or { map[string]json.Any{} }
	if 'error' in root {
		failure = 'initialize_rpc_error'
		code := RpcField.raw(RpcField.raw(raw, 'error'), 'code').int()
		if code !in [-32600, -32601, -32602] { error_class = 'provider_error' }
	} else if result := root['result'] {
		if result is map[string]json.Any {
			agent := result['userAgent'] or { json.Any('') }
			if agent !is string || agent.str().trim_space() == '' {
				failure = 'invalid_initialize_result'
			}
		} else {
			failure = 'invalid_initialize_result'
		}
	} else {
		failure = 'invalid_initialize_result'
	}
	if failure == '' {
		h.settle(HandshakeResult{ accepted: true })
	} else {
		h.settle(HandshakeResult{ failure: failure })
		rt.protocol.failed('initialize', failure, error_class)
	}
	s.publish_handshake_runtime_unlocked(name, rt)
	return true
}

pub fn (mut s CodexState) fail_handshake(instance string, expected &Handshake, code string, error_class string) {
	name := ProviderRuntime.normalize_instance(instance)
	s.mu.@lock()
	defer { s.mu.unlock() }
	mut rt := s.handshake_runtime_unlocked(name)
	mut current := rt.handshake or { return }
	if voidptr(current) != voidptr(expected) { return }
	current.settle(HandshakeResult{ failure: code })
	rt.initialized = false
	rt.protocol.failed('initialize', code, error_class)
	s.publish_handshake_runtime_unlocked(name, rt)
}

// Only an accepted response for this exact attempt can publish a usable client.
pub fn (mut s CodexState) finish_handshake(instance string, expected &Handshake, client &ws.Client) bool {
	name := ProviderRuntime.normalize_instance(instance)
	s.mu.@lock()
	defer { s.mu.unlock() }
	mut rt := s.handshake_runtime_unlocked(name)
	mut current := rt.handshake or { return false }
	if voidptr(current) != voidptr(expected) || current.client_identity != voidptr(client) || !rt.connected {
		return false
	}
	if !current.outcome().accepted || current.outcome().failure != '' { return false }
	rt.mark_initialized()
	rt.attach_connection(client)
	rt.protocol.passed('initialize')
	s.publish_handshake_runtime_unlocked(name, rt)
	return true
}
