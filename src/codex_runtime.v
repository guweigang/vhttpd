module main

import json
import log
import time
import net.websocket as ws

const websocket_upstream_provider_codex = 'codex'

// ── Codex Turn / Item / Plan state ──────────────────────────────────────

struct CodexPendingRpc {
	method     string
	stream_id  string
	message_id string
}

// ── Codex Provider Runtime ──────────────────────────────────────────────

struct CodexProviderRuntime {
mut:
	// ── config (from TOML / CLI) ──
	enabled            bool
	url                string
	model              string
	effort             string
	cwd                string
	approval_policy    string
	sandbox            string
	reconnect_delay_ms int
	flush_interval_ms  int
	// ── connection state ──
	connected               bool
	ws_url                  string
	last_connect_at_unix    i64
	last_disconnect_at_unix i64
	last_error              string
	connect_attempts        i64
	connect_successes       i64
	received_frames         i64
	initialized             bool   // initialize handshake done
	thread_id               string // active thread
	active_stream_id        string // current stream being processed
	conn                    &ws.Client = unsafe { nil }
	// ── runtime state ──
	stream_map              map[string][]CodexTarget // stream_id -> list of targets
	rpc_id_counter          int
	pending_rpcs            map[int]CodexPendingRpc
	err_bursts              map[string][]string
	err_pending_flushes     map[string]bool
	thread_stream_map       map[string]string // thread_id -> stream_id (deterministic mapping)
}

struct AdminCodexRuntimeSnapshot {
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
	config             AdminCodexConfigSnapshot
}

struct AdminCodexConfigSnapshot {
	url             string
	model           string
	effort          string
	cwd             string
	approval_policy string
	sandbox         string
	flush_interval  int
}

fn (rt CodexProviderRuntime) pull_url() !string {
	url := rt.url.trim_space()
	if url == '' {
		return error('codex url not configured')
	}
	return url
}

fn (rt CodexProviderRuntime) reconnect_delay_ms_value() int {
	if rt.reconnect_delay_ms > 0 {
		return rt.reconnect_delay_ms
	}
	return 3000
}

fn (rt CodexProviderRuntime) is_connected() bool {
	return rt.connected
}

fn (rt CodexProviderRuntime) is_initialized() bool {
	return rt.initialized
}

fn (rt CodexProviderRuntime) current_thread_id() string {
	return rt.thread_id
}

fn (rt CodexProviderRuntime) current_stream_id() string {
	return rt.active_stream_id
}

fn (rt CodexProviderRuntime) connection() &ws.Client {
	return rt.conn
}

fn (rt CodexProviderRuntime) config_snapshot() AdminCodexConfigSnapshot {
	return AdminCodexConfigSnapshot{
		url:             rt.url
		model:           rt.model
		effort:          rt.effort
		cwd:             rt.cwd
		approval_policy: rt.approval_policy
		sandbox:         rt.sandbox
		flush_interval:  rt.flush_interval_ms
	}
}

fn (mut rt CodexProviderRuntime) note_connecting() {
	rt.connect_attempts++
}

fn (mut rt CodexProviderRuntime) note_connected(ws_url string) {
	rt.connected = true
	rt.ws_url = ws_url
	rt.last_connect_at_unix = time.now().unix()
	rt.connect_successes++
	rt.last_error = ''
}

fn (mut rt CodexProviderRuntime) note_disconnected(reason string) {
	rt.connected = false
	rt.initialized = false
	rt.last_disconnect_at_unix = time.now().unix()
	rt.last_error = reason
	rt.conn = unsafe { nil }
	rt.thread_id = ''
}

fn (mut rt CodexProviderRuntime) mark_initialized() {
	rt.initialized = true
}

fn (mut rt CodexProviderRuntime) attach_connection(conn &ws.Client) {
	rt.conn = unsafe { conn }
}

fn (mut rt CodexProviderRuntime) next_rpc_id() int {
	rt.rpc_id_counter++
	return rt.rpc_id_counter
}

fn (mut rt CodexProviderRuntime) remember_pending_rpc(id int, pending CodexPendingRpc) {
	rt.pending_rpcs[id] = pending
}

fn (mut rt CodexProviderRuntime) bind_stream_to_current_thread(stream_id string) string {
	rt.active_stream_id = stream_id
	thread_id := rt.current_thread_id()
	if thread_id != '' {
		rt.thread_stream_map[thread_id] = stream_id
	}
	return thread_id
}

fn (mut rt CodexProviderRuntime) bind_stream_to_thread(thread_id string, stream_id string) string {
	rt.active_stream_id = stream_id
	if thread_id == '' {
		return ''
	}
	rt.thread_id = thread_id
	rt.thread_stream_map[thread_id] = stream_id
	return thread_id
}

fn (mut rt CodexProviderRuntime) begin_turn_stream(stream_id string) string {
	thread_id := rt.current_thread_id()
	if thread_id != '' {
		rt.thread_stream_map[thread_id] = stream_id
	}
	rt.active_stream_id = stream_id
	rt.stream_map.delete(stream_id)
	return thread_id
}

