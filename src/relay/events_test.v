module relay

fn test_forwarding_event_fields_include_trace_and_error() {
	fields := forwarding_event_fields(ForwardingOutcome{
		action:     .rejected
		channel_id: 'chan_1'
		trace_id:   'trace_1'
		frame_id:   'frm_1'
		error:      'relay_channel_buffer_full:chan_1'
	})

	assert fields['relay_event'] == 'forward.rejected'
	assert fields['trace_id'] == 'trace_1'
	assert fields['channel_id'] == 'chan_1'
	assert fields['frame_id'] == 'frm_1'
	assert fields['error'] == 'relay_channel_buffer_full:chan_1'
	assert 'correlation_id' !in fields
}

fn test_session_route_event_fields_include_counts_without_provider_policy() {
	fields := session_route_event_fields(SessionRouteOutcome{
		action:       .deliver
		session_id:   'session_1'
		link_id:      'link_1'
		source_id:    'ep_1'
		target_ids:   ['ep_2', 'ep_3']
		buffered_len: 0
		trace_id:     'trace_1'
		frame_id:     'frm_1'
	})

	assert fields['relay_event'] == 'session_route.deliver'
	assert fields['trace_id'] == 'trace_1'
	assert fields['session_id'] == 'session_1'
	assert fields['link_id'] == 'link_1'
	assert fields['source_id'] == 'ep_1'
	assert fields['target_count'] == '2'
	assert fields['buffered_len'] == '0'
	assert 'error' !in fields
}

fn test_registration_event_fields_show_accept_or_reject() {
	accepted := registration_event_fields(RegistrationResult{
		accepted: true
		node_id:  'node_1'
		relay_id: 'relay_1'
		trace_id: 'trace_1'
	})
	rejected := registration_event_fields(RegistrationResult{
		accepted:       false
		node_id:        'node_1'
		relay_id:       'relay_1'
		trace_id:       'trace_2'
		error:          'unauthorized'
		retry_after_ms: 250
	})

	assert accepted['relay_event'] == 'registration.accepted'
	assert accepted['trace_id'] == 'trace_1'
	assert 'error' !in accepted
	assert rejected['relay_event'] == 'registration.rejected'
	assert rejected['trace_id'] == 'trace_2'
	assert rejected['error'] == 'unauthorized'
	assert rejected['retry_after_ms'] == '250'
}

fn test_agent_state_event_fields_include_retry_state() {
	fields := agent_state_event_fields(AgentState{
		node_id:            'node_1'
		relay_id:           'relay_1'
		state:              .backoff
		attempt:            2
		next_attempt_at_ms: 1200
		last_error:         'dial_failed'
	})

	assert fields['relay_event'] == 'agent.backoff'
	assert fields['node_id'] == 'node_1'
	assert fields['relay_id'] == 'relay_1'
	assert fields['attempt'] == '2'
	assert fields['next_attempt_at_ms'] == '1200'
	assert fields['last_error'] == 'dial_failed'
}
