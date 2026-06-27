module relay

import dispatch
import runtime_plan

pub struct Runtime {
pub:
	descriptors map[string]RelayDescriptor
pub mut:
	agents   map[string]AgentState
	channels ChannelRegistry
	sessions SessionRegistry
	carriers CarrierRegistry
}

pub fn empty_runtime() Runtime {
	return Runtime{
		descriptors: map[string]RelayDescriptor{}
		agents:      map[string]AgentState{}
		channels:    new_channel_registry(1024)
		sessions:    new_session_registry()
		carriers:    new_carrier_registry()
	}
}

pub fn new_runtime(plan runtime_plan.RuntimePlan) !Runtime {
	descriptors := descriptors_from_plan(plan)!
	mut max_channels := 1024
	for _, descriptor in descriptors {
		if descriptor.max_channels > max_channels {
			max_channels = descriptor.max_channels
		}
	}
	return Runtime{
		descriptors: descriptors
		agents:      map[string]AgentState{}
		channels:    new_channel_registry(max_channels)
		sessions:    new_session_registry()
		carriers:    new_carrier_registry()
	}
}

pub fn (mut rt Runtime) ensure_agent(relay_id string) !AgentState {
	descriptor := rt.descriptors[relay_id] or {
		return error('relay_runtime_unknown_relay:${relay_id}')
	}
	if descriptor.mode != .agent {
		return error('relay_runtime_not_agent:${relay_id}')
	}
	if agent := rt.agents[relay_id] {
		return agent
	}
	agent := new_agent_state(descriptor)
	rt.agents[relay_id] = agent
	return agent
}

pub fn (mut rt Runtime) mark_agent_connecting(relay_id string, now_ms i64) !AgentState {
	agent := rt.ensure_agent(relay_id)!
	next := agent.begin_connect(now_ms)
	rt.agents[relay_id] = next
	return next
}

pub fn (mut rt Runtime) mark_agent_registered(relay_id string, now_ms i64) !AgentState {
	agent := rt.ensure_agent(relay_id)!
	next := agent.mark_registered(now_ms)
	rt.agents[relay_id] = next
	return next
}

pub fn (mut rt Runtime) mark_agent_failed(relay_id string, now_ms i64, err string) !AgentState {
	descriptor := rt.descriptors[relay_id] or {
		return error('relay_runtime_unknown_relay:${relay_id}')
	}
	agent := rt.ensure_agent(relay_id)!
	next := agent.mark_failed(now_ms, err, reconnect_policy_from_descriptor(descriptor))
	rt.agents[relay_id] = next
	return next
}

pub fn (mut rt Runtime) agent_reconnect_delay_ms(relay_id string, now_ms i64) !int {
	descriptor := rt.descriptors[relay_id] or {
		return error('relay_runtime_unknown_relay:${relay_id}')
	}
	agent := rt.ensure_agent(relay_id)!
	if agent.state == .closed {
		return -1
	}
	if agent.state == .backoff {
		remaining := agent.next_attempt_at_ms - now_ms
		if remaining <= 0 {
			return 0
		}
		return int(remaining)
	}
	return reconnect_policy_from_descriptor(descriptor).initial_delay_ms
}

pub fn (mut rt Runtime) handle_frame(frame WireFrame, source_node_id string, default_buffer_limit int) ForwardingOutcome {
	return handle_forward_frame(mut rt.channels, frame, source_node_id, default_buffer_limit)
}

pub fn (mut rt Runtime) drain_returned_frames(channel_id string) ![]WireFrame {
	return rt.channels.drain_returned(channel_id)
}

pub fn (mut rt Runtime) route_session_frame(session_id string, link_id string, source_endpoint_id string, target_role string, frame WireFrame, pending_limit int) SessionRouteOutcome {
	return route_session_frame(mut rt.sessions, session_id, link_id, source_endpoint_id,
		target_role, frame, pending_limit)
}

pub fn (mut rt Runtime) open_session_endpoint(endpoint RelayEndpoint) ![]WireFrame {
	return open_session_endpoint_and_drain(mut rt.sessions, endpoint)
}

pub fn (mut rt Runtime) register_carrier(relay_id string, carrier_id string) ! {
	rt.carriers.register(relay_id, carrier_id)!
}

pub fn (mut rt Runtime) unregister_carrier(relay_id string, trace_id string) CarrierDetachResult {
	return rt.carriers.unregister(relay_id, trace_id)
}

pub fn (rt Runtime) carrier_dispatch_plan(relay_id string, frame WireFrame) CarrierDispatchPlan {
	return carrier_dispatch_plan(rt.carriers, relay_id, frame)
}

pub fn (rt Runtime) project_delivery(outcome dispatch.DeliveryOutcome) DeliveryProjection {
	return delivery_projection(rt.carriers, outcome)
}

pub fn (rt Runtime) hub_relay_by_path(path string) ?RelayDescriptor {
	normalized := normalize_relay_path(path)
	mut ids := rt.descriptors.keys()
	ids.sort()
	for id in ids {
		descriptor := rt.descriptors[id]
		if descriptor.mode != .hub {
			continue
		}
		if descriptor.path.trim_space() == '' {
			continue
		}
		if normalize_relay_path(descriptor.path) == normalized {
			return descriptor
		}
	}
	return none
}

pub fn (rt Runtime) agent_descriptors() []RelayDescriptor {
	mut out := []RelayDescriptor{}
	mut ids := rt.descriptors.keys()
	ids.sort()
	for id in ids {
		descriptor := rt.descriptors[id]
		if descriptor.mode == .agent {
			out << descriptor
		}
	}
	return out
}

pub fn (rt Runtime) snapshot() RelayRuntimeSnapshot {
	mut agents := []AgentState{}
	mut ids := rt.agents.keys()
	ids.sort()
	for id in ids {
		agents << rt.agents[id]
	}
	return runtime_snapshot_with_carriers(rt.descriptors, agents, rt.channels, rt.sessions,
		rt.carriers)
}

fn normalize_relay_path(path string) string {
	trimmed := path.trim_space()
	if trimmed == '' {
		return ''
	}
	return if trimmed.starts_with('/') { trimmed } else { '/${trimmed}' }
}
