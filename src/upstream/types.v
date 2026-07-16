module upstream

import command
import executor
import net
import upstream.transport

// OllamaNdjsonMessage represents the "message" field of an Ollama NDJSON row.
pub struct OllamaNdjsonMessage {
pub:
	content string
}

// OllamaNdjsonRow represents a single NDJSON line from the Ollama API.
pub struct OllamaNdjsonRow {
pub:
	message  OllamaNdjsonMessage
	response string
	done     bool
}

pub struct UpstreamSnapshot {
pub:
	provider                string
	instance                string
	enabled                 bool
	configured              bool
	connected               bool
	url                     string
	last_connect_at_unix    i64
	last_disconnect_at_unix i64
	last_error              string
	connect_attempts        i64
	connect_successes       i64
	received_frames         i64
}

pub struct UpstreamRuntimeSnapshot {
pub:
	active_count   int
	returned_count int
	details        bool
	limit          int
	offset         int
	sessions       []UpstreamSnapshot
}

pub struct UpstreamRuntimeSession {
pub:
	id              string
	request_id      string
	trace_id        string
	role            string
	provider        string
	method          string
	path            string
	name            string
	transport       string
	codec           string
	mapper          string
	stream_type     string
	source          string
	started_at_unix i64
}

pub fn UpstreamRuntimeSnapshot.from_sessions(sessions []UpstreamSnapshot, details bool, limit int, offset int) UpstreamRuntimeSnapshot {
	mut sorted := sessions.clone()
	sorted.sort(a.provider < b.provider)
	start := if offset < sorted.len { offset } else { sorted.len }
	page_limit := if limit > 0 { limit } else { sorted.len }
	end := if start + page_limit < sorted.len { start + page_limit } else { sorted.len }
	return UpstreamRuntimeSnapshot{
		active_count:   sessions.len
		returned_count: end - start
		details:        details
		limit:          limit
		offset:         offset
		sessions:       sorted[start..end].clone()
	}
}

// UpstreamSendRequest is the canonical provider-send command payload.
pub struct UpstreamSendRequest {
pub mut:
	provider       string
	instance       string
	app            string @[json: 'app']
	target_type    string @[json: 'target_type']
	target         string
	message_type   string @[json: 'message_type']
	content        string
	content_fields map[string]string @[json: 'content_fields']
	text           string
	uuid           string
	method         string
	params         string
	metadata       map[string]string
}

pub struct UpstreamSendResult {
pub:
	ok         bool
	provider   string
	instance   string
	message_id string @[json: 'message_id']
	error      string
}

pub struct UpstreamUpdateResult {
pub:
	ok         bool
	provider   string
	instance   string
	message_id string @[json: 'message_id']
	error      string
}

pub fn UpstreamSendResult.failure(error string) UpstreamSendResult {
	return UpstreamSendResult{
		ok:    false
		error: error
	}
}

pub fn UpstreamUpdateResult.failure(error string) UpstreamUpdateResult {
	return UpstreamUpdateResult{
		ok:    false
		error: error
	}
}

pub struct UpstreamEventSnapshot {
pub:
	provider    string
	instance    string
	event_type  string
	message_id  string
	target      string
	target_type string @[json: 'target_type']
	trace_id    string
	received_at i64
	payload     string
	metadata    map[string]string
}

pub struct UpstreamEventListSnapshot {
pub:
	returned_count int
	limit          int
	offset         int
	events         []UpstreamEventSnapshot
}

pub fn UpstreamEventListSnapshot.from_events(events []UpstreamEventSnapshot, limit int, offset int) UpstreamEventListSnapshot {
	start := if offset < events.len { offset } else { events.len }
	page_limit := if limit > 0 { limit } else { events.len }
	end := if start + page_limit < events.len { start + page_limit } else { events.len }
	return UpstreamEventListSnapshot{
		returned_count: end - start
		limit:          limit
		offset:         offset
		events:         events[start..end].clone()
	}
}

pub struct UpstreamFixtureEmitRequest {
pub:
	provider    string
	instance    string
	trace_id    string @[json: 'trace_id']
	event_type  string @[json: 'event_type']
	message_id  string @[json: 'message_id']
	target_type string @[json: 'target_type']
	target      string
	payload     string
	metadata    map[string]string
}

pub struct UpstreamFixtureEmitPlan {
pub:
	instance    string
	trace_id    string
	activity_id string @[json: 'activity_id']
	event_type  string @[json: 'event_type']
	message_id  string @[json: 'message_id']
	target_type string @[json: 'target_type']
	target      string
	payload     string
	received_at i64 @[json: 'received_at']
	metadata    map[string]string
}

