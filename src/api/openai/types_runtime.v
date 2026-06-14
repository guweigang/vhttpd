module openai

import x.json2

// ── Models API Response Types ──

pub struct OpenAIModelObject {
pub:
	id       string
	object   string = 'model'
	created  int
	owned_by string = 'vhttpd'
}

pub struct OpenAIModelsResponse {
pub:
	object string = 'list'
	data   []OpenAIModelObject
}

// ── Error Response Types ──

pub struct OpenAIErrorBody {
pub:
	message string
	typ     string @[json: 'type']
	code    string
}

pub struct OpenAIErrorResponse {
pub:
	error OpenAIErrorBody
}

// ── Stream Registry ──

@[heap]
pub struct OpenAIResponsesStreamRegistryState {
pub mut:
	completed_body string
}

// ── Plugin / Executor Payload Types ──

pub struct OpenAIPluginChatPayload {
pub:
	method     string
	path       string
	model      string
	stream     bool
	body       string
	base_path  string @[json: 'base_path']
	request_id string @[json: 'request_id']
	trace_id   string @[json: 'trace_id']
}

pub struct OpenAIPluginResponsesPayload {
pub:
	method     string
	path       string
	model      string
	stream     bool
	body       string
	base_path  string @[json: 'base_path']
	request_id string @[json: 'request_id']
	trace_id   string @[json: 'trace_id']
}

pub struct OpenAIPluginModelsPayload {
pub:
	method     string
	path       string
	base_path  string @[json: 'base_path']
	request_id string @[json: 'request_id']
	trace_id   string @[json: 'trace_id']
}

pub struct OpenAIPluginFallbackPayload {
pub:
	method         string
	path           string
	model          string
	stream         bool
	body           string
	base_path      string @[json: 'base_path']
	failed_backend string @[json: 'failed_backend']
	status_code    int    @[json: 'status_code']
	error_code     string @[json: 'error_code']
	error_message  string @[json: 'error_message']
	request_id     string @[json: 'request_id']
	trace_id       string @[json: 'trace_id']
}

pub struct OpenAIExecutorPayload {
pub:
	method          string
	path            string
	model           string
	stream          bool
	body            string
	backend         string
	request_id      string @[json: 'request_id']
	trace_id        string @[json: 'trace_id']
	response_codec  string @[json: 'response_codec']
	output_protocol string @[json: 'output_protocol']
}

pub struct OpenAIPluginMapFramePayload {
pub:
	model           string
	frame           string
	response_codec  string @[json: 'response_codec']
	output_protocol string @[json: 'output_protocol']
	request_id      string @[json: 'request_id']
	trace_id        string @[json: 'trace_id']
}

// ── Chat Completion Types ──

pub struct OpenAIChatStreamDelta {
pub:
	content string
}

pub struct OpenAIChatStreamChoice {
pub:
	index int
	delta OpenAIChatStreamDelta
}

pub struct OpenAIChatStreamChunk {
pub:
	id      string
	object  string = 'chat.completion.chunk'
	created int
	model   string
	choices []OpenAIChatStreamChoice
}

pub struct OpenAIChatMessage {
pub:
	role    string
	content string
}

pub struct OpenAIChatCompletionChoice {
pub:
	index         int
	message       OpenAIChatMessage
	finish_reason string @[json: 'finish_reason']
}

pub struct OpenAIChatCompletionResponse {
pub:
	id      string
	object  string = 'chat.completion'
	created int
	model   string
	choices []OpenAIChatCompletionChoice
}

// ── Frame Mapping ──

pub struct OpenAIFrameMapping {
pub:
	content       string
	tool_calls    []json2.Any
	usage         map[string]int
	done          bool
	handled       bool
	error         string
	finish_reason string
}

pub struct OpenAIResponseBuilder {}

pub struct OpenAIErrorParser {}

pub struct OpenAIUsage {}

pub struct OpenAIBackendAccess {}

pub struct OpenAIHttp {}
