module executor

import json
import log
import upstream.transport
import vjsx

struct InProcVjsxWebSocketUpstreamResult {
	handled  bool
	commands []transport.WorkerWebSocketUpstreamCommand
	response transport.WorkerResponse
}

struct InProcVjsxWebSocketResult {
	accepted     bool
	closed       bool
	commands     []transport.WorkerWebSocketFrame
	affinity_key string @[json: 'affinity_key']
	error        string
	error_class  string @[json: 'error_class']
}

fn InProcVjsxResponseCodec.websocket_upstream_from_js_value(val vjsx.Value, req transport.WorkerWebSocketUpstreamDispatchRequest) transport.WorkerWebSocketUpstreamDispatchResponse {
	raw := val.json_stringify()
	if raw.trim_space() == '' || raw.trim_space() == 'undefined' || raw.trim_space() == 'null' {
		return transport.WorkerWebSocketUpstreamDispatchResponse{
			mode:     'websocket_upstream'
			event:    'result'
			id:       req.id
			handled:  false
			commands: []transport.WorkerWebSocketUpstreamCommand{}
			status:   200
			headers:  map[string]string{}
			body:     ''
		}
	}
	normalized := json.decode(InProcVjsxWebSocketUpstreamResult, raw) or {
		InProcVjsxWebSocketUpstreamResult{}
	}
	return transport.WorkerWebSocketUpstreamDispatchResponse{
		mode:     'websocket_upstream'
		event:    'result'
		id:       req.id
		handled:  normalized.handled
		commands: normalized.commands
		status:   if normalized.response.status > 0 { normalized.response.status } else { 200 }
		headers:  normalized.response.headers.clone()
		body:     normalized.response.body
	}
}

fn InProcVjsxResponseCodec.websocket_from_json(raw string, frame transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchResponse {
	if frame.event in ['open', 'message'] {
		log.debug('[vhttpd] websocket_response decode_begin event=${frame.event} request_id=${frame.request_id} raw_len=${raw.len}')
		if frame.event == 'open' {
			log.debug('[vhttpd] websocket_response decode_raw event=${frame.event} request_id=${frame.request_id} raw=${raw}')
		}
	}
	if raw.trim_space() == '' || raw.trim_space() == 'undefined' || raw.trim_space() == 'null' {
		return transport.WorkerWebSocketDispatchResponse{
			mode:     'websocket_dispatch'
			event:    'result'
			id:       frame.id
			accepted: false
			closed:   false
			commands: []transport.WorkerWebSocketFrame{}
		}
	}
	normalized := json.decode(InProcVjsxWebSocketResult, raw) or { InProcVjsxWebSocketResult{} }
	if frame.event in ['open', 'message'] {
		log.debug('[vhttpd] websocket_response decode_done event=${frame.event} request_id=${frame.request_id} accepted=${normalized.accepted} closed=${normalized.closed} commands=${normalized.commands.len} affinity_key=${normalized.affinity_key} error=${normalized.error} error_class=${normalized.error_class}')
	}
	return transport.WorkerWebSocketDispatchResponse{
		mode:         'websocket_dispatch'
		event:        'result'
		id:           frame.id
		accepted:     normalized.accepted
		closed:       normalized.closed
		commands:     normalized.commands
		affinity_key: normalized.affinity_key
		error:        normalized.error
		error_class:  normalized.error_class
	}
}

fn InProcVjsxResponseCodec.websocket_handler_missing_result(frame transport.WorkerWebSocketFrame) string {
	return json.encode(transport.WorkerWebSocketDispatchResponse{
		mode:     'websocket_dispatch'
		event:    'result'
		id:       frame.id
		accepted: false
		closed:   false
		commands: []transport.WorkerWebSocketFrame{}
	})
}
