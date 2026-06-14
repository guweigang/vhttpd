module executor

import upstream.transport

struct InProcVjsxHostHttpFetchResponse {
	ok      bool
	status  int
	body    string
	headers map[string]string
	error   string
}

struct InProcVjsxHostHttpFetchRequest {
	url     string
	method  string
	body    string
	headers map[string]string
}

struct InProcVjsxHostBridgeDispatchRequest {
	app         string
	trace_id    string @[json: 'trace_id']
	event_type  string @[json: 'event_type']
	message_id  string @[json: 'message_id']
	target      string
	target_type string @[json: 'target_type']
	payload     string
}

struct InProcVjsxHostWebSocketDispatchRequest {
	commands []transport.WorkerWebSocketFrame
}

struct InProcVjsxHostWebSocketDispatchResponse {
	ok              bool
	has_close       bool   @[json: 'has_close']
	close_code      int    @[json: 'close_code']
	close_reason    string @[json: 'close_reason']
	close_target_id string @[json: 'close_target_id']
	failures        []transport.WorkerWebSocketDispatchCommandFailure
	error           string
}

struct InProcVjsxHostSnapshotRequest {
	scope string
	kind  string
}

struct InProcVjsxHostSessionStoreRequest {
	namespace      string
	op             string
	key            string
	value          string
	expected_value string @[json: 'expected_value']
	expected_found bool   @[json: 'expected_found']
	delete_value   bool   @[json: 'delete_value']
	ttl_ms         i64    @[json: 'ttl_ms']
}

struct InProcVjsxHostSessionStoreResponse {
	ok       bool
	found    bool
	conflict bool
	value    string
	error    string
}
