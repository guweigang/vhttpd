module relay

import dispatch

pub enum OutboundAction {
	ready
	unavailable
	rejected
}

pub struct OutboundOutcome {
pub:
	action     OutboundAction
	relay_id   string
	carrier_id string
	trace_id   string
	frame_id   string
	frame      WireFrame
	plan       CarrierDispatchPlan
	completion ResponseCompletionPolicy
	fields     map[string]string
	error      string
}

pub fn (rt Runtime) prepare_outbound_delivery(outcome dispatch.DeliveryOutcome) OutboundOutcome {
	projection := rt.project_delivery(outcome)
	if projection.error != '' {
		return OutboundOutcome{
			action: .rejected
			error:  projection.error
			fields: event_fields('outbound.rejected', '', {
				'error': projection.error
			})
		}
	}
	mut fields := carrier_dispatch_plan_event_fields(projection.plan)
	fields['relay_id'] = projection.relay_id
	fields['carrier_id'] = projection.plan.carrier_id
	fields['frame_id'] = projection.frame.id
	fields['channel_id'] = projection.frame.channel_id
	fields['completion_mode'] = projection.completion_policy.mode
	if projection.completion_policy.timeout_ms > 0 {
		fields['completion_timeout_ms'] = projection.completion_policy.timeout_ms.str()
	}
	if projection.frame.correlation_id != '' {
		fields['correlation_id'] = projection.frame.correlation_id
	}
	action := if projection.plan.available {
		OutboundAction.ready
	} else {
		OutboundAction.unavailable
	}
	fields['relay_event'] = 'outbound.${action}'
	return OutboundOutcome{
		action:     action
		relay_id:   projection.relay_id
		carrier_id: projection.plan.carrier_id
		trace_id:   projection.frame.trace_id
		frame_id:   projection.frame.id
		frame:      projection.frame
		plan:       projection.plan
		completion: projection.completion_policy
		fields:     fields
		error:      projection.plan.error
	}
}

pub fn (mut rt Runtime) track_outbound_delivery(outbound OutboundOutcome, default_buffer_limit int) ForwardingOutcome {
	if outbound.action != .ready {
		return ForwardingOutcome{
			action:   .rejected
			trace_id: outbound.trace_id
			frame_id: outbound.frame_id
			error:    if outbound.error != '' { outbound.error } else { 'relay_outbound_not_ready:${outbound.action}' }
		}
	}
	return rt.handle_frame(outbound.frame, 'local:${outbound.relay_id}', default_buffer_limit)
}
