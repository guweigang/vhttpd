module relay

import dispatch

pub enum ResponseCompletionAction {
	sent
	completed
	failed
	missing
}

pub struct ResponseCompletionOutcome {
pub:
	action      ResponseCompletionAction
	trace_id    string
	channel_id  string
	target_id   string
	frame_id    string
	send_result CarrierSendResult
	delivery    dispatch.DeliveryOutcome
	error       string
	fields      map[string]string
}

pub fn returned_frame_delivery_outcome(frame WireFrame) dispatch.DeliveryOutcome {
	status := response_frame_status(frame)
	metadata := response_frame_metadata(frame)
	if frame.exchange_kind.trim_space().to_lower() == 'error' || frame.kind == .error {
		return dispatch.outcome_with_metadata(dispatch.delivery_failure_outcome(if status > 0 {
			status
		} else {
			500
		}, frame.body, frame.metadata['error_class'] or { 'relay_response_error' }), metadata)
	}
	return dispatch.outcome_with_metadata(dispatch.response_outcome(if status > 0 {
		status
	} else {
		200
	}, frame.headers, frame.body), metadata)
}

pub fn (mut rt Runtime) drain_returned_delivery_for(channel_id string, target_id string) !dispatch.DeliveryOutcome {
	frames := rt.drain_returned_frames_for(channel_id, target_id)!
	if frames.len == 0 {
		return error('relay_returned_frame_not_found:${channel_id}:${target_id}')
	}
	return returned_frame_delivery_outcome(frames[0])
}

pub fn response_completion_sent(outbound OutboundOutcome, send_result CarrierSendResult) ResponseCompletionOutcome {
	mut fields := response_completion_base_fields(outbound.trace_id, outbound.frame.channel_id,
		outbound.frame.id, completion_target_id(outbound.frame))
	merge_response_completion_fields(mut fields, outbound.fields)
	for key, value in carrier_send_event_fields(send_result) {
		fields['carrier_${key}'] = value
	}
	if !send_result.ok {
		return ResponseCompletionOutcome{
			action:      .failed
			trace_id:    outbound.trace_id
			channel_id:  outbound.frame.channel_id
			target_id:   completion_target_id(outbound.frame)
			frame_id:    outbound.frame.id
			send_result: send_result
			error:       send_result.error
			fields:      response_completion_fields_with_action(fields, 'failed')
		}
	}
	return ResponseCompletionOutcome{
		action:      .sent
		trace_id:    outbound.trace_id
		channel_id:  outbound.frame.channel_id
		target_id:   completion_target_id(outbound.frame)
		frame_id:    outbound.frame.id
		send_result: send_result
		fields:      response_completion_fields_with_action(fields, 'sent')
	}
}

pub fn response_completion_from_returned(outbound OutboundOutcome, send_result CarrierSendResult, returned WireFrame) ResponseCompletionOutcome {
	mut fields := response_completion_base_fields(outbound.trace_id, outbound.frame.channel_id,
		outbound.frame.id, frame_response_target_id(returned))
	merge_response_completion_fields(mut fields, outbound.fields)
	for key, value in carrier_send_event_fields(send_result) {
		fields['carrier_${key}'] = value
	}
	fields['returned_frame_id'] = returned.id
	delivery := returned_frame_delivery_outcome(returned)
	error := if delivery.kind == .failure { delivery.error } else { '' }
	return ResponseCompletionOutcome{
		action:      if delivery.kind == .failure {
			ResponseCompletionAction.failed
		} else {
			ResponseCompletionAction.completed
		}
		trace_id:    outbound.trace_id
		channel_id:  outbound.frame.channel_id
		target_id:   frame_response_target_id(returned)
		frame_id:    outbound.frame.id
		send_result: send_result
		delivery:    delivery
		error:       error
		fields:      response_completion_fields_with_action(fields, if delivery.kind == .failure {
			'failed'
		} else {
			'completed'
		})
	}
}

