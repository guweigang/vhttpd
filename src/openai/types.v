module openai

import config
import state_store

// OpenAIResponseRecord stores a completed OpenAI response.
pub struct OpenAIResponseRecord {
pub:
	id              string
	backend_name    string
	backend_kind    string
	executor        string
	model           string
	status          string
	created_at_unix i64
	updated_at_unix i64
	request_id      string
	trace_id        string
	body            string
}

// OpenaiState holds OpenAI gateway configuration and runtime state.
pub struct OpenaiState {
pub mut:
	enabled          bool
	base_path        string
	default_backend  string
	plugin           string
	endpoints        config.OpenAIEndpointsConfig
	backends         map[string]config.OpenAIBackendConfig
	routes           map[string]config.OpenAIRouteConfig
	responses        state_store.MemoryStateStore[OpenAIResponseRecord]
}
