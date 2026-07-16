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

// OpenAIResolvedRoute maps a request model to a route and upstream backend.
pub struct OpenAIResolvedRoute {
pub:
	route_name     string
	model          string
	backend_name   string
	upstream_model string
	backend        config.OpenAIBackendConfig
}

// OpenAIUpstreamPlan describes an upstream request parsed from plugin JSON.
pub struct OpenAIUpstreamPlan {
pub:
	backend         string
	method          string
	path            string
	body            string
	upstream_model  string @[json: 'upstream_model']
	stream_mode     string @[json: 'stream_mode']
	response_codec  string @[json: 'response_codec']
	output_protocol string @[json: 'output_protocol']
	mapper          string
	headers         map[string]string
}

// OpenAIResolvedPlan represents a fully resolved upstream request plan.
pub struct OpenAIResolvedPlan {
pub:
	backend_name    string
	backend         config.OpenAIBackendConfig
	method          string
	path            string
	body            string
	model           string
	stream_mode     string
	response_codec  string
	output_protocol string
	mapper          string
	headers         map[string]string
}

// OpenAIPluginPlanResult wraps a plugin's plan response.
pub struct OpenAIPluginPlanResult {
pub:
	handled bool
	plan    OpenAIResolvedPlan
}

// OpenAIPluginModelsResult wraps a plugin's models response.
pub struct OpenAIPluginModelsResult {
pub:
	handled bool
	models  []string
}
