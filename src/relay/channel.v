module relay

import sync

@[heap]
struct ChannelRegistration {}

pub struct ChannelRegistry {
	mu &sync.Mutex = &sync.Mutex{}
pub:
	max_channels int = 1024
pub mut:
	channels     map[string]RelayChannel
	correlations map[string]string
}

pub struct RelayChannel {
	registration ?&ChannelRegistration
pub:
	id           string
	node_id      string
	route        string
	trace_id     string
	buffer_limit int = 64
pub mut:
	open     bool = true
	buffered []WireFrame
}

fn (channel RelayChannel) owned_copy() RelayChannel {
	return RelayChannel{ ...channel, buffered: channel.buffered.map(it.owned_copy()) }
}

pub fn new_channel_registry(max_channels int) ChannelRegistry {
	return ChannelRegistry{
		max_channels: if max_channels > 0 { max_channels } else { 1024 }
		channels:     map[string]RelayChannel{}
		correlations: map[string]string{}
	}
}

pub fn (mut registry ChannelRegistry) open_channel(channel RelayChannel) ! {
	registry.mu.@lock()
	defer { registry.mu.unlock() }
	registry.open_channel_unlocked(channel)!
}

fn (mut registry ChannelRegistry) open_channel_unlocked(channel RelayChannel) ! {
	if channel.id.trim_space() == '' {
		return error('relay_channel_missing_id')
	}
	if channel.trace_id.trim_space() == '' {
		return error('relay_channel_missing_trace_id:${channel.id}')
	}
	if channel.id !in registry.channels && registry.channels.len >= registry.max_channels {
		return error('relay_channel_limit_exceeded:${registry.max_channels}')
	}
	// Initial frames consume the same capacity as incremental enqueue. Reject
	// before copying or replacing any live registration/correlation ownership.
	buffer_limit := if channel.buffer_limit > 0 { channel.buffer_limit } else { 64 }
	if channel.buffered.len > buffer_limit {
		return error('relay_channel_buffer_full:${channel.id}')
	}
	owned := channel.owned_copy()
	normalized := RelayChannel{
		...owned
		registration: &ChannelRegistration{}
		open:         true
		buffer_limit: buffer_limit
	}
	// Reopening publishes a new registration. Correlations belong to the
	// retired registration and must not resolve into this replacement.
	if channel.id in registry.channels { registry.remove_channel_correlations(channel.id) }
	registry.channels[channel.id] = normalized
}

pub fn (mut registry ChannelRegistry) close_channel(channel_id string) bool {
	registry.mu.@lock()
	defer { registry.mu.unlock() }
	return registry.close_channel_unlocked(channel_id)
}

fn (mut registry ChannelRegistry) close_channel_unlocked(channel_id string) bool {
	mut channel := registry.channels[channel_id] or { return false }
	channel.open = false
	channel.buffered = []WireFrame{}
	registry.channels[channel_id] = channel
	registry.remove_channel_correlations(channel_id)
	return true
}

pub fn (mut registry ChannelRegistry) retire_channel(channel_id string) bool {
	registry.mu.@lock()
	defer { registry.mu.unlock() }
	return registry.retire_channel_unlocked(channel_id)
}

fn (mut registry ChannelRegistry) retire_channel_unlocked(channel_id string) bool {
	if channel_id !in registry.channels {
		return false
	}
	registry.channels.delete(channel_id)
	registry.remove_channel_correlations(channel_id)
	return true
}

fn (mut registry ChannelRegistry) remove_channel_correlations(channel_id string) {
	mut remove_ids := []string{}
	for correlation_id, mapped_channel_id in registry.correlations {
		if mapped_channel_id == channel_id {
			remove_ids << correlation_id
		}
	}
	for correlation_id in remove_ids {
		registry.correlations.delete(correlation_id)
	}
}

fn validate_correlation_id(correlation_id string) ! {
	if correlation_id.trim_space() == '' {
		return error('relay_channel_missing_correlation_id')
	}
}

pub fn (mut registry ChannelRegistry) bind_correlation(correlation_id string, channel_id string) ! {
	registry.mu.@lock()
	defer { registry.mu.unlock() }
	registry.bind_correlation_unlocked(correlation_id, channel_id)!
}

