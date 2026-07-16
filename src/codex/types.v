module codex

import sync
import time
import net.websocket as ws

// ── Codex Target ──

pub struct CodexTarget {
pub:
	platform   string
	message_id string
}

// ── Pending RPC ──

pub struct PendingRpc {
pub:
	instance   string
	method     string
	stream_id  string
	message_id string
}

// ── Read Fallback ──

pub struct ReadFallback {
pub:
	token                int
	stream_id            string
	thread_id            string
	scheduled_at_unix_ms i64
}

// ── Admin Config Snapshot ──

pub struct AdminConfigSnapshot {
pub:
	url             string
	model           string
	effort          string
	cwd             string
	approval_policy string
	sandbox         string
	flush_interval  int
}

// ── Admin Runtime Snapshot ──

pub struct AdminRuntimeSnapshot {
pub:
	enabled            bool
	connected          bool
	initialized        bool
	ws_url             string
	thread_id          string
	active_turns       int
	last_connect_at    i64
	last_disconnect_at i64
	last_error         string
	connect_attempts   i64
	connect_successes  i64
	received_frames    i64
	config             AdminConfigSnapshot
}

// ── Provider Runtime ──

pub struct ProviderRuntime {
pub mut:
	instance                string
	enabled                 bool
	url                     string
	model                   string
	effort                  string
	cwd                     string
	approval_policy         string
	sandbox                 string
	reconnect_delay_ms      int
	flush_interval_ms       int
	connected               bool
	ws_url                  string
	last_connect_at_unix    i64
	last_disconnect_at_unix i64
	last_error              string
	connect_attempts        i64
	connect_successes       i64
	received_frames         i64
	last_frame_at_unix_ms   i64
	initialized             bool
	thread_id               string
	active_stream_id        string
	conn                    &ws.Client = unsafe { nil }
	stream_map              map[string][]CodexTarget
	rpc_id_counter          int
	pending_rpcs            map[int]PendingRpc
	err_bursts              map[string][]string
	err_pending_flushes     map[string]bool
	thread_stream_map       map[string]string
	read_fallback_seq       int
	read_fallbacks          map[string]ReadFallback
}

// ── ProviderRuntime Methods ──

pub fn (rt &ProviderRuntime) pull_url() !string {
	url := rt.url.trim_space()
	if url == '' {
		return error('codex url not configured')
	}
	return url
}

pub fn (rt &ProviderRuntime) reconnect_delay_ms_value() int {
	if rt.reconnect_delay_ms > 0 {
		return rt.reconnect_delay_ms
	}
	return 3000
}

pub fn (rt &ProviderRuntime) is_connected() bool {
	return rt.connected
}

pub fn (rt &ProviderRuntime) is_initialized() bool {
	return rt.initialized
}

pub fn (rt &ProviderRuntime) current_thread_id() string {
	return rt.thread_id
}

pub fn (rt &ProviderRuntime) current_stream_id() string {
	return rt.active_stream_id
}

pub fn (rt &ProviderRuntime) connection() &ws.Client {
	return rt.conn
}

pub fn (rt &ProviderRuntime) config_snapshot() AdminConfigSnapshot {
	return AdminConfigSnapshot{
		url:             rt.url
		model:           rt.model
		effort:          rt.effort
		cwd:             rt.cwd
		approval_policy: rt.approval_policy
		sandbox:         rt.sandbox
		flush_interval:  rt.flush_interval_ms
	}
}

pub fn (mut rt ProviderRuntime) note_connecting() {
	rt.connect_attempts++
}

pub fn (mut rt ProviderRuntime) note_connected(ws_url string) {
	rt.connected = true
	rt.ws_url = ws_url
	rt.last_connect_at_unix = time.now().unix()
	rt.connect_successes++
	rt.last_error = ''
}

pub fn (mut rt ProviderRuntime) note_disconnected(reason string) {
	rt.connected = false
	rt.initialized = false
	rt.last_disconnect_at_unix = time.now().unix()
	rt.last_error = reason
	rt.conn = unsafe { nil }
	rt.thread_id = ''
	rt.read_fallbacks = map[string]ReadFallback{}
}

pub fn (mut rt ProviderRuntime) mark_initialized() {
	rt.initialized = true
}

pub fn (mut rt ProviderRuntime) attach_connection(conn &ws.Client) {
	rt.conn = unsafe { conn }
}

pub fn (mut rt ProviderRuntime) next_rpc_id() int {
	rt.rpc_id_counter++
	return rt.rpc_id_counter
}

pub fn (mut rt ProviderRuntime) remember_pending_rpc(id int, pending PendingRpc) {
	rt.pending_rpcs[id] = pending
}

pub fn (mut rt ProviderRuntime) bind_stream_to_current_thread(stream_id string) string {
	rt.active_stream_id = stream_id
	thread_id := rt.current_thread_id()
	if thread_id != '' {
		rt.thread_stream_map[thread_id] = stream_id
	}
	return thread_id
}

pub fn (mut rt ProviderRuntime) bind_stream_to_thread(thread_id string, stream_id string) string {
	rt.active_stream_id = stream_id
	if thread_id == '' {
		return ''
	}
	rt.thread_id = thread_id
	rt.thread_stream_map[thread_id] = stream_id
	return thread_id
}

// ── Runtime State View ──

pub struct RuntimeStateView {
pub:
	connected          bool
	initialized        bool
	ws_url             string
	thread_id          string
	last_connect_at    i64
	last_disconnect_at i64
	last_error         string
	connect_attempts   i64
	connect_successes  i64
	received_frames    i64
}

pub fn (rt &ProviderRuntime) state_view() RuntimeStateView {
	return RuntimeStateView{
		connected:          rt.connected
		initialized:        rt.initialized
		ws_url:             rt.ws_url
		thread_id:          rt.thread_id
		last_connect_at:    rt.last_connect_at_unix
		last_disconnect_at: rt.last_disconnect_at_unix
		last_error:         rt.last_error
		connect_attempts:   rt.connect_attempts
		connect_successes:  rt.connect_successes
		received_frames:    rt.received_frames
	}
}

// ── Codex State ──

pub struct RuntimeSettings {
pub:
	enabled            bool
	url                string
	model              string
	effort             string
	cwd                string
	approval_policy    string
	sandbox            string
	reconnect_delay_ms int
	flush_interval_ms  int
	ollama_enabled     bool
}

pub struct CodexState {
pub mut:
	mu             sync.Mutex
	runtime        ProviderRuntime
	instances      map[string]ProviderRuntime
	ollama_enabled bool
}

pub fn CodexState.new(settings RuntimeSettings) CodexState {
	return CodexState{
		ollama_enabled: settings.ollama_enabled
		runtime:        ProviderRuntime.new(settings)
		instances:      map[string]ProviderRuntime{}
	}
}

pub fn ProviderRuntime.new(settings RuntimeSettings) ProviderRuntime {
	return ProviderRuntime{
		enabled:             settings.enabled
		url:                 settings.url
		model:               settings.model
		effort:              settings.effort
		cwd:                 settings.cwd
		approval_policy:     settings.approval_policy
		sandbox:             settings.sandbox
		reconnect_delay_ms:  settings.reconnect_delay_ms
		flush_interval_ms:   settings.flush_interval_ms
		pending_rpcs:        map[int]PendingRpc{}
		stream_map:          map[string][]CodexTarget{}
		err_bursts:          map[string][]string{}
		err_pending_flushes: map[string]bool{}
		thread_stream_map:   map[string]string{}
	}
}
