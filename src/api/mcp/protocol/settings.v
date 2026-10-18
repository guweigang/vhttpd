module protocol

// Plan projections carry configuration only, never a live session/stream owner.
pub struct Settings {
pub mut:
	max_sessions               int
	max_pending_messages       int
	session_ttl_seconds        int
	sampling_capability_policy string
	allowed_origins            []string
}

pub fn (settings Settings) new_state() McpState {
	return McpState{
		max_sessions:               settings.max_sessions
		max_pending_messages:       settings.max_pending_messages
		session_ttl_seconds:        settings.session_ttl_seconds
		sampling_capability_policy: McpState.normalize_sampling_capability_policy(settings.sampling_capability_policy)
		allowed_origins:            settings.allowed_origins.clone()
	}
}

// Keep the mutex, terminal admission state, tokens, streams, queues and metrics.
// Capacity/TTL changes take effect at the existing admission/pruning boundaries.
pub fn (mut s McpState) apply_settings(settings Settings) {
	s.mu.@lock()
	defer { s.mu.unlock() }
	s.max_sessions = settings.max_sessions
	s.max_pending_messages = settings.max_pending_messages
	s.session_ttl_seconds = settings.session_ttl_seconds
	s.sampling_capability_policy = McpState.normalize_sampling_capability_policy(settings.sampling_capability_policy)
	s.allowed_origins = settings.allowed_origins.clone()
}
