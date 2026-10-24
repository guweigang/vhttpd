module relay

fn test_connection_probe_authenticates_without_registration() {
	descriptor := RelayDescriptor{ id: 'hub', token: 'private' }
	hello := registration_hello_frame(RegistrationRequest{ node_id: 'probe', relay_id: 'hub', mode: .agent, carrier: 'websocket', token: 'private', trace_id: 'trace', max_channels: 1 })!
	probe := WireFrame{
		...hello
		kind:     .ping
		metadata: {
			...hello.metadata
			'purpose': 'connection-test-v1'
		}
	}
	mut runtime := empty_runtime()
	runtime.carriers.register('hub', 'existing-business')!
	before := runtime.snapshot().carriers
	// Legacy ping handling also leaves business registration untouched.
	ignored := runtime.handle_inbound_frame('temporary-probe', probe, 64)
	assert ignored.action == .ignored
	ack := connection_probe_ack(probe, descriptor)!
	assert runtime.snapshot().carriers == before
	assert ack.kind == .pong
	assert ack.metadata['purpose'] == 'connection-test-v1'
	assert ack.metadata['relay_id'] == 'hub'
	assert !encode_frame(ack)!.contains('private')
	for bad in [WireFrame{ ...probe, headers: {} }, WireFrame{
		...probe
		metadata: {
			...probe.metadata
			'relay_id': 'other'
		}
	}, hello] {
		connection_probe_ack(bad, descriptor) or { continue }
		assert false, 'invalid probe accepted'
	}
}
