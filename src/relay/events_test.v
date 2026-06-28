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

fn test_response_completion_event_fields_include_delivery_state() {
	fields := response_completion_event_fields(ResponseCompletionOutcome{
		action:     .completed
		trace_id:   'trace_1'
		channel_id: 'chan_1'
		target_id:  'frm_1'
		frame_id:   'frm_1'
		delivery:   returned_frame_delivery_outcome(WireFrame{
			version:       wire_version
			kind:          .data
			id:            'relay-response:frm_1'
			trace_id:      'trace_1'
			channel_id:    'chan_1'
			exchange_kind: 'response'
			metadata:      {
				'status': '203'
			}
			body:          'ok'
		})
		fields:     {
			'carrier_relay_event': 'carrier.send'
		}
	})

	assert fields['relay_event'] == 'response_completion.completed'
	assert fields['action'] == 'completed'
	assert fields['trace_id'] == 'trace_1'
	assert fields['channel_id'] == 'chan_1'
	assert fields['frame_id'] == 'frm_1'
	assert fields['target_id'] == 'frm_1'
	assert fields['delivery_kind'] == 'response'
	assert fields['status'] == '203'
	assert fields['carrier_relay_event'] == 'carrier.send'
}

fn test_response_completion_event_fields_include_error_state() {
	fields := response_completion_event_fields(ResponseCompletionOutcome{
		action:     .failed
		trace_id:   'trace_1'
		channel_id: 'chan_1'
		target_id:  'frm_1'
		frame_id:   'frm_1'
		error:      'boom'
		delivery:   returned_frame_delivery_outcome(WireFrame{
			version:       wire_version
			kind:          .error
			id:            'relay-response:frm_1'
			trace_id:      'trace_1'
			channel_id:    'chan_1'
			exchange_kind: 'error'
			metadata:      {
				'status':      '502'
				'error_class': 'relay_upstream_error'
			}
			body:          'boom'
		})
	})

	assert fields['relay_event'] == 'response_completion.failed'
	assert fields['action'] == 'failed'
	assert fields['delivery_kind'] == 'failure'
	assert fields['status'] == '502'
	assert fields['error'] == 'boom'
	assert fields['error_class'] == 'relay_upstream_error'
}
