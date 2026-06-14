module ws

import command
import executor
import feishu
import net.websocket
import sync
import upstream

// ── WebSocket Dispatch Connection State Machine ──

pub enum DispatchConnPhase {
	opening
	open
	closing
	closed
}

@[heap]
pub struct DispatchConnState {
pub mut:
	phase                  DispatchConnPhase = .opening
	close_notified         bool
	worker_initiated_close bool
	mu                     sync.Mutex
}

pub fn (state &DispatchConnState) phase() DispatchConnPhase {
	state.mu.@lock()
	defer { state.mu.unlock() }
	return state.phase
}

pub fn (state &DispatchConnState) can_process_messages() bool {
	state.mu.@lock()
	defer { state.mu.unlock() }
	return state.phase == .open && !state.close_notified
}

pub fn (state &DispatchConnState) can_send() bool {
	state.mu.@lock()
	defer { state.mu.unlock() }
	return state.phase == .open && !state.close_notified && !state.worker_initiated_close
}

pub fn (state &DispatchConnState) can_queue() bool {
	state.mu.@lock()
	defer { state.mu.unlock() }
	return (state.phase == .opening || state.phase == .open) && !state.close_notified
}

pub fn (state &DispatchConnState) mark_open() bool {
	state.mu.@lock()
	defer { state.mu.unlock() }
	if state.phase != .opening {
		return false
	}
	unsafe { state.phase = .open }
	return true
}

pub fn (state &DispatchConnState) mark_closing() bool {
	state.mu.@lock()
	defer { state.mu.unlock() }
	if state.phase == .closing || state.phase == .closed {
		return false
	}
	unsafe { state.phase = .closing }
	return true
}

pub fn (state &DispatchConnState) begin_worker_close() bool {
	state.mu.@lock()
	defer { state.mu.unlock() }
	if state.phase != .open {
		return false
	}
	unsafe { state.worker_initiated_close = true }
	unsafe { state.phase = .closing }
	return true
}

pub fn (state &DispatchConnState) begin_peer_close() (bool, bool) {
	state.mu.@lock()
	defer { state.mu.unlock() }
	worker_initiated := state.worker_initiated_close
	if state.close_notified || state.phase == .closed {
		return false, worker_initiated
	}
	unsafe { state.close_notified = true }
	unsafe { state.phase = .closing }
	if worker_initiated {
		return false, worker_initiated
	}
	return true, worker_initiated
}

pub fn (state &DispatchConnState) begin_cleanup() bool {
	state.mu.@lock()
	defer { state.mu.unlock() }
	if state.phase != .closing {
		return false
	}
	unsafe { state.phase = .closed }
	return true
}

// ── Hub Types ──

pub struct HubConn {
pub:
	id            string
	worker_socket string
	method        string
	request_id    string
	trace_id      string
	path          string
	query         map[string]string
	headers       map[string]string
	remote_addr   string
pub mut:
	client    &websocket.Client  = unsafe { nil }
	lifecycle &DispatchConnState = unsafe { nil }
}

pub struct HubPendingMessage {
pub:
	data   string
	opcode string
}

pub struct HubSendTarget {
pub:
	id string
pub mut:
	client &websocket.Client = unsafe { nil }
}

pub struct HubDispatchTarget {
pub:
	id          string
	method      string
	request_id  string
	trace_id    string
	path        string
	query       map[string]string
	headers     map[string]string
	remote_addr string
}

// ── Admin Snapshot Types ──

pub struct ConnSnapshot {
pub:
	id         string
	request_id string
	trace_id   string
	path       string
	rooms      []string
	metadata   map[string]string
}

pub struct RoomSnapshot {
pub:
	name         string
	member_count int
	members      []string
}

pub struct RuntimeSnapshot {
pub:
	active_connections   int
	active_rooms         int
	returned_connections int
	returned_rooms       int
	details              bool
	limit                int
	offset               int
	room_filter          string
	conn_id              string
	connections          []ConnSnapshot
	rooms                []RoomSnapshot
}

// ── Upstream Types ──

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

pub struct FixtureRuntime {
pub mut:
	name                    string
	connected               bool
	last_connect_at_unix    i64
	last_disconnect_at_unix i64
	last_error              string
	connect_attempts        i64
	connect_successes       i64
	received_frames         i64
	messages_sent           i64
	send_errors             i64
	recent_events           []UpstreamEventSnapshot
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

// ── Upstream Runtime Session ──

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

// ── WebSocket Hub State ──

pub struct HubState {
pub mut:
	mu                           sync.Mutex
	send_mu                      sync.Mutex
	upstream_mu                  sync.Mutex
	conns                        map[string]HubConn
	room_members                 map[string]map[string]bool
	conn_rooms                   map[string]map[string]bool
	conn_meta                    map[string]map[string]string
	pending                      map[string][]HubPendingMessage
	dispatch_mode                bool
	recent_dispatch_limit        int
	auto_start_dynamic_upstreams bool
	upstream_started             map[string]bool
	fixture_runtime              map[string]FixtureRuntime
	recent_activities            []UpstreamActivitySnapshot
	upstream_sessions            map[string]upstream.UpstreamRuntimeSession
	stat_upstream_plans_total    i64
	stat_upstream_plan_errors_total i64
}

// ── Feishu streaming normalization ──

pub fn (req UpstreamSendRequest) normalize_feishu_streaming() UpstreamSendRequest {
	if req.message_type.trim_space() == 'interactive' {
		return req
	}
	mut normalized := req
	mut markdown := feishu.SendMessageRequest.extract_markdown_text(req.content, req.text,
		req.content_fields)
	if markdown.trim_space() == '' {
		markdown = '⚙️ **处理中...**'
	}
	normalized.message_type = 'interactive'
	normalized.content = feishu.SendMessageRequest.interactive_markdown_card(markdown)
	normalized.text = ''
	normalized.content_fields = map[string]string{}
	return normalized
}

pub fn (req UpstreamSendRequest) normalize_feishu_streaming_for(normalized command.NormalizedCommand) UpstreamSendRequest {
	if normalized.correlation.stream_id.trim_space() == '' {
		return req
	}
	return req.normalize_feishu_streaming()
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
