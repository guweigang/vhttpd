module relay

fn test_disabled_carrier_send_returns_traceable_failure() {
	mut carrier := DisabledCarrier{
		name: 'test'
	}
	result := carrier.send(WireFrame{
		version:    wire_version
		kind:       .data
		id:         'frm_1'
		trace_id:   'trace_1'
		channel_id: 'chan_1'
	})
	fields := carrier_send_event_fields(result)

	assert !result.ok
	assert result.trace_id == 'trace_1'
	assert result.frame_id == 'frm_1'
	assert result.error == 'relay_carrier_disabled:test'
	assert fields['relay_event'] == 'carrier.send_failed'
	assert fields['trace_id'] == 'trace_1'
	assert fields['frame_id'] == 'frm_1'
	assert fields['queued'] == 'false'
}

fn test_disabled_carrier_close_returns_traceable_failure() {
	mut carrier := DisabledCarrier{
		name: 'test'
	}
	result := carrier.close_channel('chan_1', 'trace_1')
	fields := carrier_close_event_fields(result)

	assert !result.ok
	assert result.channel_id == 'chan_1'
	assert result.trace_id == 'trace_1'
	assert result.error == 'relay_carrier_disabled:test'
	assert fields['relay_event'] == 'carrier.close_channel_failed'
	assert fields['trace_id'] == 'trace_1'
	assert fields['channel_id'] == 'chan_1'
}