fn (mut rt CodexProviderRuntime) add_stream_target(stream_id string, target CodexTarget) {
	rt.stream_map[stream_id] << target
}

fn (mut rt CodexProviderRuntime) remove_stream_target(stream_id string, platform string, message_id string) bool {
	if stream_id == '' {
		return false
	}
	targets := rt.stream_map[stream_id]
	if targets.len == 0 {
		return false
	}
	mut next := []CodexTarget{}
	mut removed := false
	for target in targets {
		if message_id != '' && target.message_id != message_id {
			next << target
			continue
		}
		if platform != '' && target.platform != platform {
			next << target
			continue
		}
		removed = true
	}
	if next.len == 0 {
		rt.stream_map.delete(stream_id)
	} else {
		rt.stream_map[stream_id] = next
	}
	return removed
}

fn (mut rt CodexProviderRuntime) clear_stream_targets(stream_id string) bool {
	if stream_id == '' {
		return false
	}
	if stream_id !in rt.stream_map {
		return false
	}
	rt.stream_map.delete(stream_id)
	if rt.active_stream_id == stream_id {
		rt.active_stream_id = ''
	}
	return true
}

fn (mut rt CodexProviderRuntime) clear_thread_binding(thread_id string) bool {
	if thread_id == '' {
		return false
	}
	mut cleared := false
	if thread_id in rt.thread_stream_map {
		rt.thread_stream_map.delete(thread_id)
		cleared = true
	}
	if rt.thread_id == thread_id {
		rt.thread_id = ''
		cleared = true
	}
	return cleared
}

fn (mut rt CodexProviderRuntime) note_frame_received() i64 {
	rt.received_frames++
	return rt.received_frames
}

fn (mut rt CodexProviderRuntime) take_pending_rpc(id int) (CodexPendingRpc, bool) {
	if id !in rt.pending_rpcs {
		return CodexPendingRpc{}, false
	}
	pending := rt.pending_rpcs[id]
	rt.pending_rpcs.delete(id)
	return pending, true
}

fn (mut rt CodexProviderRuntime) capture_thread_id(thread_id string) bool {
	if thread_id == '' {
		return false
	}
	rt.thread_id = thread_id
	return true
}

fn (mut rt CodexProviderRuntime) ensure_thread_id(thread_id string) bool {
	if thread_id == '' || rt.thread_id != '' {
		return false
	}
	rt.thread_id = thread_id
	return true
}

fn (mut rt CodexProviderRuntime) repair_thread_stream_binding(thread_id string) string {
	if thread_id == '' {
		return ''
	}
	mut target_stream_id := rt.thread_stream_map[thread_id]
	current_stream_id := rt.current_stream_id()
	if target_stream_id == '' && current_stream_id != '' {
		target_stream_id = current_stream_id
		rt.thread_stream_map[thread_id] = target_stream_id
	}
	return target_stream_id
}

fn (rt CodexProviderRuntime) stream_targets(stream_id string) []CodexTarget {
	return rt.stream_map[stream_id].clone()
}

fn (rt CodexProviderRuntime) pending_stream_id() string {
	for _, p in rt.pending_rpcs {
		if p.stream_id != '' {
			return p.stream_id
		}
	}
	return ''
}

fn (mut rt CodexProviderRuntime) queue_error_burst(stream_id string, raw_payload string) bool {
	mut exists := false
	for msg in rt.err_bursts[stream_id] {
		if msg == raw_payload {
			exists = true
			break
		}
	}
	if !exists {
		rt.err_bursts[stream_id] << raw_payload
	}
	if rt.err_pending_flushes[stream_id] {
		return false
	}
	rt.err_pending_flushes[stream_id] = true
	return true
}

fn (mut rt CodexProviderRuntime) take_error_burst(stream_id string) []string {
	errors := rt.err_bursts[stream_id].clone()
	rt.err_bursts.delete(stream_id)
	rt.err_pending_flushes.delete(stream_id)
	return errors
}

// ── Provider lifecycle callbacks ────────────────────────────────────────

// Helper to convert sandbox type for different RPC requirements
fn codex_format_sandbox(val string, to_camel bool) string {
	if to_camel {
		return match val {
			'read-only' { 'readOnly' }
			'workspace-write' { 'workspaceWrite' }
			'danger-full-access' { 'dangerFullAccess' }
			else { val }
		}
	} else {
		return match val {
			'readOnly' { 'read-only' }
			'workspaceWrite' { 'workspace-write' }
			'dangerFullAccess' { 'danger-full-access' }
			else { val }
		}
	}
}

fn (mut app App) codex_provider_enabled() bool {
	return app.provider_enabled('codex')
}

fn (mut app App) codex_provider_pull_url() !string {
	return app.codex_runtime.pull_url()
}

