module main

fn test_relay_diagnostics_are_bounded_and_do_not_depend_on_disk_logging() {
	mut control := ControlPlaneRuntime{}
	for i in 0 .. 600 {
		control.emit('relay.takeover.execute', {'phase':'completed','execution':'local',
			'status':if i % 2 == 0 { '200' } else { '502' },'request_id':'request-${i}',
			'authorization':'Bearer private','sql':'SELECT private','body':'family-private',
			'token':'private','error':'driver private details'})
	}
	snapshot := control.relay_diagnostics_snapshot()
	assert snapshot.completed == 600
	assert snapshot.failed == 300
	assert snapshot.serial == 600
	assert snapshot.events.len == 256
	assert snapshot.events[0].serial == 345
	for event in snapshot.events {
		assert event.at_ms > 0
		assert event.fields['execution'] == 'local'
		for key in ['authorization','sql','body','token','error'] { assert key !in event.fields }
	}
	control.emit('relay.agent.payload', {'action':'received','request_id':'noise'})
	assert control.relay_diagnostics_snapshot().serial == 600
	control.emit('relay.agent.disconnected', {'relay_id':'edge','last_error':'private'})
	after := control.relay_diagnostics_snapshot()
	assert after.events.len == 256
	assert after.serial == 601
	assert 'last_error' !in after.events.last().fields
}
