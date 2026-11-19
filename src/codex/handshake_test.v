module codex

import net.websocket as ws

fn test_handshake_correlates_exact_attempt_and_requires_response_before_ready() {
	mut state := CodexState{}
	mut client := &ws.Client{}
	state.runtime.connected = true
	mut owner := state.begin_handshake('main', voidptr(client))
	assert !state.finish_handshake('main', owner, client)
	assert !state.accept_handshake_response('main', voidptr(client), '{"id":999,"result":{"userAgent":"test"}}')
	assert !state.accept_handshake_response('main', voidptr(client), '{"id":"${owner.id}","result":{"userAgent":"test"}}')
	assert !owner.outcome().accepted
	assert state.accept_handshake_response('main', voidptr(client), '{"id":${owner.id},"result":{"userAgent":"test","future":true}}')
	assert !state.snapshot('main').initialized
	assert state.finish_handshake('main', owner, client)
	assert state.snapshot('main').initialized
	assert state.snapshot('main').protocol.status == 'passed'
}

fn test_handshake_replacement_and_timeout_cannot_publish_old_client() {
	mut state := CodexState{}
	mut client := &ws.Client{}
	state.runtime.connected = true
	mut old := state.begin_handshake('main', voidptr(client))
	mut next := state.begin_handshake('main', voidptr(client))
	assert old.outcome().failure == 'superseded'
	assert !state.accept_handshake_response('main', voidptr(client), '{"id":${old.id},"result":{"userAgent":"test"}}')
	state.fail_handshake('main', old, 'stale_timeout', 'transport_error')
	assert next.outcome().failure == ''
	state.fail_handshake('main', next, 'initialize_timeout', 'transport_error')
	assert !state.finish_handshake('main', next, client)
	assert state.snapshot('main').protocol.code == 'initialize_timeout'
}

fn test_handshake_rejects_invalid_results_and_distinguishes_rpc_errors() {
	for body, expected in {
		'{"result":{}}':                                 'invalid_initialize_result'
		'{"error":{"code":-32601,"message":"private"}}': 'initialize_rpc_error'
	} {
		mut state := CodexState{}
		mut owner := state.begin_handshake('main', voidptr(123))
		assert state.accept_handshake_response('main', voidptr(123), '{"id":${owner.id},${body[1..]}')
		assert owner.outcome().failure == expected
		assert state.snapshot('main').protocol.error_class == 'protocol_error'
	}
}

fn test_rpc_envelopes_tolerate_unknown_methods_and_reject_ambiguous_or_malformed_frames() {
	assert RpcFrame.classify('{"method":"future/new","params":{"id":42}}').is_notification
	assert RpcFrame.classify('{"id":"abc","method":"future/new","params":{}}').is_request
	for raw in ['{"method":42}', '{"id":1,"result":{},"error":{}}', '{"method":"x",', '[]',
		'{"id":{},"result":{}}'] {
		cls := RpcFrame.classify(raw)
		assert !cls.is_response && !cls.is_request && !cls.is_notification
	}
}

fn test_rpc_ids_do_not_round_through_floating_point_or_pick_nested_ids() {
	assert RpcFrame.classify('{"params":{"id":7},"id":9223372036854775807,"method":"future/request"}').id_raw == '9223372036854775807'
	assert RpcFrame.classify('{"result":{"id":7},"id":-9223372036854775807}').id_raw == '-9223372036854775807'
}
