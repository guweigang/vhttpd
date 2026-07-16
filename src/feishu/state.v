module feishu

import config
import log
import time

// ── Provider Runtime Lifecycle ──

pub fn (mut s FeishuState) ensure(name string) ProviderRuntime {
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	if runtime := s.runtime[name] {
		return runtime
	}
	runtime := ProviderRuntime.new(name)
	s.runtime[name] = runtime
	return runtime
}

pub fn (mut s FeishuState) update_runtime(name string, runtime ProviderRuntime) {
	s.mu.@lock()
	s.runtime[name] = runtime
	s.mu.unlock()
}

// ── Runtime Metrics ──

pub fn (mut s FeishuState) note_connecting(name string) {
	mut runtime := s.ensure(name)
	runtime.note_connecting()
	s.update_runtime(name, runtime)
}

pub fn (mut s FeishuState) note_connected(name string, ws_url string) {
	mut runtime := s.ensure(name)
	runtime.note_connected(ws_url)
	s.update_runtime(name, runtime)
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
	mut runtime := s.ensure(name)
	runtime.note_disconnected(reason)
	s.update_runtime(name, runtime)
}

pub fn (mut s FeishuState) note_frame(name string) {
	mut runtime := s.ensure(name)
	runtime.note_frame()
	s.update_runtime(name, runtime)
}

pub fn (mut s FeishuState) note_ack(name string) {
	mut runtime := s.ensure(name)
	runtime.note_ack()
	s.update_runtime(name, runtime)
}

pub fn (mut s FeishuState) note_send(name string, ok bool) {
	mut runtime := s.ensure(name)
	runtime.note_send(ok)
	s.update_runtime(name, runtime)
}

pub fn (mut s FeishuState) note_client_config(instance string, cfg RuntimeClientConfig) {
	mut runtime := s.ensure(instance)
	runtime.note_client_config(cfg)
	s.update_runtime(instance, runtime)
}

pub fn (mut s FeishuState) push_event(name string, snapshot RuntimeEventSnapshot) {
	mut runtime := s.ensure(name)
	runtime.push_event(snapshot, s.recent_event_limit)
	s.update_runtime(name, runtime)
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
	if message_id == '' {
		return
	}
	now := time.now().unix_milli()
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	mut buf := s.buffers[message_id] or {
		StreamBuffer{
			message_id: message_id
			app:        app_name
			last_flush: now
		}
	}
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
	s.buffers[message_id] = buf
}

pub fn (mut s FeishuState) clear_buffer(message_id string) {
	s.mu.@lock()
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

pub fn (mut s FeishuState) clear_buffer_chain(message_id string) int {
	if message_id == '' {
		return 0
	}
	mut cleared := 0
	mut current := message_id
	for current != '' {
		mut next := ''
		s.mu.@lock()
		if buf := s.buffers[current] {
			next = buf.next_message_id
			s.buffers.delete(current)
			cleared++
		}
		s.mu.unlock()
		current = next
	}
	return cleared
}

pub fn (mut s FeishuState) clear_stream_buffers(stream_id string) int {
	if stream_id == '' {
		return 0
	}
	s.mu.@lock()
	keys := s.buffers.keys()
	s.mu.unlock()
	mut cleared := 0
	for key in keys {
		s.mu.@lock()
		buf := s.buffers[key] or {
			s.mu.unlock()
			continue
		}
		s.mu.unlock()
		if buf.stream_id == stream_id {
			cleared += s.clear_buffer_chain(key)
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