pub fn response_completion_missing(outbound OutboundOutcome, send_result CarrierSendResult) ResponseCompletionOutcome {
	mut fields := response_completion_base_fields(outbound.trace_id, outbound.frame.channel_id,
		outbound.frame.id, completion_target_id(outbound.frame))
	merge_response_completion_fields(mut fields, outbound.fields)
	for key, value in carrier_send_event_fields(send_result) {
		fields['carrier_${key}'] = value
	}
	target_id := completion_target_id(outbound.frame)
	err := 'relay_returned_frame_not_found:${outbound.frame.channel_id}:${target_id}'
	return ResponseCompletionOutcome{
		action:      .missing
		trace_id:    outbound.trace_id
		channel_id:  outbound.frame.channel_id
		target_id:   target_id
		frame_id:    outbound.frame.id
		send_result: send_result
		error:       err
		fields:      response_completion_fields_with_action(fields, 'missing')
	}
}

pub fn response_completion_delivery_outcome(completion ResponseCompletionOutcome) dispatch.DeliveryOutcome {
	match completion.action {
		.completed {
			return dispatch.outcome_with_metadata(completion.delivery,
				response_completion_delivery_metadata(completion))
		}
		.sent {
			return dispatch.accepted_event_outcome(response_completion_delivery_metadata(completion))
		}
		.missing {
			return dispatch.outcome_with_metadata(dispatch.delivery_failure_outcome(504,
				completion.error, 'relay_response_missing'),
				response_completion_delivery_metadata(completion))
		}
		.failed {
			status := if completion.delivery.status > 0 {
				completion.delivery.status
			} else {
				relay_response_completion_failure_status(completion.error)
			}
			error_class := if completion.delivery.error_class != '' {
				completion.delivery.error_class
			} else {
				'relay_response_completion_failed'
			}
			error := if completion.error != '' {
				completion.error
			} else {
				completion.delivery.error
			}
			return dispatch.outcome_with_metadata(dispatch.delivery_failure_outcome(status, error,
				error_class), response_completion_delivery_metadata(completion))
		}
	}
}

fn response_frame_status(frame WireFrame) int {
	status := (frame.metadata['status'] or { '' }).trim_space().int()
	if status > 0 {
		return status
	}
	return (frame.headers['status'] or { '' }).trim_space().int()
}

fn response_frame_metadata(frame WireFrame) map[string]string {
	mut metadata := frame.metadata.clone()
	metadata['trace_id'] = frame.trace_id
	metadata['frame_id'] = frame.id
	metadata['channel_id'] = frame.channel_id
	target_id := frame_response_target_id(frame)
	if target_id != '' {
		metadata['response_to'] = target_id
	}
	return metadata
}

fn response_completion_delivery_metadata(completion ResponseCompletionOutcome) map[string]string {
	mut metadata := completion.fields.clone()
	metadata['trace_id'] = completion.trace_id
	metadata['channel_id'] = completion.channel_id
	metadata['frame_id'] = completion.frame_id
	if completion.target_id != '' {
		metadata['target_id'] = completion.target_id
	}
	if completion.error != '' {
		metadata['error'] = completion.error
	}
	return metadata
}

fn relay_response_completion_failure_status(error string) int {
	if error.contains('not_found') || error.contains('missing') {
		return 504
	}
	if error.contains('not_connected') || error.contains('unavailable')
		|| error.contains('disabled') {
		return 503
	}
	return 500
}

fn response_completion_base_fields(trace_id string, channel_id string, frame_id string, target_id string) map[string]string {
	mut fields := event_fields('response_completion', trace_id, {
		'channel_id': channel_id
		'frame_id':   frame_id
	})
	if target_id != '' {
		fields['target_id'] = target_id
	}
	return fields
}

fn merge_response_completion_fields(mut fields map[string]string, source map[string]string) {
	for key, value in source {
		if key == 'relay_event' {
			fields['outbound_relay_event'] = value
			continue
		}
		if key != '' && value != '' {
			fields[key] = value
		}
	}
}

fn completion_target_id(frame WireFrame) string {
	target_id := frame_response_target_id(frame)
	if target_id != '' {
		return target_id
	}
	return frame.id
}

fn response_completion_fields_with_action(fields map[string]string, action string) map[string]string {
	mut out := fields.clone()
	out['relay_event'] = 'response_completion.${action}'
	out['action'] = action
	return out
}
