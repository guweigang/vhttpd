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
	if projection.frame.correlation_id != '' {
		fields['correlation_id'] = projection.frame.correlation_id
	}
	action := if projection.plan.available { OutboundAction.ready } else { OutboundAction.unavailable }
	fields['relay_event'] = 'outbound.${action}'
	return OutboundOutcome{
		action:     action
		relay_id:   projection.relay_id
		carrier_id: projection.plan.carrier_id
		trace_id:   projection.frame.trace_id
		frame_id:   projection.frame.id
		frame:      projection.frame
		plan:       projection.plan
		fields:     fields
		error:      projection.plan.error
	}
}
