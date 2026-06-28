module relay

pub struct ChannelRegistry {
pub:
	max_channels int = 1024
pub mut:
	channels     map[string]RelayChannel
	correlations map[string]string
}

pub struct RelayChannel {
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

pub fn new_channel_registry(max_channels int) ChannelRegistry {
	return ChannelRegistry{
		max_channels: if max_channels > 0 { max_channels } else { 1024 }
		channels:     map[string]RelayChannel{}
		correlations: map[string]string{}
	}
}

pub fn (mut registry ChannelRegistry) open_channel(channel RelayChannel) ! {
	if channel.id.trim_space() == '' {
		return error('relay_channel_missing_id')
	}
	if channel.trace_id.trim_space() == '' {
		return error('relay_channel_missing_trace_id:${channel.id}')
	}
	if channel.id !in registry.channels && registry.channels.len >= registry.max_channels {
		return error('relay_channel_limit_exceeded:${registry.max_channels}')
	}
	normalized := RelayChannel{
		...channel
		open:         true
		buffer_limit: if channel.buffer_limit > 0 { channel.buffer_limit } else { 64 }
	}
	registry.channels[channel.id] = normalized
}

pub fn (mut registry ChannelRegistry) close_channel(channel_id string) bool {
	mut channel := registry.channels[channel_id] or { return false }
	channel.open = false
	channel.buffered = []WireFrame{}
	registry.channels[channel_id] = channel
	mut remove_ids := []string{}
	for correlation_id, mapped_channel_id in registry.correlations {
		if mapped_channel_id == channel_id {
			remove_ids << correlation_id
		}
	}
	for correlation_id in remove_ids {
		registry.correlations.delete(correlation_id)
	}
	return true
}

pub fn (mut registry ChannelRegistry) retire_channel(channel_id string) bool {
	if channel_id !in registry.channels {
		return false
	}
	registry.channels.delete(channel_id)
	mut remove_ids := []string{}
	for correlation_id, mapped_channel_id in registry.correlations {
		if mapped_channel_id == channel_id {
			remove_ids << correlation_id
		}
	}
	for correlation_id in remove_ids {
		registry.correlations.delete(correlation_id)
	}
	return true
}

pub fn (mut registry ChannelRegistry) bind_correlation(correlation_id string, channel_id string) ! {
	if correlation_id.trim_space() == '' {
		return error('relay_channel_missing_correlation_id')
	}
	channel := registry.channels[channel_id] or {
		return error('relay_channel_unknown:${channel_id}')
	}
	if !channel.open {
		return error('relay_channel_closed:${channel_id}')
	}
	registry.correlations[correlation_id] = channel_id
}

pub fn (registry ChannelRegistry) channel_for_correlation(correlation_id string) ?RelayChannel {
	channel_id := registry.correlations[correlation_id] or { return none }
	return registry.channels[channel_id] or { none }
}

pub fn (mut registry ChannelRegistry) enqueue(channel_id string, frame WireFrame) ! {
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
	mut channel := registry.channels[channel_id] or {
		return error('relay_channel_unknown:${channel_id}')
	}
	frames := channel.buffered.clone()
	channel.buffered = []WireFrame{}
	registry.channels[channel_id] = channel
	return frames
}

pub fn (mut registry ChannelRegistry) drain_returned(channel_id string) ![]WireFrame {
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