pub fn (req UpstreamFixtureEmitRequest) normalized(received_at i64, seed i64) UpstreamFixtureEmitPlan {
	return UpstreamFixtureEmitPlan{
		instance:    if req.instance.trim_space() == '' { 'main' } else { req.instance.trim_space() }
		trace_id:    if req.trace_id.trim_space() == '' { 'fixture-trace-${seed}' } else { req.trace_id.trim_space() }
		activity_id: 'fixture-activity-${seed}'
		event_type:  if req.event_type.trim_space() == '' { 'fixture.message' } else { req.event_type.trim_space() }
		message_id:  if req.message_id.trim_space() == '' { 'fixture-event-${seed}' } else { req.message_id.trim_space() }
		target_type: if req.target_type.trim_space() == '' { 'fixture_target' } else { req.target_type.trim_space() }
		target:      req.target
		payload:     req.payload
		received_at: received_at
		metadata:    req.metadata.clone()
	}
}

pub fn (plan UpstreamFixtureEmitPlan) event_snapshot(provider string) UpstreamEventSnapshot {
	return UpstreamEventSnapshot{
		provider:    provider
		instance:    plan.instance
		event_type:  plan.event_type
		message_id:  plan.message_id
		target:      plan.target
		target_type: plan.target_type
		trace_id:    plan.trace_id
		received_at: plan.received_at
		payload:     plan.payload
		metadata:    plan.metadata.clone()
	}
}

pub fn (plan UpstreamFixtureEmitPlan) activity_snapshot(provider string) UpstreamActivitySnapshot {
	return UpstreamActivitySnapshot{
		provider:    provider
		instance:    plan.instance
		trace_id:    plan.trace_id
		activity_id: plan.activity_id
		event_type:  plan.event_type
		message_id:  plan.message_id
		target_type: plan.target_type
		target:      plan.target
		payload:     plan.payload
		received_at: plan.received_at
		recorded_at: plan.received_at
	}
}

pub struct UpstreamActivitySnapshot {
pub mut:
	provider       string
	instance       string
	trace_id       string @[json: 'trace_id']
	activity_id    string @[json: 'activity_id']
	event_type     string @[json: 'event_type']
	message_id     string @[json: 'message_id']
	target_type    string @[json: 'target_type']
	target         string
	payload        string
	received_at    i64    @[json: 'received_at']
	worker_handled bool   @[json: 'worker_handled']
	worker_error   string @[json: 'worker_error']
	error_class    string @[json: 'error_class']
	command_error  string @[json: 'command_error']
	commands       []executor.WebSocketUpstreamCommandActivity
	recorded_at    i64 @[json: 'recorded_at']
}

pub struct UpstreamActivityListSnapshot {
pub:
	returned_count int
	limit          int
	offset         int
	activities     []UpstreamActivitySnapshot
}

pub fn (req UpstreamSendRequest) normalized(default_provider string) UpstreamSendRequest {
	mut normalized := req
	if normalized.provider.trim_space() == '' {
		normalized.provider = default_provider
	} else {
		normalized.provider = normalized.provider.trim_space()
	}
	if normalized.instance.trim_space() != '' {
		normalized.instance = normalized.instance.trim_space()
	}
	return normalized
}

pub fn UpstreamSendRequest.from_normalized(normalized command.NormalizedCommand, default_provider string) UpstreamSendRequest {
	return UpstreamSendRequest{
		provider:       normalized.normalized_provider(default_provider)
		instance:       normalized.instance
		target_type:    normalized.target.type_
		target:         normalized.target.id
		message_type:   normalized.message_type
		content:        normalized.content
		content_fields: normalized.content_fields.clone()
		text:           normalized.text
		uuid:           normalized.uuid
		method:         normalized.method
		params:         normalized.params
		metadata:       normalized.metadata.clone()
	}
}

pub fn UpstreamSendRequest.from_feishu_command(normalized command.NormalizedCommand) UpstreamSendRequest {
	return UpstreamSendRequest.from_normalized(normalized, 'feishu')
}

// Io bridges transport-level I/O from the main App to upstream sub-module.
pub struct Io {
pub:
	write_sse_message                fn (mut net.TcpConn, transport.WorkerStreamFrame) !             = unsafe { nil }
	write_chunk                      fn (mut net.TcpConn, string) !                                  = unsafe { nil }
	write_http_stream_headers_conn   fn (mut net.TcpConn, int, string, map[string]string, bool) !   = unsafe { nil }
}

// ExecState tracks the lifecycle of a single upstream stream execution.
@[heap]
pub struct ExecState {
pub mut:
	io                  Io
	conn                net.TcpConn
	method              string
	stream_type         string
	mapper              string
	field_path          string
	fallback_field_path string
	sse_event           string
	status_code         int
	content_type        string
	response_headers    map[string]string
	headers_written     bool
	line_buf            string
	token_index         int
}
