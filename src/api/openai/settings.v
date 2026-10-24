module openai

import config
import state_store

// Configuration can be replaced without moving the response store or its lock.
pub struct Settings {
pub mut:
	enabled         bool
	base_path       string
	default_backend string
	plugin          string
	endpoints       config.OpenAIEndpointsConfig
	backends        map[string]config.OpenAIBackendConfig
	routes          map[string]config.OpenAIRouteConfig
}

pub fn (settings Settings) new_state() OpenaiState {
	mut state := OpenaiState{ responses: state_store.MemoryStateStore.new[OpenAIResponseRecord]() }
	state.apply_settings(settings)
	return state
}

pub fn (mut s OpenaiState) apply_settings(settings Settings) {
	s.enabled = settings.enabled
	s.base_path = settings.base_path
	s.default_backend = settings.default_backend
	s.plugin = settings.plugin
	s.endpoints = settings.endpoints
	s.backends = settings.backends.clone()
	s.routes = settings.routes.clone()
}
