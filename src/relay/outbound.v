module relay

import dispatch
import sync

// One execution attempt owns one captured registration. Copies of the outcome
// share this capability; public wire IDs cannot recreate it.
@[heap]
struct OutboundTracking {
mut:
	mu           sync.Mutex
	attempted    bool
	channel_id   string
	registration ?&ChannelRegistration
}

pub enum OutboundAction {
	ready
	unavailable
	rejected
}

pub struct OutboundOutcome {
	tracking &OutboundTracking = &OutboundTracking{}
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
			error:    if outbound.error != '' {
				outbound.error
			} else {
				'relay_outbound_not_ready:${outbound.action}'
			}
		}
	}
	mut tracking := outbound.tracking
	tracking.mu.@lock()
	defer { tracking.mu.unlock() }
	if tracking.attempted {
		return ForwardingOutcome{ action: .rejected, trace_id: outbound.trace_id, frame_id: outbound.frame_id, error: 'relay_outbound_already_tracked' }
	}
	tracking.attempted = true
	rt.channels.mu.@lock()
	defer { rt.channels.mu.unlock() }
	result := handle_forward_frame_unlocked(mut rt.channels, outbound.frame, 'local:${outbound.relay_id}', default_buffer_limit)
	if result.action in [.opened, .queued, .closed] {
		if channel := rt.channels.channels[result.channel_id] {
			tracking.registration = channel.registration
			tracking.channel_id = result.channel_id
		}
	}
	return result
}

// Caller holds tracking.mu and registry.mu, in that order.
fn (outbound OutboundOutcome) owns_channel_unlocked(registry ChannelRegistry) bool {
	tracking := outbound.tracking
	if tracking.channel_id != outbound.frame.channel_id { return false }
	expected := tracking.registration or { return false }
	channel := registry.channels[tracking.channel_id] or { return false }
	current := channel.registration or { return false }
	return voidptr(expected) == voidptr(current)
}

pub fn (mut rt Runtime) finish_outbound_delivery(outbound OutboundOutcome) ForwardingOutcome {
	if outbound.frame.channel_id.trim_space() == '' {
		return ForwardingOutcome{
			action:   .rejected
			trace_id: outbound.trace_id
			frame_id: outbound.frame_id
			error:    'relay_outbound_missing_channel_id'
		}
	}
	mut tracking := outbound.tracking
	tracking.mu.@lock()
	defer { tracking.mu.unlock() }
	rt.channels.mu.@lock()
	defer { rt.channels.mu.unlock() }
	if outbound.frame.channel_id !in rt.channels.channels {
		return ForwardingOutcome{
			action:     .rejected
			channel_id: outbound.frame.channel_id
			trace_id:   outbound.trace_id
			frame_id:   outbound.frame_id
			error:      'relay_channel_unknown:${outbound.frame.channel_id}'
		}
	}
	if !outbound.owns_channel_unlocked(rt.channels) {
		return ForwardingOutcome{ action: .rejected, channel_id: outbound.frame.channel_id, trace_id: outbound.trace_id, frame_id: outbound.frame_id, error: 'relay_outbound_registration_retired:${outbound.frame.channel_id}' }
	}
	rt.channels.retire_channel_unlocked(outbound.frame.channel_id)
	return ForwardingOutcome{
		action:     .closed
		channel_id: outbound.frame.channel_id
		trace_id:   outbound.trace_id
		frame_id:   outbound.frame_id
	}
}
