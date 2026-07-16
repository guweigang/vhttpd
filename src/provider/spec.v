module provider

import upstream.transport
import command as cmdpkg
import executor

// ProviderCommandHandler bridges provider-specific command execution.
pub interface ProviderCommandHandler {
	execute(command transport.WorkerWebSocketUpstreamCommand, normalized cmdpkg.NormalizedCommand, mut snapshot executor.WebSocketUpstreamCommandActivity) (bool, string)
}

// No-op default lets specs be constructed safely while keeping behavior stable.
pub struct NoopProviderCommandHandler {}

pub fn (h NoopProviderCommandHandler) execute(command transport.WorkerWebSocketUpstreamCommand, normalized cmdpkg.NormalizedCommand, mut snapshot executor.WebSocketUpstreamCommandActivity) (bool, string) {
	_ = command
	_ = normalized
	_ = snapshot
	return false, ''
}

// ProviderRuntimeMetrics aggregates connection-level counters across providers.
pub struct ProviderRuntimeMetrics {
pub:
	connect_attempts  i64
	connect_successes i64
	received_frames   i64
	acked_events      i64
	messages_sent     i64
	send_errors       i64
}

// ProviderRuntimeUpstreamLaunch describes a launch entry for admin UI.
pub struct ProviderRuntimeUpstreamLaunch {
pub:
	provider string
	instance string
	label    string
	url      string
}
