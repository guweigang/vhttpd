module protocol_diagnostics

fn test_bounded_diagnostics_keep_counters_and_sanitize_untrusted_methods() {
	mut d := Snapshot{}
	d.failed('decode', 'invalid_protobuf', 'protocol_error')
	d.failed('initialize', 'initialize_timeout', 'transport_error')
	d.unknown('private message with spaces')
	assert d.last_unknown_method == '<invalid-method>'
	assert d.decode_errors == 1 && d.handshake_failures == 1
	d.passed('frame')
	assert d.status == 'passed' && d.decode_errors == 1
	assert safe_method('item/agentMessage/delta') == 'item/agentMessage/delta'
}
