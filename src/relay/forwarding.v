module relay

pub enum ForwardingAction {
	opened
	queued
	closed
	rejected
	ignored
}

pub struct ForwardingOutcome {
pub:
	action         ForwardingAction
	channel_id     string
	correlation_id string
	trace_id       string
	frame_id       string
	error          string
}

pub fn handle_forward_frame(mut registry ChannelRegistry, frame WireFrame, source_node_id string, default_buffer_limit int) ForwardingOutcome {
	registry.mu.@lock()
	defer { registry.mu.unlock() }
	return handle_forward_frame_unlocked(mut registry, frame, source_node_id, default_buffer_limit)
}

// Caller holds the channel registry mutex across lookup and publication.
fn handle_forward_frame_unlocked(mut registry ChannelRegistry, frame WireFrame, source_node_id string, default_buffer_limit int) ForwardingOutcome {
	validate_frame(frame) or {
		return forwarding_rejected(frame, err.msg())
	}
	match frame.kind {
		.open {
			return handle_open_frame(mut registry, frame, source_node_id, default_buffer_limit)
		}
		.data {
			return handle_data_frame(mut registry, frame)
		}
		.end, .cancel, .error {
			return handle_close_frame(mut registry, frame)
		}
		.hello, .hello_ack, .ping, .pong {
			return ForwardingOutcome{
				action:   .ignored
				trace_id: frame.trace_id
				frame_id: frame.id
			}
		}
	}
}

fn handle_open_frame(mut registry ChannelRegistry, frame WireFrame, source_node_id string, default_buffer_limit int) ForwardingOutcome {
	// Correlation admission must succeed before open replaces the registration,
	// its queued frames and old correlation ownership. Empty means no binding.
	if frame.correlation_id != '' {
		validate_correlation_id(frame.correlation_id) or {
			return forwarding_rejected(frame, err.msg())
		}
	}
	channel := RelayChannel{
		id:           frame.channel_id
		node_id:      source_node_id
		route:        frame.route
		trace_id:     frame.trace_id
		buffer_limit: if default_buffer_limit > 0 { default_buffer_limit } else { 64 }
	}
	registry.open_channel_unlocked(channel) or {
		return forwarding_rejected(frame, err.msg())
	}
	if frame.correlation_id != '' {
		registry.bind_correlation_unlocked(frame.correlation_id, frame.channel_id) or {
			return forwarding_rejected(frame, err.msg())
		}
	}
	return ForwardingOutcome{
		action:         .opened
		channel_id:     frame.channel_id
		correlation_id: frame.correlation_id
		trace_id:       frame.trace_id
		frame_id:       frame.id
	}
}

fn handle_data_frame(mut registry ChannelRegistry, frame WireFrame) ForwardingOutcome {
	channel_id := resolve_forward_channel_id(registry, frame) or {
		return forwarding_rejected(frame, 'relay_forward_unknown_channel')
	}
	registry.enqueue_unlocked(channel_id, frame) or {
		return forwarding_rejected(frame, err.msg())
	}
	return ForwardingOutcome{
		action:         .queued
		channel_id:     channel_id
		correlation_id: frame.correlation_id
		trace_id:       frame.trace_id
		frame_id:       frame.id
	}
}

fn handle_close_frame(mut registry ChannelRegistry, frame WireFrame) ForwardingOutcome {
	channel_id := resolve_forward_channel_id(registry, frame) or {
		return forwarding_rejected(frame, 'relay_forward_unknown_channel')
	}
	if !registry.close_channel_unlocked(channel_id) {
		return forwarding_rejected(frame, 'relay_forward_unknown_channel')
	}
	return ForwardingOutcome{
		action:         .closed
		channel_id:     channel_id
		correlation_id: frame.correlation_id
		trace_id:       frame.trace_id
		frame_id:       frame.id
	}
}

fn resolve_forward_channel_id(registry ChannelRegistry, frame WireFrame) ?string {
	if frame.channel_id != '' {
		if _ := registry.channels[frame.channel_id] {
			return frame.channel_id
		}
	}
	if frame.correlation_id != '' {
		if channel_id := registry.channel_id_for_correlation(frame.correlation_id) {
			return channel_id
		}
	}
	return none
}

fn forwarding_rejected(frame WireFrame, err string) ForwardingOutcome {
	return ForwardingOutcome{
		action:         .rejected
		channel_id:     frame.channel_id
		correlation_id: frame.correlation_id
		trace_id:       frame.trace_id
		frame_id:       frame.id
		error:          err
	}
}
