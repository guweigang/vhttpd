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
