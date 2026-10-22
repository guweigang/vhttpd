module feishu

import config
import log
import time
import rand

// ── Provider Runtime Lifecycle ──

pub fn (mut s FeishuState) ensure(name string) ProviderRuntime {
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	runtime := s.ensure_unlocked(name)
	return ProviderRuntime{ ...runtime, recent_events: runtime.recent_events.clone() }
}

// Caller holds mu. Only the state owner may mutate and publish this value.
fn (mut s FeishuState) ensure_unlocked(name string) ProviderRuntime {
	if runtime := s.runtime[name] {
		return runtime
	}
	runtime := ProviderRuntime.new(name)
	s.runtime[name] = runtime
	return runtime
}

// Explicit replacement owns its event array; activity updates use narrow methods.
pub fn (mut s FeishuState) update_runtime(name string, runtime ProviderRuntime) {
	s.mu.@lock()
	s.runtime[name] = ProviderRuntime{ ...runtime, recent_events: runtime.recent_events.clone() }
	s.mu.unlock()
}

// ── Runtime Metrics ──

pub fn (mut s FeishuState) note_connecting(name string) {
	s.mu.@lock()
	defer { s.mu.unlock() }
	mut runtime := s.ensure_unlocked(name)
	runtime.note_connecting()
	s.runtime[name] = runtime
}

pub fn (mut s FeishuState) note_connected(name string, ws_url string) {
	s.mu.@lock()
	defer { s.mu.unlock() }
	mut runtime := s.ensure_unlocked(name)
	runtime.note_connected(ws_url)
	s.runtime[name] = runtime
}

pub fn (mut s FeishuState) runtime_ws_url(name string) string {
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	if runtime := s.runtime[name] {
		return runtime.ws_url
	}
	return ''
}

pub fn (mut s FeishuState) note_disconnected(name string, reason string) {
	log.error('[feishu] ❌ disconnected: name=${name} reason=${reason}')
	s.mu.@lock()
	defer { s.mu.unlock() }
	mut runtime := s.ensure_unlocked(name)
	runtime.note_disconnected(reason)
	s.runtime[name] = runtime
}

pub fn (mut s FeishuState) note_frame(name string) {
	s.mu.@lock()
	defer { s.mu.unlock() }
	mut runtime := s.ensure_unlocked(name)
	runtime.note_frame()
	s.runtime[name] = runtime
}

pub fn (mut s FeishuState) note_ack(name string) {
	s.mu.@lock()
	defer { s.mu.unlock() }
	mut runtime := s.ensure_unlocked(name)
	runtime.note_ack()
	s.runtime[name] = runtime
}

pub fn (mut s FeishuState) note_send(name string, ok bool) {
	s.mu.@lock()
	defer { s.mu.unlock() }
	mut runtime := s.ensure_unlocked(name)
	runtime.note_send(ok)
	s.runtime[name] = runtime
}

pub fn (mut s FeishuState) note_client_config(instance string, cfg RuntimeClientConfig) {
	s.mu.@lock()
	defer { s.mu.unlock() }
	mut runtime := s.ensure_unlocked(instance)
	runtime.note_client_config(cfg)
	s.runtime[instance] = runtime
}

pub fn (mut s FeishuState) push_event(name string, snapshot RuntimeEventSnapshot) {
	s.mu.@lock()
	defer { s.mu.unlock() }
	mut runtime := s.ensure_unlocked(name)
	runtime.push_event(snapshot, s.recent_event_limit)
	s.runtime[name] = runtime
}

// Token refresh commits only the cache fields, preserving concurrent activity.
pub fn (mut s FeishuState) cache_tenant_access_token(name string, token string, expire_unix i64) {
	s.mu.@lock()
	defer { s.mu.unlock() }
	mut runtime := s.ensure_unlocked(name)
	runtime.cache_tenant_access_token(token, expire_unix)
	s.runtime[name] = runtime
}

