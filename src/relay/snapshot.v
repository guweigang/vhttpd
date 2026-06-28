module relay

pub struct RelayRuntimeSnapshot {
pub:
	descriptor_count int
	agent_count      int
	channel_count    int
	open_channels    int
	carrier_count    int
	session_count    int
	pending_frames   int
	returned_frames  int
	agents           []AgentSnapshot
	carriers         []CarrierSnapshot
	channels         []ChannelSnapshot
	sessions         []SessionSnapshot
}

pub struct AgentSnapshot {
pub:
	node_id            string
	relay_id           string
	state              string
	attempt            int
	next_attempt_at_ms i64
	last_error         string
}

pub struct ChannelSnapshot {
pub:
	id           string
	node_id      string
	route        string
	trace_id     string
	open         bool
	buffered_len int
	returned_len int
}

pub struct CarrierSnapshot {
pub:
	relay_id   string
	carrier_id string
}

pub struct SessionSnapshot {
pub:
	id             string
	endpoint_count int
	link_count     int
	pending_frames int
}

pub fn runtime_snapshot(descriptors map[string]RelayDescriptor, agents []AgentState, channels ChannelRegistry, sessions SessionRegistry) RelayRuntimeSnapshot {
	return runtime_snapshot_with_carriers(descriptors, agents, channels, sessions,
		new_carrier_registry())
}

pub fn runtime_snapshot_with_carriers(descriptors map[string]RelayDescriptor, agents []AgentState, channels ChannelRegistry, sessions SessionRegistry, carriers CarrierRegistry) RelayRuntimeSnapshot {
	channel_items := build_channel_snapshots(channels)
	session_items := build_session_snapshots(sessions)
	carrier_items := build_carrier_snapshots(carriers)
	return RelayRuntimeSnapshot{
		descriptor_count: descriptors.len
		agent_count:      agents.len
		channel_count:    channel_items.len
		open_channels:    channel_items.filter(it.open).len
		carrier_count:    carrier_items.len
		session_count:    session_items.len
		pending_frames:   channel_pending_total(channel_items) +
			session_pending_total(session_items)
		returned_frames:  channel_returned_total(channel_items)
		agents:           agent_snapshots(agents)
		carriers:         carrier_items
		channels:         channel_items
		sessions:         session_items
	}
}

fn agent_snapshots(agents []AgentState) []AgentSnapshot {
	mut out := []AgentSnapshot{}
	for agent in agents {
		out << AgentSnapshot{
			node_id:            agent.node_id
			relay_id:           agent.relay_id
			state:              agent.state.str()
			attempt:            agent.attempt
			next_attempt_at_ms: agent.next_attempt_at_ms
			last_error:         agent.last_error
		}
	}
	return out
}

fn build_channel_snapshots(registry ChannelRegistry) []ChannelSnapshot {
	mut ids := registry.channels.keys()
	ids.sort()
	mut out := []ChannelSnapshot{}
	for id in ids {
		channel := registry.channels[id]
		out << ChannelSnapshot{
			id:           channel.id
			node_id:      channel.node_id
			route:        channel.route
			trace_id:     channel.trace_id
			open:         channel.open
			buffered_len: channel.buffered.len
			returned_len: channel.buffered.filter(frame_is_pipeline_response(it)).len
		}
	}
	return out
}

fn build_carrier_snapshots(registry CarrierRegistry) []CarrierSnapshot {
	mut ids := registry.ids.keys()
	ids.sort()
	mut out := []CarrierSnapshot{}
	for relay_id in ids {
		out << CarrierSnapshot{
			relay_id:   relay_id
			carrier_id: registry.ids[relay_id]
		}
	}
	return out
}

fn build_session_snapshots(registry SessionRegistry) []SessionSnapshot {
	mut ids := registry.sessions.keys()
	ids.sort()
	mut out := []SessionSnapshot{}
	for id in ids {
		session := registry.sessions[id]
		mut pending := 0
		for _, frames in session.pending_by_link {
			pending += frames.len
		}
		out << SessionSnapshot{
			id:             session.id
			endpoint_count: session.endpoints.len
			link_count:     session.endpoints_by_link.len
			pending_frames: pending
		}
	}
	return out
}

fn channel_pending_total(channels []ChannelSnapshot) int {
	mut total := 0
	for channel in channels {
		total += channel.buffered_len
	}
	return total
}

fn channel_returned_total(channels []ChannelSnapshot) int {
	mut total := 0
	for channel in channels {
		total += channel.returned_len
	}
	return total
}

fn session_pending_total(sessions []SessionSnapshot) int {
	mut total := 0
	for session in sessions {
		total += session.pending_frames
	}
	return total
}