fn (mut registry ChannelRegistry) bind_correlation_unlocked(correlation_id string, channel_id string) ! {
	validate_correlation_id(correlation_id)!
	channel := registry.channels[channel_id] or {
		return error('relay_channel_unknown:${channel_id}')
	}
	if !channel.open {
		return error('relay_channel_closed:${channel_id}')
	}
	registry.correlations[correlation_id] = channel_id
}

// Internal routing needs only the identity, not a copy of every queued frame.
fn (registry ChannelRegistry) channel_id_for_correlation(correlation_id string) ?string {
	channel_id := registry.correlations[correlation_id] or { return none }
	if channel_id !in registry.channels { return none }
	return channel_id
}

pub fn (registry ChannelRegistry) channel_for_correlation(correlation_id string) ?RelayChannel {
	mut mu := registry.mu
	mu.@lock()
	defer { mu.unlock() }
	channel_id := registry.channel_id_for_correlation(correlation_id) or { return none }
	channel := registry.channels[channel_id] or { return none }
	return channel.owned_copy()
}

pub fn (mut registry ChannelRegistry) enqueue(channel_id string, frame WireFrame) ! {
	registry.mu.@lock()
	defer { registry.mu.unlock() }
	registry.enqueue_unlocked(channel_id, frame)!
}

fn (mut registry ChannelRegistry) enqueue_unlocked(channel_id string, frame WireFrame) ! {
	mut channel := registry.channels[channel_id] or {
		return error('relay_channel_unknown:${channel_id}')
	}
	if !channel.open {
		return error('relay_channel_closed:${channel_id}')
	}
	if channel.buffered.len >= channel.buffer_limit {
		return error('relay_channel_buffer_full:${channel_id}')
	}
	channel.buffered << frame
	registry.channels[channel_id] = channel
}

pub fn (mut registry ChannelRegistry) drain(channel_id string) ![]WireFrame {
	registry.mu.@lock()
	defer { registry.mu.unlock() }
	return registry.drain_unlocked(channel_id)!
}

fn (mut registry ChannelRegistry) drain_unlocked(channel_id string) ![]WireFrame {
	mut channel := registry.channels[channel_id] or {
		return error('relay_channel_unknown:${channel_id}')
	}
	frames := channel.buffered.clone()
	channel.buffered = []WireFrame{}
	registry.channels[channel_id] = channel
	return frames
}

pub fn (mut registry ChannelRegistry) drain_returned(channel_id string) ![]WireFrame {
	registry.mu.@lock()
	defer { registry.mu.unlock() }
	return registry.drain_returned_unlocked(channel_id)!
}

fn (mut registry ChannelRegistry) drain_returned_unlocked(channel_id string) ![]WireFrame {
	mut channel := registry.channels[channel_id] or {
		return error('relay_channel_unknown:${channel_id}')
	}
	mut returned := []WireFrame{}
	mut remaining := []WireFrame{}
	for frame in channel.buffered {
		if frame_is_pipeline_response(frame) {
			returned << frame
		} else {
			remaining << frame
		}
	}
	channel.buffered = remaining
	registry.channels[channel_id] = channel
	return returned
}

pub fn (mut registry ChannelRegistry) drain_returned_for(channel_id string, target_id string) ![]WireFrame {
	registry.mu.@lock()
	defer { registry.mu.unlock() }
	return registry.drain_returned_for_unlocked(channel_id, target_id)!
}

fn (mut registry ChannelRegistry) drain_returned_for_unlocked(channel_id string, target_id string) ![]WireFrame {
	normalized_target := target_id.trim_space()
	if normalized_target == '' {
		return error('relay_channel_missing_response_target')
	}
	mut channel := registry.channels[channel_id] or {
		return error('relay_channel_unknown:${channel_id}')
	}
	mut returned := []WireFrame{}
	mut remaining := []WireFrame{}
	for frame in channel.buffered {
		if frame_is_pipeline_response(frame) && frame_response_target_id(frame) == normalized_target {
			returned << frame
		} else {
			remaining << frame
		}
	}
	channel.buffered = remaining
	registry.channels[channel_id] = channel
	return returned
}