pub fn (mut s FeishuState) ping_interval_seconds(instance string) int {
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	if runtime := s.runtime[instance] {
		return runtime.ping_interval_seconds_value()
	}
	return 5
}

// ── App Config Queries ──

pub fn (s &FeishuState) default_app_name() string {
	if 'main' in s.apps {
		return 'main'
	}
	mut names := []string{}
	for name in s.apps.keys() {
		names << name
	}
	names.sort()
	return if names.len > 0 { names[0] } else { '' }
}

pub fn (s &FeishuState) app_names() []string {
	mut names := []string{}
	for name, cfg in s.apps {
		if cfg.app_id.trim_space() == '' && cfg.app_secret.trim_space() == '' {
			continue
		}
		names << name
	}
	names.sort()
	return names
}

pub fn (s &FeishuState) resolve_app_name(raw string) !string {
	name := raw.trim_space()
	if name != '' {
		if name in s.apps {
			return name
		}
		return error('unknown feishu app "${name}"')
	}
	default_name := s.default_app_name()
	if default_name == '' {
		return error('no configured feishu apps')
	}
	return default_name
}

pub fn (s &FeishuState) app_config(name string) !config.FeishuAppConfig {
	resolved := s.resolve_app_name(name)!
	if cfg := s.apps[resolved] {
		return cfg
	}
	return error('missing feishu app config "${resolved}"')
}

// ── Buffer Management ──

pub fn (mut s FeishuState) register_stream_buffer(message_id string, stream_id string, app_name string, receive_id string, receive_id_type string, initial_content string) {
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	s.register_stream_buffer_unlocked(message_id, stream_id, app_name, receive_id, receive_id_type, initial_content)
}

// Caller holds FeishuState.mu across paired buffer/target publication. This
// state-only transition invalidates captured asynchronous completion claims.
pub fn (mut s FeishuState) register_stream_buffer_unlocked(message_id string, stream_id string, app_name string, receive_id string, receive_id_type string, initial_content string) {
	if message_id == '' { return }
	if old := s.buffers[message_id] {
		s.revoke_creations_unlocked(old.stream_id)
		s.revoke_initial_sends_unlocked(old.stream_id)
	}
	s.revoke_creations_unlocked(stream_id)
	s.revoke_initial_sends_unlocked(stream_id)
	s.register_stream_buffer_content_unlocked(message_id, stream_id, app_name, receive_id, receive_id_type, initial_content)
}

// Initial-send commit already owns admission and must not revoke current peers.
fn (mut s FeishuState) register_stream_buffer_content_unlocked(message_id string, stream_id string, app_name string, receive_id string, receive_id_type string, initial_content string) {
	if message_id == '' {
		return
	}
	s.note_initial_send_message_unlocked(message_id)
	now := time.now().unix_milli()
	mut buf := s.buffers[message_id] or {
		StreamBuffer{
			message_id: message_id
			app:        app_name
			last_flush: now
		}
	}
	// A new owner or explicit content reset starts a new buffer lifecycle.
	if (stream_id != '' && buf.stream_id != '' && stream_id != buf.stream_id)
		|| (app_name != '' && buf.app != '' && app_name != buf.app) || initial_content != '' || buf.failure != none || buf.message_only || buf.message_update != none {
		buf.content = ''
		buf.rendered_content = ''
		buf.sealed = false
		buf.next_message_id = ''
		buf.next_identity = none
		buf.segment_index = 1
		buf.rollover_content = ''
	}
	// A registration supersedes any in-flight claim. Same-owner queued text is
	// retained for a later claim when this is only a metadata/context update.
	buf.rollover = none
	buf.finish = none
	buf.failure = none
	if app_name != '' {
		buf.app = app_name
	}
	if stream_id != '' {
		buf.stream_id = stream_id
	}
	if receive_id != '' {
		buf.receive_id = receive_id
	}
	if receive_id_type != '' {
		buf.receive_id_type = receive_id_type
	}
	if buf.segment_index <= 0 {
		buf.segment_index = 1
	}
	if initial_content != '' {
		buf.content = initial_content
		buf.rendered_content = initial_content
		buf.last_delta = now
		buf.last_flush = now
	}
	// Registration invalidates work captured before a rebind or content reset.
	buf.message_update = none
	buf.message_only = false
	buf.sent_publication = none
	buf.identity = &StreamBufferIdentity{}
	buf.bridge_gate = none
	buf.bridge_replica = false
	buf.bridge_operation = none
	buf.bind_pending = false
	buf.bridge_owner = none
	buf.bridge_generation = ''
	buf.bridge_stream = ''
	buf.bridge_app = ''
	buf.generation = rand.uuid_v4()
	s.buffers[message_id] = buf
}

