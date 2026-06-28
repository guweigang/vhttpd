module relay

import dispatch
import runtime_plan

fn test_returned_frame_delivery_outcome_projects_response() {
	outcome := returned_frame_delivery_outcome(WireFrame{
		version:       wire_version
		kind:          .data
		id:            'relay-response:frm_1'
		trace_id:      'trace_1'
		channel_id:    'chan_1'
		exchange_kind: 'response'
		metadata:      {
			'status': '201'
		}
		headers:       {
			'content-type': 'application/json'
		}
		body:          '{"ok":true}'
	})

	assert outcome.kind == dispatch.DeliveryOutcomeKind.response
	assert outcome.status == 201
	assert outcome.headers['content-type'] == 'application/json'
	assert outcome.body == '{"ok":true}'
	assert outcome.metadata['trace_id'] == 'trace_1'
	assert outcome.metadata['frame_id'] == 'relay-response:frm_1'
	assert outcome.metadata['response_to'] == 'frm_1'
}

fn test_returned_frame_delivery_outcome_projects_error() {
	outcome := returned_frame_delivery_outcome(WireFrame{
		version:       wire_version
		kind:          .error
		id:            'relay-response:frm_2'
		trace_id:      'trace_2'
		channel_id:    'chan_2'
		exchange_kind: 'error'
		metadata:      {
			'status':      '502'
			'error_class': 'relay_upstream_error'
		}
		body:          'bad gateway'
	})

	assert outcome.kind == dispatch.DeliveryOutcomeKind.failure
	assert outcome.status == 502
	assert outcome.error == 'bad gateway'
	assert outcome.error_class == 'relay_upstream_error'
	assert outcome.metadata['response_to'] == 'frm_2'
}

fn test_runtime_drains_returned_delivery_for_target() {
	mut rt := new_runtime(runtime_plan.RuntimePlan{}) or { panic(err) }
	rt.handle_frame(WireFrame{
		version:    wire_version
		kind:       .open
		id:         'frm_open'
		trace_id:   'trace_1'
		channel_id: 'chan_1'
	}, 'node_1', 4)
	rt.handle_frame(WireFrame{
		version:       wire_version
		kind:          .data
		id:            'relay-response:frm_1'
		trace_id:      'trace_1'
		channel_id:    'chan_1'
		exchange_kind: 'response'
		metadata:      {
			'status': '202'
		}
		body:          'accepted'
	}, 'node_1', 4)

	outcome := rt.drain_returned_delivery_for('chan_1', 'frm_1') or { panic(err) }

	assert outcome.kind == dispatch.DeliveryOutcomeKind.response
	assert outcome.status == 202
	assert outcome.body == 'accepted'
	assert rt.snapshot().pending_frames == 0
}

fn test_response_completion_sent_reports_send_state() {
	outbound := OutboundOutcome{
		action:   .ready
		trace_id: 'trace_1'
		frame_id: 'frm_1'
		frame:    WireFrame{
			version:    wire_version
			kind:       .data
			id:         'frm_1'
			trace_id:   'trace_1'
			channel_id: 'chan_1'
		}
	}
	completion := response_completion_sent(outbound, CarrierSendResult{
		ok:       true
		trace_id: 'trace_1'
		frame_id: 'frm_1'
		queued:   true
	})

	assert completion.action == .sent
	assert completion.target_id == 'frm_1'
	assert completion.send_result.queued
	assert completion.fields['relay_event'] == 'response_completion.sent'
	assert completion.fields['carrier_relay_event'] == 'carrier.send'
}

fn test_response_completion_sent_reports_send_failure() {
	outbound := OutboundOutcome{
		action:   .ready
		trace_id: 'trace_1'
		frame_id: 'frm_1'
		frame:    WireFrame{
			version:    wire_version
			kind:       .data
			id:         'frm_1'
			trace_id:   'trace_1'
			channel_id: 'chan_1'
		}
	}
	completion := response_completion_sent(outbound, CarrierSendResult{
		ok:       false
		trace_id: 'trace_1'
		frame_id: 'frm_1'
		error:    'relay_carrier_not_connected:carrier_1'
	})

	assert completion.action == .failed
	assert completion.error == 'relay_carrier_not_connected:carrier_1'
	assert completion.fields['relay_event'] == 'response_completion.failed'
	assert completion.fields['carrier_error'] == 'relay_carrier_not_connected:carrier_1'
}

fn test_response_completion_from_returned_reports_delivery() {
	outbound := OutboundOutcome{
		action:   .ready
		trace_id: 'trace_1'
		frame_id: 'frm_1'
		frame:    WireFrame{
			version:    wire_version
			kind:       .data
			id:         'frm_1'
			trace_id:   'trace_1'
			channel_id: 'chan_1'
		}
	}
	completion := response_completion_from_returned(outbound, CarrierSendResult{
		ok:       true
		trace_id: 'trace_1'
		frame_id: 'frm_1'
	}, WireFrame{
		version:       wire_version
		kind:          .data
		id:            'relay-response:frm_1'
		trace_id:      'trace_1'
		channel_id:    'chan_1'
		exchange_kind: 'response'
		metadata:      {
			'status': '204'
		}
	})

	assert completion.action == .completed
	assert completion.delivery.kind == dispatch.DeliveryOutcomeKind.response
	assert completion.delivery.status == 204
	assert completion.fields['relay_event'] == 'response_completion.completed'
	assert completion.fields['returned_frame_id'] == 'relay-response:frm_1'
}

fn test_response_completion_missing_reports_target() {
	outbound := OutboundOutcome{
		action:   .ready
		trace_id: 'trace_1'
		frame_id: 'frm_1'
		frame:    WireFrame{
			version:    wire_version
			kind:       .data
			id:         'frm_1'
			trace_id:   'trace_1'
			channel_id: 'chan_1'
		}
	}
	completion := response_completion_missing(outbound, CarrierSendResult{
		ok:       true
		trace_id: 'trace_1'
		frame_id: 'frm_1'
	})

	assert completion.action == .missing
	assert completion.target_id == 'frm_1'
	assert completion.error == 'relay_returned_frame_not_found:chan_1:frm_1'
	assert completion.fields['relay_event'] == 'response_completion.missing'
}
