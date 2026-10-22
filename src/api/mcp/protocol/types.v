module protocol

import sync
import crypto.rand

// ── MCP Session ──

pub struct Session {
pub mut:
	id                       string
	protocol_version         string
	request_id               string
	trace_id                 string
	path                     string
	started_at_unix          i64
	last_activity_unix       i64
	client_capabilities_json string
	stream                   ?&SessionStream
	dispatch                 ?&SessionDispatch
	pending                  []string
}

// ── Admin Snapshot Types ──

pub struct SessionSnapshot {
pub:
	id                       string
	protocol_version         string
	request_id               string
	trace_id                 string
	path                     string
	started_at_unix          i64
	last_activity_unix       i64
	pending_count            int
	connected                bool
	client_capabilities_json string
}

pub struct RuntimeSnapshot {
pub:
	active_sessions            int
	returned_sessions          int
	details                    bool
	limit                      int
	offset                     int
	session_id                 string
	protocol_version           string
	max_sessions               int
	max_pending_messages       int
	session_ttl_seconds        int
	allowed_origins            []string
	sampling_capability_policy string
	sessions                   []SessionSnapshot
}

// ── Queue Result ──

pub struct QueueResult {
pub:
	queued      bool
	error       bool
	error_class string
}

// ── Session Utilities ──

// Session IDs are opaque correlation keys. Wall-clock precision cannot provide
// uniqueness when independent initialize requests complete concurrently.
pub fn Session.generate_id() !string {
	bytes := rand.bytes(24)!
	return 'mcp_${bytes.hex()}'
}

// Mutable queue storage belongs to McpState. Stream/dispatch references remain
// observations governed by their existing identity and close owners.
fn (session Session) snapshot_copy() Session {
	return Session{ ...session, pending: session.pending.clone() }
}

pub fn Session.default_protocol_version() string {
	return '2025-11-05'
}

pub fn McpState.normalize_sampling_capability_policy(raw string) string {
	policy := raw.trim_space().to_lower()
	return match policy {
		'drop', 'error' { policy }
		else { 'warn' }
	}
}

pub struct McpState {
mut:
	stopping       bool
	stream_counter u64
	streams        map[u64]&SessionStream
pub mut:
	mu                                      sync.Mutex
	max_sessions                            int
	max_pending_messages                    int
	session_ttl_seconds                     int
	sampling_capability_policy              string
	allowed_origins                         []string
	sessions                                map[string]Session
	stat_sessions_expired_total             i64
	stat_sessions_evicted_total             i64
	stat_pending_dropped_total              i64
	stat_sampling_capability_warnings_total i64
	stat_sampling_capability_dropped_total  i64
	stat_sampling_capability_errors_total   i64
}