// Capture a live buffer identity under its owner lock. Detached values alone
// cannot authorize a later asynchronous writeback by message ID.
pub fn (mut s FeishuState) buffer_snapshot(message_id string) ?StreamBuffer {
	s.mu.@lock()
	defer { s.mu.unlock() }
	return s.buffer_snapshot_unlocked(message_id)
}

fn (mut s FeishuState) buffer_snapshot_unlocked(message_id string) ?StreamBuffer {
	mut buf := s.buffers[message_id] or { return none }
	if buf.identity == none {
		buf.sent_publication = none
		buf.identity = &StreamBufferIdentity{}
		buf.generation = rand.uuid_v4()
		s.buffers[message_id] = buf
	}
	return buf
}

pub fn (mut s FeishuState) pending_buffer_snapshots(now i64) []StreamBuffer {
	s.mu.@lock()
	defer { s.mu.unlock() }
	mut pending := []StreamBuffer{}
	for key in s.buffers.keys() {
		buf := s.buffers[key] or { continue }
		if !buf.message_only && buf.message_update == none && !buf.bridge_replica && buf.bridge_operation == none && !buf.bind_pending && !buf.sealed && buf.finish == none && buf.failure == none && buf.last_delta >= buf.last_flush && now - buf.last_flush >= 400 && buf.content.trim_space() != '' {
			captured := s.buffer_snapshot_unlocked(key) or { continue }
			pending << captured
		}
	}
	return pending
}

fn (buf StreamBuffer) same_identity(other StreamBuffer) bool {
	if other.message_only || other.message_update != none || other.bind_pending || other.bridge_operation != none {
		return false
	}
	if owner := other.bridge_owner {
		if !bridge_authority_live(owner) { return false }
	}
	identity := buf.identity or { return false }
	current := other.identity or { return false }
	return voidptr(identity) == voidptr(current)
}

pub fn (mut s FeishuState) buffer_snapshot_is_current(captured StreamBuffer) bool {
	s.mu.@lock()
	defer { s.mu.unlock() }
	active := s.buffers[captured.message_id] or { return false }
	return !active.bridge_replica && captured.same_identity(active) && active.finish == none && active.failure == none && active.sealed == captured.sealed && active.content == captured.content
}

pub fn (mut s FeishuState) commit_buffer_preview(captured StreamBuffer, rendered string, now i64) bool {
	s.mu.@lock()
	defer { s.mu.unlock() }
	mut active := s.buffers[captured.message_id] or { return false }
	if active.bridge_replica || !captured.same_identity(active) || active.finish != none || active.failure != none || active.sealed || active.last_flush != captured.last_flush || active.rendered_content != captured.rendered_content {
		return false
	}
	// Record what was sent, but leave a concurrent delta eligible for the next
	// flush, including deltas sharing the same millisecond timestamp.
	active.rendered_content = rendered
	if active.content == captured.content { active.last_flush = now }
	s.buffers[captured.message_id] = active
	return true
}

pub fn (mut s FeishuState) commit_buffer_finish(captured StreamBuffer, rendered string, segment_index int, now i64) bool {
	s.mu.@lock()
	defer { s.mu.unlock() }
	active := s.buffers[captured.message_id] or { return false }
	if active.finish != none { return false }
	return s.commit_buffer_finish_unlocked(captured, rendered, segment_index, now)
}

