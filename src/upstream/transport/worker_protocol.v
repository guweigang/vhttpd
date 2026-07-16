module transport

// Worker HTTP/Stream communication protocol structures.
pub struct WorkerResponse {
pub:
	id      string
	status  int
	body    string
	headers map[string]string
}

pub struct WorkerStreamFrame {
pub:
	mode         string
	strategy     string
	event        string
	id           string
	status       int
	stream_type  string @[json: 'stream_type']
	content_type string @[json: 'content_type']
	headers      map[string]string
	data         string
	data_base64  string @[json: 'data_base64']
	sse_id       string @[json: 'sse_id']
	sse_event    string @[json: 'sse_event']
	sse_retry    int    @[json: 'sse_retry']
	error        string
	error_class  string @[json: 'error_class']
}

pub struct StreamDispatchRequest {
pub:
	mode        string
	strategy    string
	event       string
	id          string
	method      string
	path        string
	body        string
	remote_addr string @[json: 'remote_addr']
	request_id  string @[json: 'request_id']
	trace_id    string @[json: 'trace_id']
	query       map[string]string
	headers     map[string]string
	state       map[string]string
	reason      string
}

pub struct StreamDispatchChunk {
pub:
	event string
	id    string
	data  string
	retry int
}

pub struct StreamDispatchResponse {
pub:
	mode         string
	strategy     string
	event        string
	id           string
	handled      bool
	done         bool
	stream_type  string @[json: 'stream_type']
	content_type string @[json: 'content_type']
	headers      map[string]string
	state        map[string]string
	chunks       []StreamDispatchChunk
	error        string
	error_class  string @[json: 'error_class']
}

pub struct WorkerUpstreamPlanFrame {
pub:
	mode                string
	strategy            string
	event               string
	id                  string
	transport           string
	url                 string
	method              string
	request_headers     map[string]string @[json: 'request_headers']
	body                string
	codec               string
	mapper              string
	output_stream_type  string            @[json: 'output_stream_type']
	output_content_type string            @[json: 'output_content_type']
	response_headers    map[string]string @[json: 'response_headers']
	fixture_path        string            @[json: 'fixture_path']
	name                string
	meta                map[string]string
}

pub struct WorkerRequestPayload {
pub:
	id               string
	method           string
	path             string
	body             string
	scheme           string
	host             string
	port             string
	protocol_version string
	remote_addr      string
	query            map[string]string
	headers          map[string]string
	cookies          map[string]string
	attributes       map[string]string
	server           map[string]string
	uploaded_files   []string
}

pub struct WorkerFrameCodec {}

pub struct WorkerHttpRequestCodec {}

// WebSocket / MCP communication protocol structures.
pub struct WorkerWebSocketFrame {
pub:
	mode            string
	event           string
	id              string
	path            string
	query           map[string]string
	headers         map[string]string
	remote_addr     string @[json: 'remote_addr']
	request_id      string @[json: 'request_id']
	trace_id        string @[json: 'trace_id']
	target_id       string @[json: 'target_id']
	room            string
	key             string
	value           string
	except_id       string @[json: 'except_id']
	rooms           []string
	metadata        map[string]string
	room_members    map[string][]string          @[json: 'room_members']
	member_metadata map[string]map[string]string @[json: 'member_metadata']
	room_counts     map[string]int               @[json: 'room_counts']
	presence_users  map[string][]string          @[json: 'presence_users']
	status          int
	code            int
	reason          string
	opcode          string
	data            string
	error           string
	error_class     string @[json: 'error_class']
}

pub struct WorkerWebSocketDispatchResponse {
pub:
	mode         string
	event        string
	id           string
	accepted     bool
	closed       bool
	commands     []WorkerWebSocketFrame
	affinity_key string @[json: 'affinity_key']
	error        string
	error_class  string @[json: 'error_class']
}

pub struct WorkerWebSocketDispatchCommandFailure {
pub:
	event       string
	id          string
	target_id   string @[json: 'target_id']
	opcode      string
	error       string
	error_class string @[json: 'error_class']
}

pub struct WorkerWebSocketDispatchCommandsResult {
pub:
	close_frame WorkerWebSocketFrame
	has_close   bool
	failures    []WorkerWebSocketDispatchCommandFailure
}

pub struct WorkerWebSocketDispatchFailureEnvelope {
pub:
	event    string
	failures []WorkerWebSocketDispatchCommandFailure
}

pub struct WorkerMcpDispatchRequest {
pub:
	mode                     string
	event                    string
	id                       string
	http_method              string @[json: 'http_method']
	path                     string
	headers                  map[string]string
	protocol_version         string @[json: 'protocol_version']
	accept                   string
	content_type             string @[json: 'content_type']
	body                     string
	jsonrpc_raw              string @[json: 'jsonrpc_raw']
	remote_addr              string @[json: 'remote_addr']
	request_id               string @[json: 'request_id']
	trace_id                 string @[json: 'trace_id']
	session_id               string @[json: 'session_id']
	client_capabilities_json string @[json: 'client_capabilities_json']
}

pub struct WorkerMcpDispatchResponse {
pub:
	mode             string
	event            string
	id               string
	handled          bool
	status           int
	headers          map[string]string
	body             string
	protocol_version string @[json: 'protocol_version']
	session_id       string @[json: 'session_id']
	messages         []string
	commands         []WorkerWebSocketUpstreamCommand
	error            string
	error_class      string @[json: 'error_class']
}

pub struct WorkerWebSocketUpstreamDispatchRequest {
pub:
	mode        string
	event       string
	id          string
	provider    string
	instance    string
	trace_id    string @[json: 'trace_id']
	event_type  string @[json: 'event_type']
	message_id  string @[json: 'message_id']
	target      string
	target_type string @[json: 'target_type']
	payload     string
	received_at i64 @[json: 'received_at']
	metadata    map[string]string
}

pub struct WorkerWebSocketUpstreamCommand {
pub mut:
	event          string
	provider       string
	instance       string
	target         string
	target_type    string @[json: 'target_type']
	message_type   string @[json: 'message_type']
	content        string
	content_fields map[string]string @[json: 'content_fields']
	text           string
	uuid           string
	metadata       map[string]string

	// unified command dispatch structure
	type_       string @[json: 'type']
	stream_id   string @[json: 'stream_id']
	session_key string @[json: 'session_key']
	task_type   string @[json: 'task_type']
	prompt      string
	method      string
	params      string
}

pub struct WorkerWebSocketUpstreamDispatchResponse {
pub:
	mode        string
	event       string
	id          string
	handled     bool
	commands    []WorkerWebSocketUpstreamCommand
	status      int
	headers     map[string]string
	body        string
	error       string
	error_class string @[json: 'error_class']
}