fn (mut app App) codex_provider_on_connecting() {
	log.info('[codex] connecting to ${app.codex_runtime.url} ...')
	app.codex_mu.@lock()
	defer { app.codex_mu.unlock() }
	app.codex_runtime.note_connecting()
}

fn (mut app App) codex_provider_on_connected(ws_url string) {
	log.info('[codex] ✅ connected to ${ws_url}')
	app.codex_mu.@lock()
	defer { app.codex_mu.unlock() }
	app.codex_runtime.note_connected(ws_url)
}

fn codex_ping_loop(mut client ws.Client) {
	for client.get_state() == .open {
		client.ping() or {
			log.error('[codex] ❌ ping failed: ${err}')
			return
		}
		time.sleep(20 * time.second)
	}
}


fn (mut app App) codex_provider_on_disconnected(reason string) {
	log.error('[codex] ❌ disconnected: ${reason}')
	app.codex_mu.@lock()
	defer { app.codex_mu.unlock() }
	app.codex_runtime.note_disconnected(reason)

	// Connections will be cleaned up by PHP as needed or timed out
}

fn (mut app App) codex_provider_reconnect_delay_ms() int {
	return app.codex_runtime.reconnect_delay_ms_value()
}

fn (app &App) codex_runtime_config_snapshot() AdminCodexConfigSnapshot {
	return app.codex_runtime.config_snapshot()
}

fn (app &App) codex_runtime_config() CodexProviderRuntime {
	return app.codex_runtime
}