fn (mut s FeishuState) commit_buffer_finish_unlocked(captured StreamBuffer, rendered string, segment_index int, now i64) bool {
	mut active := s.buffers[captured.message_id] or { return false }
	if active.bridge_replica || !captured.same_identity(active) || active.failure != none || active.sealed != captured.sealed || active.content != captured.content {
		return false
	}
	active.finish = none
	active.content = ''
	active.rendered_content = rendered
	active.last_flush = now
	active.last_delta = now
	active.sealed = true
	active.next_message_id = ''
	active.next_identity = none
	active.segment_index = segment_index
	s.buffers[captured.message_id] = active
	return true
}

pub fn (mut s FeishuState) clear_buffer(message_id string) {
	s.mu.@lock()
	if old := s.buffers[message_id] {
		s.revoke_creations_unlocked(old.stream_id)
		s.revoke_initial_sends_unlocked(old.stream_id)
	}
	s.note_initial_send_message_unlocked(message_id)
	s.buffers.delete(message_id)
	s.mu.unlock()
}

pub fn (mut s FeishuState) stream_id_for_buffer(message_id string) string {
	if message_id == '' {
		return ''
	}
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	if buf := s.buffers[message_id] {
		return buf.stream_id
	}
	return ''
}

// A release reports the ownership captured by the same transition that removes
// the chain. Callers must not look up its stream in a separate preflight read.
pub struct StreamBufferRelease {
pub:
	stream_id string
	cleared   int
}

pub fn (mut s FeishuState) release_buffer_chain(message_id string, expected_stream_id string) ?StreamBufferRelease {
	s.mu.@lock()
	defer { s.mu.unlock() }
	return s.release_buffer_chain_unlocked(message_id, expected_stream_id)
}

// Caller holds FeishuState.mu, including paired routing metadata cleanup.
pub fn (mut s FeishuState) release_buffer_chain_unlocked(message_id string, expected_stream_id string) ?StreamBufferRelease {
	if message_id == '' { return none }
	root := s.buffers[message_id] or {
		s.note_initial_send_message_unlocked(message_id)
		return none
	}
	if expected_stream_id != '' && root.stream_id != expected_stream_id { return none }
	s.revoke_creations_unlocked(root.stream_id)
	s.revoke_initial_sends_unlocked(root.stream_id)
	mut current := message_id
	mut cleared := 0
	for current != '' {
		buf := s.buffers[current] or { break }
		// A stale rollover link does not confer ownership of another stream's buffer.
		if buf.stream_id != root.stream_id || (root.generation != '' && buf.generation != root.generation)
			|| (root.app != '' && buf.app != root.app) {
			break
		}
		s.note_initial_send_message_unlocked(current)
		s.buffers.delete(current)
		cleared++
		if expected := buf.next_identity {
			next := s.buffers[buf.next_message_id] or { break }
			actual := next.identity or { break }
			if voidptr(expected) != voidptr(actual) { break }
		}
		current = buf.next_message_id
	}
	return StreamBufferRelease{ stream_id: root.stream_id, cleared: cleared }
}

pub fn (mut s FeishuState) clear_buffer_chain(message_id string) int {
	released := s.release_buffer_chain(message_id, '') or { return 0 }
	return released.cleared
}

pub fn (mut s FeishuState) clear_stream_buffers(stream_id string) int {
	s.mu.@lock()
	defer { s.mu.unlock() }
	return s.clear_stream_buffers_unlocked(stream_id)
}

// Caller holds FeishuState.mu, including paired routing metadata cleanup.
pub fn (mut s FeishuState) clear_stream_buffers_unlocked(stream_id string) int {
	if stream_id == '' { return 0 }
	s.revoke_creations_unlocked(stream_id)
	s.revoke_initial_sends_unlocked(stream_id)
	mut cleared := 0
	// Select and delete under one lock; linked IDs never expand stream ownership.
	for key in s.buffers.keys() {
		buf := s.buffers[key] or { continue }
		if buf.stream_id == stream_id {
			s.note_initial_send_message_unlocked(key)
			s.buffers.delete(key)
			cleared++
		}
	}
	return cleared
}

