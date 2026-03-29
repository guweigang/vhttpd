module main

import json
import log
import time
import net.websocket as ws

const websocket_upstream_provider_codex = 'codex'
const codex_turn_read_fallback_delay_ms = 12000

// ── Codex Turn / Item / Plan state ──────────────────────────────────────

struct CodexPendingRpc {
	instance   string
	method     string
	stream_id  string
	message_id string
}

struct CodexReadFallback {
	token               int
	stream_id           string
	thread_id           string
	scheduled_at_unix_ms i64
}

// ── Codex Provider Runtime ──────────────────────────────────────────────

struct CodexProviderRuntime {
mut:
	instance           string
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
	last_frame_at_unix_ms   i64
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
	read_fallback_seq       int
	read_fallbacks          map[string]CodexReadFallback
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
	rt.read_fallbacks = map[string]CodexReadFallback{}
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
	rt.last_frame_at_unix_ms = time.now().unix_milli()
	return rt.received_frames
}

fn (mut rt CodexProviderRuntime) schedule_read_fallback(stream_id string, thread_id string) CodexReadFallback {
	rt.read_fallback_seq++
	fallback := CodexReadFallback{
		token:                rt.read_fallback_seq
		stream_id:            stream_id
		thread_id:            thread_id
		scheduled_at_unix_ms: time.now().unix_milli()
	}
	rt.read_fallbacks[stream_id] = fallback
	return fallback
}

fn (mut rt CodexProviderRuntime) clear_read_fallback(stream_id string) bool {
	if stream_id == '' || stream_id !in rt.read_fallbacks {
		return false
	}
	rt.read_fallbacks.delete(stream_id)
	return true
}

