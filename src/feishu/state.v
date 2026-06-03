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
	runtime := new_provider_runtime(name)
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