struct CodexRuntimeStateView {
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

fn (rt CodexProviderRuntime) state_view() CodexRuntimeStateView {
	return CodexRuntimeStateView{
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

fn (mut app App) codex_runtime_state_view() CodexRuntimeStateView {
	app.codex_mu.@lock()
	rt := app.codex_runtime
	app.codex_mu.unlock()
	return rt.state_view()
}

// ── Admin snapshot ──────────────────────────────────────────────────────

fn (mut app App) admin_codex_snapshot() AdminCodexRuntimeSnapshot {
	rt := app.codex_runtime_state_view()
	return AdminCodexRuntimeSnapshot{
		enabled:            app.codex_provider_enabled()
		connected:          rt.connected
		initialized:        rt.initialized
		ws_url:             rt.ws_url
		thread_id:          rt.thread_id
		active_turns:       0
		last_connect_at:    rt.last_connect_at
		last_disconnect_at: rt.last_disconnect_at
		last_error:         rt.last_error
		connect_attempts:   rt.connect_attempts
		connect_successes:  rt.connect_successes
		received_frames:    rt.received_frames
		config:             app.codex_runtime_config_snapshot()
	}
}

// ── JSON-RPC encode / decode ────────────────────────────────────────────
// Codex app-server wire format: JSON-RPC 2.0 with "jsonrpc":"2.0" OMITTED.

fn (mut app App) codex_next_rpc_id() int {
	app.codex_mu.@lock()
	defer { app.codex_mu.unlock() }
	return app.codex_runtime.next_rpc_id()
}

fn codex_encode_request(method string, id int, params string) string {
	if params == '' || params == '{}' {
		return '{"method":"${method}","id":${id},"params":{}}'
	}
	return '{"method":"${method}","id":${id},"params":${params}}'
}

fn codex_encode_notification(method string, params string) string {
	if params == '' || params == '{}' {
		return '{"method":"${method}","params":{}}'
	}
	return '{"method":"${method}","params":${params}}'
}

// Lightweight JSON-RPC message classification using string scanning.
// Avoids full JSON parse for every incoming frame.

struct CodexRpcClassification {
	is_response     bool // has "id" + ("result" or "error"), no "method"
	is_notification bool // has "method", no "id"
	is_request      bool // has "method" + "id" (server-initiated request, e.g. approvals)
	method          string
	id_raw          string // raw id value as string (may be int)
	has_error       bool
}

struct CodexJsonRpcMessage {
	method string
	id     ?int
	params string
	result string
	error  string
}

fn codex_is_response(msg CodexJsonRpcMessage) bool {
	return msg.id != none && msg.method == ''
}

fn codex_classify_rpc(raw string) CodexRpcClassification {
    // Use top-level field detection to avoid matching nested keys like thread.id
    has_method := vhttpd_has_any_top_level_key(raw, ['method'])
    has_id := vhttpd_has_any_top_level_key(raw, ['id'])
    has_result := vhttpd_has_any_top_level_key(raw, ['result'])
    has_error := vhttpd_has_any_top_level_key(raw, ['error'])

	method := if has_method { codex_extract_string_field(raw, 'method') } else { '' }
	id_raw := if has_id { codex_extract_raw_field(raw, 'id') } else { '' }

	if has_method && !has_id {
		return CodexRpcClassification{
			is_notification: true
			method:          method
		}
	}
	if has_method && has_id {
		return CodexRpcClassification{
			is_request: true
			method:     method
			id_raw:     id_raw
		}
	}
	if has_id && (has_result || has_error) {
		return CodexRpcClassification{
			is_response: true
			id_raw:      id_raw
			has_error:   has_error
		}
	}
	return CodexRpcClassification{}
}

// Fast field extractors (avoid full JSON parse for routing)
fn codex_extract_string_field(raw string, field string) string {
	marker := '"${field}"'
	mut idx := raw.index(marker) or { return '' }
	idx += marker.len
	// skip : and optional whitespace
	for idx < raw.len && (raw[idx] == `:` || raw[idx] == ` ` || raw[idx] == `\t` || raw[idx] == `\n` || raw[idx] == `\r`) {
		idx++
	}
	if idx >= raw.len || raw[idx] != `"` {
		return ''
	}
	idx++ // skip opening quote
	start := idx
	for idx < raw.len && raw[idx] != `"` {
		if raw[idx] == `\\` {
			idx++ // skip escaped char
		}
		idx++
	}
	return raw[start..idx]
}

fn codex_extract_rpc_thread_id(params string) string {
	if params == '' || !params.contains('"threadId"') {
		return ''
	}
	return codex_extract_string_field(params, 'threadId')
}

fn codex_extract_raw_field(raw string, field string) string {
	marker := '"${field}"'
	mut idx := raw.index(marker) or { return '' }
	idx += marker.len
	for idx < raw.len && (raw[idx] == `:` || raw[idx] == ` ` || raw[idx] == `\t`) {
		idx++
	}
	if idx >= raw.len {
		return ''
	}
	start := idx
	// value can be number, string, object, array, bool, null
	if raw[idx] == `"` {
		// string value — find closing quote
		idx++
		for idx < raw.len {
			if raw[idx] == `\\` {
				idx++
			} else if raw[idx] == `"` {
				idx++
				break
			}
			idx++
		}
	} else if raw[idx] == `{` || raw[idx] == `[` {
		// object/array value — track nesting while ignoring quoted strings
		mut stack := []u8{cap: 16}
		stack << raw[idx]
		idx++
		mut in_string := false
		mut escaped := false
		for idx < raw.len && stack.len > 0 {
			ch := raw[idx]
			if in_string {
				if escaped {
					escaped = false
				} else if ch == `\\` {
					escaped = true
				} else if ch == `"` {
					in_string = false
				}
				idx++
				continue
			}
			if ch == `"` {
				in_string = true
				idx++
				continue
			}
			if ch == `{` || ch == `[` {
				stack << ch
			} else if ch == `}` {
				if stack.len > 0 && stack[stack.len - 1] == `{` {
					stack.delete(stack.len - 1)
				} else {
					break
				}
			} else if ch == `]` {
				if stack.len > 0 && stack[stack.len - 1] == `[` {
					stack.delete(stack.len - 1)
				} else {
					break
				}
			}
			idx++
		}
	} else {
		// number, bool, null — read until , or } or ]
		for idx < raw.len && raw[idx] != `,` && raw[idx] != `}` && raw[idx] != `]`
			&& raw[idx] != ` ` && raw[idx] != `\n` {
			idx++
		}
	}
	return raw[start..idx].trim_space()
}

// Detect if a top-level field exists (naive but avoids nested matches)
// Deprecated: use the shared top-level JSON key helpers instead.
fn codex_has_top_level_field(raw string, field string) bool {
    return vhttpd_has_top_level_key(raw, field)
}

fn codex_debug_enabled() bool {
	$if prod {
		return false
	}
	return true
}

fn codex_debug_snippet(raw string, limit int) string {
	if raw.len <= limit {
		return raw
	}
	return raw[..limit] + '...'
}

fn codex_debug_log(label string, raw string) {
	if !codex_debug_enabled() {
		return
	}
	log.info('[codex][debug] ${label}: ${codex_debug_snippet(raw, 1600)}')
}

// ── WebSocket text message handler ──────────────────────────────────────

fn (mut app App) codex_provider_handle_text_message(raw string) {
	app.codex_mu.@lock()
	frame_count := app.codex_runtime.note_frame_received()
	app.codex_mu.unlock()

	preview := if raw.len > 200 { raw[..200] + '...' } else { raw }
	log.info('[codex] 📩 frame #${frame_count}: ${preview}')
	codex_debug_log('frame.raw', raw)

	classification := codex_classify_rpc(raw)

	if classification.is_response {
		app.codex_handle_response(classification, raw)
		return
	}
	if classification.is_notification {
		app.codex_handle_notification(classification.method, raw)
		return
	}
	if classification.is_request {
		// Server-initiated requests (e.g. approval requests)
		// MVP: auto-decline or ignore
		app.emit('codex.server_request', {
			'method': classification.method
			'id':     classification.id_raw
		})
		return
	}
}

// ── Response handling ───────────────────────────────────────────────────

fn (mut app App) codex_handle_response(cls CodexRpcClassification, raw string) {
	log.info('[codex] 📨 response id=${cls.id_raw} has_error=${cls.has_error}')
	codex_debug_log('response.raw', raw)
	
	// Check for pending RPCs FIRST so we know the stream_id
	id := cls.id_raw.int()
	app.codex_mu.@lock()
	pending, _ := app.codex_runtime.take_pending_rpc(id)
	app.codex_mu.unlock()

	if cls.has_error {
		error_msg := codex_extract_string_field(raw, 'message')
		app.emit('codex.rpc.error', {
			'id':    cls.id_raw
			'error': error_msg
		})
		
		// If we have a pending rpc with a stream_id, aggregate this error
		if pending.stream_id != '' {
			app.codex_queue_error_dispatch(pending.stream_id, raw)
		} else {
			// Fallback: use active stream
			app.codex_queue_error_dispatch(app.codex_get_active_stream_id(), raw)
		}
		return
	}
	// For thread/start response: extract thread id
	if raw.contains('"thread"') {
		// Use a more specific marker to avoid picking up the top-level "id"
		thread_marker := '"thread"'
		if thread_idx := raw.index(thread_marker) {
			thread_id := codex_extract_string_field(raw[thread_idx..], 'id')
			if thread_id != '' {
				app.codex_mu.@lock()
				app.codex_runtime.capture_thread_id(thread_id)
				app.codex_mu.unlock()
				log.info('[codex]    ✅ thread_id extracted: ${thread_id}')
				app.emit('codex.thread.created', {
					'thread_id': thread_id
				})
			}
		}
	}
	// For turn/start response: extract turn id
	if raw.contains('"turn"') {
		// Avoid top-level "id" (RPC ID)
		if turn_idx := raw.index('"turn"') {
			turn_id := codex_extract_string_field(raw[turn_idx..], 'id')
			if turn_id != '' {
				log.info('[codex]    ✅ turn_id extracted: ${turn_id}')
				app.emit('codex.turn.response', {
					'turn_id': turn_id
				})
			}
		}
	}

	if pending.method != '' {
		// Route result back to PHP
		result_raw := if cls.has_error { codex_extract_raw_field(raw, 'error') } else { codex_extract_raw_field(raw, 'result') }
		app.dispatch_codex_rpc_response(pending, result_raw, cls.has_error, raw)
	}
}

fn (mut app App) dispatch_codex_rpc_response(pending CodexPendingRpc, result_raw string, has_error bool, raw string) {
	log.info('[codex] 🏁 dispatch_codex_rpc_response method=${pending.method} stream_id=${pending.stream_id} error=${has_error}')
	codex_debug_log('rpc.dispatch.raw_response', raw)
	codex_debug_log('rpc.dispatch.result_raw', result_raw)
	if !app.has_websocket_upstream_logic_executor() {
		log.warn('[codex] ⚠️ websocket_upstream logic executor unavailable, skipping dispatch')
		return
	}

	req := app.kernel_websocket_upstream_dispatch_request(
		'codex-rpc-${time.now().unix_milli()}',
		'codex',
		'main',
		pending.stream_id,
		'codex.rpc.response',
		pending.message_id,
		pending.stream_id,
		'stream_id',
		'{"method":"${pending.method}","result":${result_raw},"has_error":${has_error},"raw_response":${raw}}',
		time.now().unix(),
		map[string]string{},
	)

	outcome := app.kernel_dispatch_websocket_upstream_handled(req) or {
		log.error('[codex] ❌ failed to dispatch websocket_upstream: ${err}')
		return
	}
	resp := outcome.response

	if resp.commands.len > 0 {
		log.info('[codex]    ✅ worker returned ${resp.commands.len} commands')
		if outcome.command_error != '' {
			log.error('[codex]    ❌ command execution error: ${outcome.command_error}')
		}
	}
}

fn (mut app App) codex_send_rpc(method string, params string, stream_id string, message_id string) !int {
	id := app.codex_next_rpc_id()
	app.codex_mu.@lock()
	app.codex_runtime.remember_pending_rpc(id, CodexPendingRpc{
		method:     method
		stream_id:  stream_id
		message_id: message_id
	})
	
	// 🚨 航空级堵漏：确保 RPC 调用也能建立物理绑定
	if stream_id != '' {
		explicit_thread_id := codex_extract_rpc_thread_id(params)
		bound_thread_id := if explicit_thread_id != '' {
			app.codex_runtime.bind_stream_to_thread(explicit_thread_id, stream_id)
		} else {
			app.codex_runtime.bind_stream_to_current_thread(stream_id)
		}
		if bound_thread_id != '' {
			if explicit_thread_id != '' {
				log.info('[codex] 📌 rpc bind: explicit thread=${bound_thread_id} → stream=${stream_id} (via ${method})')
			} else {
				log.info('[codex] 📌 rpc bind: thread=${bound_thread_id} → stream=${stream_id} (via ${method})')
			}
		}
	}
	
	mut conn := app.codex_runtime.connection()
	connected := app.codex_runtime.is_connected()
	app.codex_mu.unlock()

	if isnil(conn) || !connected {
		return error('codex provider not connected')
	}

	msg := codex_encode_request(method, id, params)
	log.info('[codex] 📤 sending custom rpc: ${msg}')
	codex_debug_log('rpc.send.params.${method}', params)
	conn.write_string(msg)!
	return id
}

fn (mut app App) codex_reply_rpc(id string, result string) ! {
	app.codex_mu.@lock()
	mut conn := app.codex_runtime.connection()
	connected := app.codex_runtime.is_connected()
	app.codex_mu.unlock()

	if isnil(conn) || !connected {
		return error('codex provider not connected')
	}

	msg := '{"id":${id},"result":${result}}'
	log.info('[codex] 📤 sending rpc reply: ${msg}')
	codex_debug_log('rpc.reply.result', result)
	conn.write_string(msg)!
}

// ── Notification routing ────────────────────────────────────────────────

fn (mut app App) codex_handle_notification(method string, raw string) {
	// 1. Transparent logging
	log.info('[codex] 📢 notification: ${method}')
	codex_debug_log('notification.raw.${method}', raw)

	// 2. Minimal gateway-level state sync & Mapping Lookups
	detected_thread_id := codex_extract_string_field(raw, 'threadId')
	
	mut target_stream_id := ''
	if detected_thread_id != '' {
		app.codex_mu.@lock()
		target_stream_id = app.codex_runtime.repair_thread_stream_binding(detected_thread_id)
		app.codex_mu.unlock()
		if target_stream_id != '' {
			log.info('[codex] 🔗 reactive bind: thread=${detected_thread_id} → stream=${target_stream_id}')
		}
	}

	// 🚨 航空级强化：拦截所有异步错误通知并聚合，防止抢跑或互相覆盖
	is_system_error := method == 'thread/status/changed' && raw.contains('"systemError"')
	is_generic_error := method == 'error'
	if is_system_error || is_generic_error {
		mut t_id := target_stream_id
		if t_id == '' {
			t_id = app.codex_get_active_stream_id()
			log.warn('[codex] ⚠️ fallback to active_stream_id=${t_id} for error type=${method}')
		} else {
			log.error('[codex] 🚨 DETERMINISTIC ERROR: type=${method} thread=${detected_thread_id} → stream=${t_id}')
		}
		app.codex_queue_error_dispatch(t_id, raw)
		return // Intercepted
	}

	match method {
		'thread/started' {
			if raw.contains('"thread"') {
				if idx := raw.index('"thread"') {
					thread_id := codex_extract_string_field(raw[idx..], 'id')
					if thread_id != '' {
						app.codex_mu.@lock()
						if app.codex_runtime.ensure_thread_id(thread_id) {
							log.info('[codex]    ✅ thread_id sync: ${thread_id}')
						}
						app.codex_mu.unlock()
					}
				}
			}
		}
		'item/agentMessage/delta' {
			// Keep delta delivery on the PHP side for now so a single renderer owns
			// buffering and flush. Native patching here races with PHP patch/flush and
			// can duplicate content or orphan Feishu buffers.
		}
		else {}
	}

	// 3. Dispatch raw payload to business logic executor.
	if app.has_websocket_upstream_logic_executor() {
		mut stream_id := app.codex_get_active_stream_id()
		if stream_id == '' {
			app.codex_mu.@lock()
			stream_id = app.codex_runtime.pending_stream_id()
			app.codex_mu.unlock()
		}

		req := app.kernel_websocket_upstream_dispatch_request(
			'codex-notif-${time.now().unix_milli()}',
			'codex',
			'main',
			stream_id,
			'codex.notification',
			'',
			'',
			'',
			raw,
			time.now().unix(),
			map[string]string{},
		)
		outcome := app.kernel_dispatch_websocket_upstream_handled(req) or {
			log.error('[codex] ❌ failed to dispatch codex notification: ${err}')
			return
		}
		resp := outcome.response
		if resp.error != '' {
			log.error('[codex] ❌ codex notification worker error: ${resp.error}')
		}
		log.info('[codex] 🧾 codex notification result: method=${method} handled=${resp.handled} commands=${resp.commands.len} error=${resp.error}')
		if resp.commands.len > 0 {
			if outcome.command_error != '' {
				log.error('[codex] ❌ codex notification command execution error: ${outcome.command_error}')
			}
		}
	}
}


// ── Initialize handshake ────────────────────────────────────────────────
// Must be called right after WebSocket connect, before any other RPC.

fn (mut app App) codex_send_initialize(mut conn ws.Client) ! {
	log.info('[codex] 🤝 sending initialize ...')
	id := app.codex_next_rpc_id()
	params := '{"clientInfo":{"name":"codex_vhttpd","title":"vhttpd Codex Integration","version":"0.1.0"},"capabilities":{"experimentalApi":true}}'
	msg := codex_encode_request('initialize', id, params)
	log.info('[codex]    → ${msg}')
	codex_debug_log('rpc.send.params.initialize', params)
	conn.write_string(msg)!
	app.emit('codex.rpc.sent', {
		'method': 'initialize'
		'id':     '${id}'
	})
}

fn (mut app App) codex_send_initialized(mut conn ws.Client) ! {
	log.info('[codex] 🤝 sending initialized notification ...')
	msg := codex_encode_notification('initialized', '{}')
	conn.write_string(msg)!
	app.codex_mu.@lock()
	app.codex_runtime.mark_initialized()
	app.codex_mu.unlock()
	app.emit('codex.rpc.sent', {
		'method': 'initialized'
	})
}

fn (mut app App) codex_send_thread_start(mut conn ws.Client) ! {
	log.info('[codex] 🤝 sending thread/start ...')
	id := app.codex_next_rpc_id()
	cfg := app.codex_runtime_config()
	// thread/start expects kebab-case for top-level sandbox field
	sandbox_wire := codex_format_sandbox(cfg.sandbox, false)
	params := '{"model":"${cfg.model}","cwd":"${cfg.cwd}","approvalPolicy":"${cfg.approval_policy}","sandbox":"${sandbox_wire}"}'
	msg := codex_encode_request('thread/start', id, params)
	log.info('[codex]    → ${msg}')
	codex_debug_log('rpc.send.params.thread/start', params)
	conn.write_string(msg)!
	app.emit('codex.rpc.sent', {
		'method': 'thread/start'
		'id':     '${id}'
	})
}

// Called from run_websocket_upstream_provider after connect + on_connected.
// Sends initialize request, waits briefly for response, then sends initialized.
fn (mut app App) codex_post_connect_handshake(mut conn ws.Client) {
	app.codex_send_initialize(mut conn) or {
		app.emit('codex.handshake.failed', {
			'phase': 'initialize'
			'error': '${err}'
		})
		return
	}
	// Small delay to allow the initialize response to arrive via the message callback
	time.sleep(200 * time.millisecond)
	app.codex_send_initialized(mut conn) or {
		app.emit('codex.handshake.failed', {
			'phase': 'initialized'
			'error': '${err}'
		})
		return
	}

	// Wait a bit and send thread/start to have an active thread
	time.sleep(200 * time.millisecond)
	app.codex_send_thread_start(mut conn) or {
		app.emit('codex.handshake.failed', {
			'phase': 'thread/start'
			'error': '${err}'
		})
		return
	}

	app.codex_mu.@lock()
	app.codex_runtime.attach_connection(conn)
	app.codex_mu.unlock()

	app.emit('codex.handshake.completed', {
		'phase': 'initialized'
	})
}

// ── Generic WebSocket Upstream Provider Implementation ──────────────────

fn (mut app App) codex_provider_send(req WebSocketUpstreamSendRequest) !WebSocketUpstreamSendResult {
	app.codex_mu.@lock()
	mut conn := app.codex_runtime.connection()
	connected := app.codex_runtime.is_connected()
	app.codex_mu.unlock()

	if isnil(conn) || !connected {
		return error('codex provider not connected')
	}

	conn.write_string(req.text)!

	return WebSocketUpstreamSendResult{
		ok:         true
		provider:   websocket_upstream_provider_codex
		instance:   'main'
		message_id: 'codex-rpc-${time.now().unix_micro()}'
	}
}

fn (mut app App) codex_provider_update(req WebSocketUpstreamSendRequest) !WebSocketUpstreamUpdateResult {
	// Codex as a WebSocket provider doesn't really have "message updates" in the same sense as Feishu,
	// but we might use it to send follow-up notifications.
	res := app.codex_provider_send(req)!
	return WebSocketUpstreamUpdateResult{
		ok:         res.ok
		provider:   res.provider
		instance:   res.instance
		message_id: res.message_id
	}
}

// ── Turn Management ─────────────────────────────────────────────────────

fn (mut app App) codex_start_turn(cmd WorkerWebSocketUpstreamCommand) ! {
	return app.codex_start_turn_normalized(NormalizedCommand.from_worker_command(cmd))
}

fn (mut app App) codex_start_turn_normalized(cmd NormalizedCommand) ! {
	log.info('[codex] 🚀 codex_start_turn stream_id=${cmd.correlation.stream_id} task_type=${cmd.task_type} prompt=${cmd.prompt}')
	cfg := app.codex_runtime_config()
	app.codex_mu.@lock()

	// Ensure provider is connected
	if !app.codex_runtime.is_connected() {
		app.codex_mu.unlock()
		return error('codex provider not connected')
	}
	if !app.codex_runtime.is_initialized() {
		app.codex_mu.unlock()
		return error('codex provider not initialized')
	}

	stream_id := cmd.correlation.stream_id
	if stream_id == '' {
		app.codex_mu.unlock()
		return error('codex stream_id is required')
	}

	override_thread_id := cmd.correlation.thread_id
	override_cwd := cmd.working_dir

	// Prefer an explicit thread binding when the caller is resuming a known thread.
	thread_id := if override_thread_id != '' {
		app.codex_runtime.bind_stream_to_thread(override_thread_id, stream_id)
	} else {
		app.codex_runtime.begin_turn_stream(stream_id)
	}
	if thread_id != '' {
		if override_thread_id != '' {
			log.info('[codex] 📌 deterministic bind: explicit thread=${thread_id} → stream=${stream_id}')
		} else {
			log.info('[codex] 📌 deterministic bind: thread=${thread_id} → stream=${stream_id}')
		}
	}

	// Map stream_id to message_id for gateway routing
	message_id := cmd.response_message_id
	if message_id != '' {
		app.codex_runtime.add_stream_target(stream_id, CodexTarget{
			platform:   'feishu'
			message_id: message_id
		})
	}

	// Build JSON-RPC request for turn/start
	id := app.codex_next_rpc_id()
	app.codex_runtime.remember_pending_rpc(id, CodexPendingRpc{
		method:     'turn/start'
		stream_id:  stream_id
		message_id: cmd.response_message_id
	})

	app.codex_mu.unlock()

	if thread_id == '' {
		return error('no active codex thread available for turn')
	}

	// Create params using threadId and input array as per protocol
	escaped_prompt := cmd.prompt.replace('"', '\\"').replace('\n', '\\n')

	// sandboxPolicy object
	// turn/start sandboxPolicy.type expects camelCase
	sandbox_type_wire := codex_format_sandbox(cfg.sandbox, true)
	mut sandbox_policy := '{"type":"${sandbox_type_wire}"'
	cwd := if override_cwd != '' { override_cwd } else { cfg.cwd }

	if cwd != '' {
		sandbox_policy += ',"writableRoots":["${cwd}"]'
	}
	sandbox_policy += ',"networkAccess":true}'

	mut params := '"threadId":"${thread_id}",'
	params += '"input":[{"type":"text","text":"${escaped_prompt}"}],'
	params += '"effort":"${cfg.effort}",'
	params += '"model":"${cfg.model}",'
	params += '"approvalPolicy":"${cfg.approval_policy}",'
	params += '"sandboxPolicy":${sandbox_policy}'

	if cwd != '' {
		params += ',"cwd":"${cwd}"'
	}

	// Add session info as sessionReference
	if cmd.correlation.session_key != '' {
		params += ',"sessionReference":"${cmd.correlation.session_key}"'
	}

	params = '{${params}}'

	req_msg := codex_encode_request('turn/start', id, params)
	log.info('[codex]    → turn/start rpc: ${req_msg}')
	codex_debug_log('rpc.send.params.turn/start', params)

	// Send to websocket
	req := WebSocketUpstreamSendRequest{
		provider: 'codex'
		instance: 'main'
		text:     req_msg
	}
	app.websocket_upstream_send(req)!
	app.emit('codex.turn.requested', {
		'stream_id': stream_id
		'rpc_id':    '${id}'
	})
}

fn (mut app App) codex_get_active_stream_id() string {
	app.codex_mu.@lock()
	defer { app.codex_mu.unlock() }
	return app.codex_runtime.current_stream_id()
}

fn (mut app App) codex_queue_error_dispatch(stream_id_ string, raw_payload string) {
	mut stream_id := stream_id_
	if stream_id == '' {
		app.codex_mu.@lock()
		// Deterministic recovery from pending RPCs still valid as they are explicitly tied
		stream_id = app.codex_runtime.pending_stream_id()
		if stream_id == '' {
			stream_id = app.codex_runtime.current_stream_id()
		}
		app.codex_mu.unlock()
	}

	if stream_id == '' {
		log.error('[codex] ❌ CRITICAL: cannot queue error, stream_id is still empty after all recovery attempts. Payload: ${raw_payload}')
		return
	}

	log.info('[codex] ⚡️ queuing error for stream_id=${stream_id}')
	app.codex_mu.@lock()
	should_schedule_flush := app.codex_runtime.queue_error_burst(stream_id, raw_payload)
	app.codex_mu.unlock()
	if !should_schedule_flush {
		return
	}

	// Wait 500ms to collect all simultaneous errors (e.g. status change + rpc error)
	spawn fn (mut app App, s_id string) {
		time.sleep(500 * time.millisecond)
		app.codex_flush_error_burst(s_id)
	}(mut app, stream_id)
}

fn (mut app App) codex_flush_error_burst(stream_id string) {
	app.codex_mu.@lock()
	errors := app.codex_runtime.take_error_burst(stream_id)
	app.codex_mu.unlock()

	if errors.len == 0 {
		return
	}

	// Pick the first error as base properties, but we'll send all error details to PHP
	log.info('[codex] 💥 flushing error burst for stream_id=${stream_id} (${errors.len} messages)')

	pending := CodexPendingRpc{
		method:    'codex.error_burst'
		stream_id: stream_id
	}

	// Join all error details as a JSON array
	result := json.encode(errors)
	// Use the first raw as original message for any metadata extraction
	app.dispatch_codex_rpc_response(pending, result, true, errors[0])
}