// ── Snapshot Aggregation ──

pub fn (mut s FeishuState) chats_snapshot(limit int, offset int, instance_filter string, chat_type_filter string, chat_id_filter string) RuntimeChatsSnapshot {
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	mut latest_by_chat := map[string]RuntimeChatSnapshot{}
	for instance, runtime in s.runtime {
		if instance_filter != '' && instance != instance_filter {
			continue
		}
		for event in runtime.recent_events {
			if event.chat_id.trim_space() == '' {
				continue
			}
			if chat_type_filter != '' && event.chat_type != chat_type_filter {
				continue
			}
			if chat_id_filter != '' && event.chat_id != chat_id_filter {
				continue
			}
			key := '${instance}:${event.chat_id}'
			existing := latest_by_chat[key] or { RuntimeChatSnapshot{} }
			if existing.chat_id == '' || event.received_at >= existing.last_received_at {
				latest_by_chat[key] = RuntimeChatSnapshot{
					instance:          instance
					chat_id:           event.chat_id
					chat_type:         event.chat_type
					target_type:       'chat_id'
					target:            event.chat_id
					last_event_type:   event.event_type
					last_message_id:   event.message_id
					last_message_type: event.message_type
					last_sender_id:    event.sender_id
					last_create_time:  event.create_time
					last_received_at:  event.received_at
					seen_count:        existing.seen_count + 1
				}
			} else {
				latest_by_chat[key] = RuntimeChatSnapshot{
					instance:          existing.instance
					chat_id:           existing.chat_id
					chat_type:         existing.chat_type
					target_type:       existing.target_type
					target:            existing.target
					last_event_type:   existing.last_event_type
					last_message_id:   existing.last_message_id
					last_message_type: existing.last_message_type
					last_sender_id:    existing.last_sender_id
					last_create_time:  existing.last_create_time
					last_received_at:  existing.last_received_at
					seen_count:        existing.seen_count + 1
				}
			}
		}
	}
	mut chats := latest_by_chat.values()
	chats.sort(a.last_received_at > b.last_received_at)
	if offset >= chats.len {
		return RuntimeChatsSnapshot{
			returned_count: 0
			limit:          limit
			offset:         offset
			instance:       instance_filter
			chat_type:      chat_type_filter
			chat_id:        chat_id_filter
			chats:          []RuntimeChatSnapshot{}
		}
	}
	end := if offset + limit < chats.len { offset + limit } else { chats.len }
	return RuntimeChatsSnapshot{
		returned_count: end - offset
		limit:          limit
		offset:         offset
		instance:       instance_filter
		chat_type:      chat_type_filter
		chat_id:        chat_id_filter
		chats:          chats[offset..end].clone()
	}
}

pub fn (mut s FeishuState) totals() (i64, i64, i64, i64, i64, i64) {
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	mut connect_attempts := i64(0)
	mut connect_successes := i64(0)
	mut received_frames := i64(0)
	mut acked_events := i64(0)
	mut messages_sent := i64(0)
	mut send_errors := i64(0)
	for _, runtime in s.runtime {
		connect_attempts += runtime.connect_attempts
		connect_successes += runtime.connect_successes
		received_frames += runtime.received_frames
		acked_events += runtime.acked_events
		messages_sent += runtime.messages_sent
		send_errors += runtime.send_errors
	}
	return connect_attempts, connect_successes, received_frames, acked_events, messages_sent, send_errors
}

// Only the initiating host marks mirrors; remote provider buffers stay writable.
pub fn (mut s FeishuState) mark_bridge_replica_unlocked(message string) {
	mut buf := s.buffers[message] or { return }
	if buf.bridge_owner == none { return }
	buf.bridge_replica = true
	s.buffers[message] = buf
}