fn (rt CodexProviderRuntime) read_fallback(stream_id string) (CodexReadFallback, bool) {
	if stream_id == '' || stream_id !in rt.read_fallbacks {
		return CodexReadFallback{}, false
	}
	return rt.read_fallbacks[stream_id], true
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

fn codex_runtime_instance_name(instance string) string {
	name := instance.trim_space()
	if name == '' || name == 'default' {
		return 'main'
	}
	return name
}

fn codex_runtime_build_instance_from_base(base CodexProviderRuntime, instance string) CodexProviderRuntime {
	resolved := codex_runtime_instance_name(instance)
	return CodexProviderRuntime{
		instance:              resolved
		enabled:               base.enabled
		url:                   base.url
		model:                 base.model
		effort:                base.effort
		cwd:                   base.cwd
		approval_policy:       base.approval_policy
		sandbox:               base.sandbox
		reconnect_delay_ms:    base.reconnect_delay_ms
		flush_interval_ms:     base.flush_interval_ms
		stream_map:            map[string][]CodexTarget{}
		pending_rpcs:          map[int]CodexPendingRpc{}
		err_bursts:            map[string][]string{}
		err_pending_flushes:   map[string]bool{}
		thread_stream_map:     map[string]string{}
		read_fallbacks:        map[string]CodexReadFallback{}
	}
}

fn (mut app App) codex_runtime_ensure_instance(instance string) CodexProviderRuntime {
	resolved := codex_runtime_instance_name(instance)
	app.codex_mu.@lock()
	defer {
		app.codex_mu.unlock()
	}
	if resolved == 'main' {
		if app.codex_runtime.instance == '' {
			app.codex_runtime.instance = 'main'
		}
		return app.codex_runtime
	}
	if resolved in app.codex_instances {
		return app.codex_instances[resolved] or { codex_runtime_build_instance_from_base(app.codex_runtime, resolved) }
	}
	mut next := codex_runtime_build_instance_from_base(app.codex_runtime, resolved)
	if spec := app.provider_instance_get('codex', resolved) {
		if spec.config_json.trim_space() != '' {
			cfg := json.decode(CodexConfig, spec.config_json) or { CodexConfig{} }
			if cfg.url.trim_space() != '' {
				next.url = cfg.url
			}
			if cfg.model.trim_space() != '' {
				next.model = cfg.model
			}
			if cfg.effort.trim_space() != '' {
				next.effort = cfg.effort
			}
			if cfg.cwd.trim_space() != '' {
				next.cwd = cfg.cwd
			}
			if cfg.approval_policy.trim_space() != '' {
				next.approval_policy = cfg.approval_policy
			}
			if cfg.sandbox.trim_space() != '' {
				next.sandbox = cfg.sandbox
			}
			if cfg.reconnect_delay_ms > 0 {
				next.reconnect_delay_ms = cfg.reconnect_delay_ms
			}
			if cfg.flush_interval_ms > 0 {
				next.flush_interval_ms = cfg.flush_interval_ms
			}
		}
	}
	app.codex_instances[resolved] = next
	return next
}

fn (mut app App) codex_runtime_snapshot(instance string) CodexProviderRuntime {
	resolved := codex_runtime_instance_name(instance)
	app.codex_mu.@lock()
	defer {
		app.codex_mu.unlock()
	}
	if resolved == 'main' {
		if app.codex_runtime.instance == '' {
			app.codex_runtime.instance = 'main'
		}
		return app.codex_runtime
	}
	if resolved in app.codex_instances {
		return app.codex_instances[resolved] or { codex_runtime_build_instance_from_base(app.codex_runtime, resolved) }
	}
	return codex_runtime_build_instance_from_base(app.codex_runtime, resolved)
}

fn (mut app App) codex_runtime_update(instance string, rt CodexProviderRuntime) {
	resolved := codex_runtime_instance_name(instance)
	app.codex_mu.@lock()
	defer {
		app.codex_mu.unlock()
	}
	if resolved == 'main' {
		app.codex_runtime = rt
		if app.codex_runtime.instance == '' {
			app.codex_runtime.instance = 'main'
		}
		return
	}
	app.codex_instances[resolved] = rt
}

fn (app &App) codex_runtime_known_instances() []string {
	mut names := ['main']
	for name, _ in app.codex_instances {
		if name !in names {
			names << name
		}
	}
	for spec in app.provider_instance_list('codex') {
		if spec.instance !in names {
			names << spec.instance
		}
	}
	names.sort()
	return names
}

fn (mut app App) codex_note_frame_received(instance string) i64 {
	mut rt := app.codex_runtime_ensure_instance(instance)
	count := rt.note_frame_received()
	app.codex_runtime_update(instance, rt)
	return count
}

fn (mut app App) codex_take_pending_rpc(instance string, id int) (CodexPendingRpc, bool) {
	mut rt := app.codex_runtime_ensure_instance(instance)
	pending, ok := rt.take_pending_rpc(id)
	app.codex_runtime_update(instance, rt)
	return pending, ok
}

fn (mut app App) codex_remember_pending_rpc(instance string, id int, pending CodexPendingRpc) {
	mut rt := app.codex_runtime_ensure_instance(instance)
	rt.remember_pending_rpc(id, pending)
	app.codex_runtime_update(instance, rt)
}

fn (mut app App) codex_bind_stream_to_thread(instance string, thread_id string, stream_id string) string {
	mut rt := app.codex_runtime_ensure_instance(instance)
	bound := rt.bind_stream_to_thread(thread_id, stream_id)
	app.codex_runtime_update(instance, rt)
	return bound
}

fn (mut app App) codex_bind_stream_to_current_thread(instance string, stream_id string) string {
	mut rt := app.codex_runtime_ensure_instance(instance)
	bound := rt.bind_stream_to_current_thread(stream_id)
	app.codex_runtime_update(instance, rt)
	return bound
}

fn (mut app App) codex_begin_turn_stream(instance string, stream_id string) string {
	mut rt := app.codex_runtime_ensure_instance(instance)
	thread_id := rt.begin_turn_stream(stream_id)
	app.codex_runtime_update(instance, rt)
	return thread_id
}

fn (mut app App) codex_add_stream_target(instance string, stream_id string, target CodexTarget) {
	mut rt := app.codex_runtime_ensure_instance(instance)
	rt.add_stream_target(stream_id, target)
	app.codex_runtime_update(instance, rt)
}

fn (mut app App) codex_stream_targets(instance string, stream_id string) []CodexTarget {
	return app.codex_runtime_snapshot(instance).stream_targets(stream_id)
}

fn (mut app App) codex_clear_stream_targets(instance string, stream_id string) bool {
	mut rt := app.codex_runtime_ensure_instance(instance)
	cleared := rt.clear_stream_targets(stream_id)
	app.codex_runtime_update(instance, rt)
	return cleared
}

fn (mut app App) codex_clear_stream_targets_any(stream_id string) bool {
	mut cleared := false
	for instance in app.codex_runtime_known_instances() {
		if app.codex_clear_stream_targets(instance, stream_id) {
			cleared = true
		}
	}
	return cleared
}

fn (mut app App) codex_clear_thread_binding(instance string, thread_id string) bool {
	mut rt := app.codex_runtime_ensure_instance(instance)
	cleared := rt.clear_thread_binding(thread_id)
	app.codex_runtime_update(instance, rt)
	return cleared
}

fn (mut app App) codex_clear_thread_binding_any(thread_id string) bool {
	mut cleared := false
	for instance in app.codex_runtime_known_instances() {
		if app.codex_clear_thread_binding(instance, thread_id) {
			cleared = true
		}
	}
	return cleared
}

fn (mut app App) codex_capture_thread_id(instance string, thread_id string) bool {
	mut rt := app.codex_runtime_ensure_instance(instance)
	ok := rt.capture_thread_id(thread_id)
	app.codex_runtime_update(instance, rt)
	return ok
}

fn (mut app App) codex_ensure_thread_id(instance string, thread_id string) bool {
	mut rt := app.codex_runtime_ensure_instance(instance)
	ok := rt.ensure_thread_id(thread_id)
	app.codex_runtime_update(instance, rt)
	return ok
}

fn (mut app App) codex_repair_thread_stream_binding(instance string, thread_id string) string {
	mut rt := app.codex_runtime_ensure_instance(instance)
	stream_id := rt.repair_thread_stream_binding(thread_id)
	app.codex_runtime_update(instance, rt)
	return stream_id
}

fn (mut app App) codex_pending_stream_id(instance string) string {
	return app.codex_runtime_snapshot(instance).pending_stream_id()
}

fn (mut app App) codex_queue_error_burst(instance string, stream_id string, raw_payload string) bool {
	mut rt := app.codex_runtime_ensure_instance(instance)
	should_flush := rt.queue_error_burst(stream_id, raw_payload)
	app.codex_runtime_update(instance, rt)
	return should_flush
}

fn (mut app App) codex_schedule_read_fallback(instance string, stream_id string, thread_id string) (CodexReadFallback, bool) {
	if stream_id.trim_space() == '' || thread_id.trim_space() == '' {
		return CodexReadFallback{}, false
	}
	mut rt := app.codex_runtime_ensure_instance(instance)
	fallback := rt.schedule_read_fallback(stream_id, thread_id)
	app.codex_runtime_update(instance, rt)
	return fallback, true
}

fn (mut app App) codex_clear_read_fallback(instance string, stream_id string) bool {
	mut rt := app.codex_runtime_ensure_instance(instance)
	cleared := rt.clear_read_fallback(stream_id)
	app.codex_runtime_update(instance, rt)
	return cleared
}

fn (mut app App) codex_read_fallback(instance string, stream_id string) (CodexReadFallback, bool) {
	rt := app.codex_runtime_ensure_instance(instance)
	return rt.read_fallback(stream_id)
}

fn (mut app App) codex_take_error_burst(instance string, stream_id string) []string {
	mut rt := app.codex_runtime_ensure_instance(instance)
	errors := rt.take_error_burst(stream_id)
	app.codex_runtime_update(instance, rt)
	return errors
}

fn (mut app App) codex_resolve_instance_for_stream(stream_id string) string {
	if stream_id.trim_space() == '' {
		return 'main'
	}
	for instance in app.codex_runtime_known_instances() {
		rt := app.codex_runtime_snapshot(instance)
		if stream_id in rt.stream_map {
			return instance
		}
		if rt.active_stream_id == stream_id {
			return instance
		}
		if rt.pending_stream_id() == stream_id {
			return instance
		}
		for _, bound_stream_id in rt.thread_stream_map {
			if bound_stream_id == stream_id {
				return instance
			}
		}
	}
	return 'main'
}

fn (mut app App) codex_get_active_stream_id_for_instance(instance string) string {
	return app.codex_runtime_snapshot(instance).current_stream_id()
}

fn (mut app App) codex_find_stream_targets(stream_id string) []CodexTarget {
	instance := app.codex_resolve_instance_for_stream(stream_id)
	return app.codex_stream_targets(instance, stream_id)
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

fn (mut app App) codex_provider_pull_url(instance string) !string {
	rt := app.codex_runtime_ensure_instance(instance)
	return rt.pull_url()
}

fn (mut app App) codex_provider_on_connecting(instance string) {
	mut rt := app.codex_runtime_ensure_instance(instance)
	log.info('[codex] connecting instance=${rt.instance} to ${rt.url} ...')
	rt.note_connecting()
	app.codex_runtime_update(instance, rt)
}

fn (mut app App) codex_provider_on_connected(instance string, ws_url string) {
	log.info('[codex] ✅ connected instance=${codex_runtime_instance_name(instance)} to ${ws_url}')
	mut rt := app.codex_runtime_ensure_instance(instance)
	rt.note_connected(ws_url)
	app.codex_runtime_update(instance, rt)
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


fn (mut app App) codex_provider_on_disconnected(instance string, reason string) {
	log.error('[codex] ❌ disconnected instance=${codex_runtime_instance_name(instance)}: ${reason}')
	mut rt := app.codex_runtime_ensure_instance(instance)
	rt.note_disconnected(reason)
	app.codex_runtime_update(instance, rt)

	// Connections will be cleaned up by PHP as needed or timed out
}

fn (mut app App) codex_provider_reconnect_delay_ms(instance string) int {
	rt := app.codex_runtime_ensure_instance(instance)
	return rt.reconnect_delay_ms_value()
}

fn (mut app App) codex_runtime_config_snapshot(instance string) AdminCodexConfigSnapshot {
	return app.codex_runtime_snapshot(instance).config_snapshot()
}

fn (mut app App) codex_runtime_config(instance string) CodexProviderRuntime {
	return app.codex_runtime_snapshot(instance)
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

fn (mut app App) codex_runtime_state_view(instance string) CodexRuntimeStateView {
	return app.codex_runtime_snapshot(instance).state_view()
}

// ── Admin snapshot ──────────────────────────────────────────────────────

fn (mut app App) admin_codex_snapshot() AdminCodexRuntimeSnapshot {
	rt := app.codex_runtime_state_view('main')
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
		config:             app.codex_runtime_config_snapshot('main')
	}
}

// ── JSON-RPC encode / decode ────────────────────────────────────────────
// Codex app-server wire format: JSON-RPC 2.0 with "jsonrpc":"2.0" OMITTED.

fn (mut app App) codex_next_rpc_id(instance string) int {
	mut rt := app.codex_runtime_ensure_instance(instance)
	id := rt.next_rpc_id()
	app.codex_runtime_update(instance, rt)
	return id
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

fn (mut app App) codex_provider_handle_text_message(instance string, raw string) {
	frame_count := app.codex_note_frame_received(instance)

	preview := if raw.len > 200 { raw[..200] + '...' } else { raw }
	log.info('[codex] 📩 instance=${codex_runtime_instance_name(instance)} frame #${frame_count}: ${preview}')
	codex_debug_log('frame.raw', raw)

	classification := codex_classify_rpc(raw)

	if classification.is_response {
		app.codex_handle_response(instance, classification, raw)
		return
	}
	if classification.is_notification {
		app.codex_handle_notification(instance, classification.method, raw)
		return
	}
	if classification.is_request {
		// Server-initiated requests (e.g. approval requests)
		// MVP: auto-decline or ignore
		app.emit('codex.server_request', {
			'method':   classification.method
			'id':       classification.id_raw
			'instance': codex_runtime_instance_name(instance)
		})
		return
	}
}

// ── Response handling ───────────────────────────────────────────────────

fn (mut app App) codex_handle_response(instance string, cls CodexRpcClassification, raw string) {
	log.info('[codex] 📨 instance=${codex_runtime_instance_name(instance)} response id=${cls.id_raw} has_error=${cls.has_error}')
	codex_debug_log('response.raw', raw)
	
	// Check for pending RPCs FIRST so we know the stream_id
	id := cls.id_raw.int()
	pending, _ := app.codex_take_pending_rpc(instance, id)

	if cls.has_error {
		if pending.stream_id != '' {
			app.codex_clear_read_fallback(instance, pending.stream_id)
		}
		error_msg := codex_extract_string_field(raw, 'message')
		app.emit('codex.rpc.error', {
			'id':       cls.id_raw
			'error':    error_msg
			'instance': codex_runtime_instance_name(instance)
		})
		
		// If we have a pending rpc with a stream_id, aggregate this error
		if pending.stream_id != '' {
			app.codex_queue_error_dispatch(instance, pending.stream_id, raw)
		} else {
			// Fallback: use active stream
			app.codex_queue_error_dispatch(instance, app.codex_get_active_stream_id_for_instance(instance), raw)
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
				app.codex_capture_thread_id(instance, thread_id)
				log.info('[codex]    ✅ thread_id extracted: ${thread_id}')
				app.emit('codex.thread.created', {
					'thread_id': thread_id
					'instance':  codex_runtime_instance_name(instance)
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
					'turn_id':  turn_id
					'instance': codex_runtime_instance_name(instance)
				})
			}
		}
	}

	if pending.method != '' {
		// Route result back to PHP
		result_raw := if cls.has_error { codex_extract_raw_field(raw, 'error') } else { codex_extract_raw_field(raw, 'result') }
		app.dispatch_codex_rpc_response(instance, pending, result_raw, cls.has_error, raw)
		if pending.method == 'thread/read' {
			app.codex_clear_read_fallback(instance, pending.stream_id)
		}
		if pending.method == 'turn/start' && !cls.has_error {
			thread_id := app.codex_runtime_snapshot(instance).current_thread_id()
			app.codex_spawn_read_fallback(instance, pending.stream_id, thread_id)
		}
	}
}

fn (mut app App) dispatch_codex_rpc_response(instance string, pending CodexPendingRpc, result_raw string, has_error bool, raw string) {
	log.info('[codex] 🏁 dispatch_codex_rpc_response instance=${codex_runtime_instance_name(instance)} method=${pending.method} stream_id=${pending.stream_id} error=${has_error}')
	codex_debug_log('rpc.dispatch.raw_response', raw)
	codex_debug_log('rpc.dispatch.result_raw', result_raw)
	if !app.has_websocket_upstream_logic_executor() {
		log.warn('[codex] ⚠️ websocket_upstream logic executor unavailable, skipping dispatch')
		return
	}

	req := app.kernel_websocket_upstream_dispatch_request(
		'codex-rpc-${time.now().unix_milli()}',
		'codex',
		codex_runtime_instance_name(instance),
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

fn (mut app App) codex_spawn_read_fallback(instance string, stream_id string, thread_id string) {
	fallback, ok := app.codex_schedule_read_fallback(instance, stream_id, thread_id)
	if !ok {
		return
	}
	log.info('[codex] ⏳ scheduled thread/read fallback instance=${codex_runtime_instance_name(instance)} stream_id=${stream_id} thread_id=${thread_id} token=${fallback.token}')
	spawn fn (mut app App, instance_name string, stream_id string, token int) {
		time.sleep(codex_turn_read_fallback_delay_ms * time.millisecond)
		app.codex_fire_read_fallback(instance_name, stream_id, token)
	}(mut app, codex_runtime_instance_name(instance), stream_id, fallback.token)
}

fn (mut app App) codex_fire_read_fallback(instance string, stream_id string, token int) {
	fallback, ok := app.codex_read_fallback(instance, stream_id)
	if !ok || fallback.token != token {
		return
	}
	rt := app.codex_runtime_snapshot(instance)
	if rt.current_stream_id() != stream_id {
		app.codex_clear_read_fallback(instance, stream_id)
		return
	}
	thread_id := if fallback.thread_id != '' { fallback.thread_id } else { rt.current_thread_id() }
	if thread_id == '' {
		app.codex_clear_read_fallback(instance, stream_id)
		return
	}
	app.codex_clear_read_fallback(instance, stream_id)
	log.warn('[codex] 🛟 watchdog triggering thread/read instance=${codex_runtime_instance_name(instance)} stream_id=${stream_id} thread_id=${thread_id}')
	params := '{"threadId":"${thread_id}","includeTurns":true}'
	app.codex_send_rpc(instance, 'thread/read', params, stream_id, '') or {
		log.error('[codex] ❌ watchdog thread/read failed instance=${codex_runtime_instance_name(instance)} stream_id=${stream_id}: ${err}')
	}
}

fn (mut app App) codex_send_rpc(instance string, method string, params string, stream_id string, message_id string) !int {
	resolved_instance := codex_runtime_instance_name(instance)
	id := app.codex_next_rpc_id(resolved_instance)
	app.codex_remember_pending_rpc(resolved_instance, id, CodexPendingRpc{
		instance:   resolved_instance
		method:     method
		stream_id:  stream_id
		message_id: message_id
	})
	
	// 🚨 航空级堵漏：确保 RPC 调用也能建立物理绑定
	if stream_id != '' {
		explicit_thread_id := codex_extract_rpc_thread_id(params)
		bound_thread_id := if explicit_thread_id != '' {
			app.codex_bind_stream_to_thread(resolved_instance, explicit_thread_id, stream_id)
		} else {
			app.codex_bind_stream_to_current_thread(resolved_instance, stream_id)
		}
		if bound_thread_id != '' {
			if explicit_thread_id != '' {
				log.info('[codex] 📌 rpc bind: explicit thread=${bound_thread_id} → stream=${stream_id} (via ${method})')
			} else {
				log.info('[codex] 📌 rpc bind: thread=${bound_thread_id} → stream=${stream_id} (via ${method})')
			}
		}
	}
	
	rt := app.codex_runtime_snapshot(resolved_instance)
	mut conn := rt.connection()
	connected := rt.is_connected()

	if isnil(conn) || !connected {
		return error('codex provider not connected')
	}

	msg := codex_encode_request(method, id, params)
	thread_id := codex_extract_rpc_thread_id(params)
	log.info('[codex] 🧭 rpc route instance=${resolved_instance} method=${method} url=${rt.ws_url} thread_id=${thread_id} stream_id=${stream_id}')
	log.info('[codex] 📤 sending custom rpc: ${msg}')
	codex_debug_log('rpc.send.params.${method}', params)
	conn.write_string(msg)!
	return id
}

fn (mut app App) codex_reply_rpc(instance string, id string, result string) ! {
	rt := app.codex_runtime_snapshot(instance)
	mut conn := rt.connection()
	connected := rt.is_connected()

	if isnil(conn) || !connected {
		return error('codex provider not connected')
	}

	msg := '{"id":${id},"result":${result}}'
	log.info('[codex] 📤 sending rpc reply: ${msg}')
	codex_debug_log('rpc.reply.result', result)
	conn.write_string(msg)!
}

// ── Notification routing ────────────────────────────────────────────────

fn (mut app App) codex_handle_notification(instance string, method string, raw string) {
	// 1. Transparent logging
	log.info('[codex] 📢 instance=${codex_runtime_instance_name(instance)} notification: ${method}')
	codex_debug_log('notification.raw.${method}', raw)

	// 2. Minimal gateway-level state sync & Mapping Lookups
	detected_thread_id := codex_extract_string_field(raw, 'threadId')
	
	mut target_stream_id := ''
	if detected_thread_id != '' {
		target_stream_id = app.codex_repair_thread_stream_binding(instance, detected_thread_id)
		if target_stream_id != '' {
			log.info('[codex] 🔗 reactive bind: thread=${detected_thread_id} → stream=${target_stream_id}')
		}
	}

	// 🚨 航空级强化：拦截所有异步错误通知并聚合，防止抢跑或互相覆盖
	is_system_error := method == 'thread/status/changed' && raw.contains('"systemError"')
	is_generic_error := method == 'error'
	if is_system_error || is_generic_error {
		if target_stream_id != '' {
			app.codex_clear_read_fallback(instance, target_stream_id)
		}
		mut t_id := target_stream_id
		if t_id == '' {
			t_id = app.codex_get_active_stream_id_for_instance(instance)
			log.warn('[codex] ⚠️ fallback to active_stream_id=${t_id} for error type=${method}')
		} else {
			log.error('[codex] 🚨 DETERMINISTIC ERROR: type=${method} thread=${detected_thread_id} → stream=${t_id}')
		}
		app.codex_queue_error_dispatch(instance, t_id, raw)
		return // Intercepted
	}

	match method {
		'thread/started' {
			if raw.contains('"thread"') {
				if idx := raw.index('"thread"') {
					thread_id := codex_extract_string_field(raw[idx..], 'id')
					if thread_id != '' {
						if app.codex_ensure_thread_id(instance, thread_id) {
							log.info('[codex]    ✅ thread_id sync: ${thread_id}')
						}
					}
				}
			}
		}
		'item/agentMessage/delta' {
			if target_stream_id != '' {
				app.codex_clear_read_fallback(instance, target_stream_id)
			}
			// Keep delta delivery on the PHP side for now so a single renderer owns
			// buffering and flush. Native patching here races with PHP patch/flush and
			// can duplicate content or orphan Feishu buffers.
		}
		else {}
	}

	if method == 'turn/completed' || method == 'turn/started' || method == 'item/completed'
		|| method == 'rawResponseItem/completed' {
		if target_stream_id != '' {
			app.codex_clear_read_fallback(instance, target_stream_id)
		}
	}
	if method == 'thread/status/changed' {
		status_type := codex_extract_string_field(raw, 'type').to_lower()
		if status_type == 'active' && target_stream_id != '' && detected_thread_id != '' {
			app.codex_spawn_read_fallback(instance, target_stream_id, detected_thread_id)
		}
		if (status_type == 'idle' || status_type == 'completed' || status_type == 'error')
			&& target_stream_id != '' {
			app.codex_clear_read_fallback(instance, target_stream_id)
		}
	}

	// 3. Dispatch raw payload to business logic executor.
	if app.has_websocket_upstream_logic_executor() {
		mut stream_id := app.codex_get_active_stream_id_for_instance(instance)
		if stream_id == '' {
			stream_id = app.codex_pending_stream_id(instance)
		}

		req := app.kernel_websocket_upstream_dispatch_request(
			'codex-notif-${time.now().unix_milli()}',
			'codex',
			codex_runtime_instance_name(instance),
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

fn (mut app App) codex_send_initialize(instance string, mut conn ws.Client) ! {
	log.info('[codex] 🤝 sending initialize instance=${codex_runtime_instance_name(instance)} ...')
	id := app.codex_next_rpc_id(instance)
	params := '{"clientInfo":{"name":"codex_vhttpd","title":"vhttpd Codex Integration","version":"0.1.0"},"capabilities":{"experimentalApi":true}}'
	msg := codex_encode_request('initialize', id, params)
	log.info('[codex]    → ${msg}')
	codex_debug_log('rpc.send.params.initialize', params)
	conn.write_string(msg)!
	app.emit('codex.rpc.sent', {
		'method':   'initialize'
		'id':       '${id}'
		'instance': codex_runtime_instance_name(instance)
	})
}

fn (mut app App) codex_send_initialized(instance string, mut conn ws.Client) ! {
	log.info('[codex] 🤝 sending initialized notification instance=${codex_runtime_instance_name(instance)} ...')
	msg := codex_encode_notification('initialized', '{}')
	conn.write_string(msg)!
	mut rt := app.codex_runtime_ensure_instance(instance)
	rt.mark_initialized()
	app.codex_runtime_update(instance, rt)
	app.emit('codex.rpc.sent', {
		'method':   'initialized'
		'instance': codex_runtime_instance_name(instance)
	})
}

fn (mut app App) codex_send_thread_start(instance string, mut conn ws.Client) ! {
	cfg := app.codex_runtime_config(instance)
	rt := app.codex_runtime_snapshot(instance)
	log.info('[codex] 🤝 sending thread/start instance=${codex_runtime_instance_name(instance)} url=${rt.ws_url} cwd=${cfg.cwd} ...')
	id := app.codex_next_rpc_id(instance)
	// thread/start expects kebab-case for top-level sandbox field
	sandbox_wire := codex_format_sandbox(cfg.sandbox, false)
	params := '{"model":"${cfg.model}","cwd":"${cfg.cwd}","approvalPolicy":"${cfg.approval_policy}","sandbox":"${sandbox_wire}"}'
	msg := codex_encode_request('thread/start', id, params)
	log.info('[codex]    → ${msg}')
	codex_debug_log('rpc.send.params.thread/start', params)
	conn.write_string(msg)!
	app.emit('codex.rpc.sent', {
		'method':   'thread/start'
		'id':       '${id}'
		'instance': codex_runtime_instance_name(instance)
	})
}

// Called from run_websocket_upstream_provider after connect + on_connected.
// Sends initialize request, waits briefly for response, then sends initialized.
fn (mut app App) codex_post_connect_handshake(instance string, mut conn ws.Client) {
	app.codex_send_initialize(instance, mut conn) or {
		app.emit('codex.handshake.failed', {
			'phase':    'initialize'
			'instance': codex_runtime_instance_name(instance)
			'error':    '${err}'
		})
		return
	}
	// Small delay to allow the initialize response to arrive via the message callback
	time.sleep(200 * time.millisecond)
	app.codex_send_initialized(instance, mut conn) or {
		app.emit('codex.handshake.failed', {
			'phase':    'initialized'
			'instance': codex_runtime_instance_name(instance)
			'error':    '${err}'
		})
		return
	}

	// Wait a bit and send thread/start to have an active thread
	time.sleep(200 * time.millisecond)
	app.codex_send_thread_start(instance, mut conn) or {
		app.emit('codex.handshake.failed', {
			'phase':    'thread/start'
			'instance': codex_runtime_instance_name(instance)
			'error':    '${err}'
		})
		return
	}

	mut rt := app.codex_runtime_ensure_instance(instance)
	rt.attach_connection(conn)
	app.codex_runtime_update(instance, rt)

	app.emit('codex.handshake.completed', {
		'phase':    'initialized'
		'instance': codex_runtime_instance_name(instance)
	})
}

// ── Generic WebSocket Upstream Provider Implementation ──────────────────

fn (mut app App) codex_provider_send(req WebSocketUpstreamSendRequest) !WebSocketUpstreamSendResult {
	instance := codex_runtime_instance_name(req.instance)
	rt := app.codex_runtime_snapshot(instance)
	mut conn := rt.connection()
	connected := rt.is_connected()

	if isnil(conn) || !connected {
		return error('codex provider not connected')
	}

	conn.write_string(req.text)!

	return WebSocketUpstreamSendResult{
		ok:         true
		provider:   websocket_upstream_provider_codex
		instance:   instance
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
	instance := codex_runtime_instance_name(cmd.instance)
	cfg := app.codex_runtime_config(instance)
	mut rt := app.codex_runtime_ensure_instance(instance)

	// Ensure provider is connected
	if !rt.is_connected() {
		return error('codex provider not connected')
	}
	if !rt.is_initialized() {
		return error('codex provider not initialized')
	}

	stream_id := cmd.correlation.stream_id
	if stream_id == '' {
		return error('codex stream_id is required')
	}

	override_thread_id := cmd.correlation.thread_id
	override_cwd := cmd.working_dir

	// Prefer an explicit thread binding when the caller is resuming a known thread.
	thread_id := if override_thread_id != '' {
		rt.bind_stream_to_thread(override_thread_id, stream_id)
	} else {
		rt.begin_turn_stream(stream_id)
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
		rt.add_stream_target(stream_id, CodexTarget{
			platform:   'feishu'
			message_id: message_id
		})
	}

	// Build JSON-RPC request for turn/start
	id := rt.next_rpc_id()
	rt.remember_pending_rpc(id, CodexPendingRpc{
		instance:   instance
		method:     'turn/start'
		stream_id:  stream_id
		message_id: cmd.response_message_id
	})
	app.codex_runtime_update(instance, rt)

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
	log.info('[codex] 🧭 rpc route instance=${codex_runtime_instance_name(instance)} method=turn/start url=${rt.ws_url} thread_id=${thread_id} stream_id=${stream_id} cwd=${cwd}')
	log.info('[codex]    → turn/start rpc: ${req_msg}')
	codex_debug_log('rpc.send.params.turn/start', params)

	// Send to websocket
	req := WebSocketUpstreamSendRequest{
		provider: 'codex'
		instance: instance
		text:     req_msg
	}
	app.websocket_upstream_send(req)!
	app.emit('codex.turn.requested', {
		'stream_id': stream_id
		'rpc_id':    '${id}'
	})
}

fn (mut app App) codex_queue_error_dispatch(instance string, stream_id_ string, raw_payload string) {
	mut stream_id := stream_id_
	if stream_id == '' {
		// Deterministic recovery from pending RPCs still valid as they are explicitly tied
		stream_id = app.codex_pending_stream_id(instance)
		if stream_id == '' {
			stream_id = app.codex_get_active_stream_id_for_instance(instance)
		}
	}

	if stream_id == '' {
		log.error('[codex] ❌ CRITICAL: cannot queue error, stream_id is still empty after all recovery attempts. Payload: ${raw_payload}')
		return
	}

	log.info('[codex] ⚡️ queuing error for stream_id=${stream_id}')
	should_schedule_flush := app.codex_queue_error_burst(instance, stream_id, raw_payload)
	if !should_schedule_flush {
		return
	}

	// Wait 500ms to collect all simultaneous errors (e.g. status change + rpc error)
	spawn fn (mut app App, instance_name string, s_id string) {
		time.sleep(500 * time.millisecond)
		app.codex_flush_error_burst(instance_name, s_id)
	}(mut app, codex_runtime_instance_name(instance), stream_id)
}

fn (mut app App) codex_flush_error_burst(instance string, stream_id string) {
	errors := app.codex_take_error_burst(instance, stream_id)

	if errors.len == 0 {
		return
	}

	// Pick the first error as base properties, but we'll send all error details to PHP
	log.info('[codex] 💥 flushing error burst for stream_id=${stream_id} (${errors.len} messages)')

	pending := CodexPendingRpc{
		instance:  codex_runtime_instance_name(instance)
		method:    'codex.error_burst'
		stream_id: stream_id
	}

	// Join all error details as a JSON array
	result := json.encode(errors)
	// Use the first raw as original message for any metadata extraction
	app.dispatch_codex_rpc_response(instance, pending, result, true, errors[0])
}
