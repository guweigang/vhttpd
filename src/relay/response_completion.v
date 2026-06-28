module relay

import dispatch

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
