module main

import upstream.transport
import executor
import veb

@[heap]
struct StreamContextProbe {
mut:
	rows             []string
	response         transport.StreamDispatchResponse
	open_error       bool
	close_error      bool
	open_request     transport.StreamDispatchRequest
	next_request     transport.StreamDispatchRequest
	close_request    transport.StreamDispatchRequest
	event_fields     map[string]string
	rendered_request HttpIngressRequest
	rendered_failure executor.KernelStreamDispatchFailure
}

fn stream_probe_context(mut probe StreamContextProbe) StreamRuntimeContext {
	return StreamRuntimeContext{
		emit_fn:                fn [mut probe] (kind string, fields map[string]string) {
			probe.rows << kind
			probe.event_fields = fields.clone()
		}
		dispatch_open_fn:       fn [mut probe] (method string, path string, body string, remote string, id string, trace string, query map[string]string, headers map[string]string) !transport.StreamDispatchResponse {
			probe.rows << 'open'
			probe.open_request = transport.StreamDispatchRequest{ method: method, path: path, body: body, remote_addr: remote, request_id: id, trace_id: trace, query: query.clone(), headers: headers.clone() }
			if probe.open_error { return error('open transport failure') }
			return probe.response
		}
		dispatch_next_fn:       fn [mut probe] (method string, path string, remote string, id string, trace string, query map[string]string, headers map[string]string, state map[string]string) !transport.StreamDispatchResponse {
			probe.rows << 'next'
			probe.next_request = transport.StreamDispatchRequest{ method: method, path: path, remote_addr: remote, request_id: id, trace_id: trace, query: query.clone(), headers: headers.clone(), state: state.clone() }
			return probe.response
		}
		dispatch_close_fn:      fn [mut probe] (id string, trace string, state map[string]string, reason string) !transport.StreamDispatchResponse {
			probe.rows << 'close'
			probe.close_request = transport.StreamDispatchRequest{ request_id: id, trace_id: trace, state: state.clone(), reason: reason }
			if probe.close_error { return error('close transport failure') }
			return probe.response
		}
		render_open_failure_fn: fn [mut probe] (mut ctx Context, req HttpIngressRequest, failure executor.KernelStreamDispatchFailure) veb.Result {
			probe.rows << 'render'
			probe.rendered_request = req
			probe.rendered_failure = failure
			ctx.req.data = 'rendered'
			return veb.no_result()
		}
	}
}

fn test_stream_context_forwards_injected_callbacks_and_correlations() {
	mut probe := &StreamContextProbe{ response: transport.StreamDispatchResponse{ handled: true, done: true } }
	rt := stream_probe_context(mut probe)
	query := {
		'cursor': 'a'
	}
	headers := {
		'x-test': 'yes'
	}
	state := {
		'session': 's'
	}
	assert (rt.dispatch_open('POST', '/events', 'body', 'remote', 'req', 'trace', query, headers) or { panic(err) }).handled
	assert probe.open_request.method == 'POST'
	assert probe.open_request.path == '/events'
	assert probe.open_request.body == 'body'
	assert probe.open_request.remote_addr == 'remote'
	assert probe.open_request.request_id == 'req'
	assert probe.open_request.trace_id == 'trace'
	assert probe.open_request.query == query
	assert probe.open_request.headers == headers
	assert (rt.dispatch_next('GET', '/next', 'peer', 'req2', 'trace2', query, headers, state) or { panic(err) }).done
	assert probe.next_request.method == 'GET'
	assert probe.next_request.path == '/next'
	assert probe.next_request.remote_addr == 'peer'
	assert probe.next_request.request_id == 'req2'
	assert probe.next_request.trace_id == 'trace2'
	assert probe.next_request.query == query
	assert probe.next_request.headers == headers
	assert probe.next_request.state == state
	rt.dispatch_close('req3', 'trace3', state, 'completed') or { panic(err) }
	assert probe.close_request.request_id == 'req3'
	assert probe.close_request.trace_id == 'trace3'
	assert probe.close_request.state == state
	assert probe.close_request.reason == 'completed'
	rt.emit('http.stream.error', {
		'trace_id': 'trace3'
	})
	assert probe.event_fields == {
		'trace_id': 'trace3'
	}
	assert probe.rows == ['open', 'next', 'close', 'http.stream.error']
}

fn test_stream_dispatch_fallback_and_open_failure_need_no_app() {
	for kind in ['transport', 'unhandled', 'worker_error'] {
		mut probe := &StreamContextProbe{
			open_error: kind == 'transport'
			response:   transport.StreamDispatchResponse{
				event: if kind == 'worker_error' {
					'error'
				} else {
					'open'
				}
				error: 'worker failed'
			}
		}
		rt := stream_probe_context(mut probe)
		mut ctx := Context{}
		ctx.req.data = 'body'
		if _result := HttpStreamRuntime.dispatch(rt, mut ctx, 'GET', '/events/sse?cursor=a', 'req', 'trace', 'peer') {
			assert kind == 'worker_error'
			assert probe.rows == ['open', 'render']
			assert probe.rendered_failure.error == 'worker failed'
			assert probe.rendered_failure.error_class == 'worker_runtime_error'
			assert probe.rendered_request.method == 'GET'
			assert probe.rendered_request.path == '/events/sse?cursor=a'
			assert probe.rendered_request.request_id == 'req'
			assert probe.rendered_request.trace_id == 'trace'
			assert ctx.req.data == 'rendered'
		} else {
			assert kind != 'worker_error'
			assert probe.rows == ['open']
		}
		assert probe.open_request.path == '/events/sse'
		assert probe.open_request.query == {
			'cursor': 'a'
		}
	}
}

fn test_stream_best_effort_close_keeps_state_and_swallows_injected_error() {
	mut probe := &StreamContextProbe{ close_error: true }
	rt := stream_probe_context(mut probe)
	DispatchStreamSession.best_effort_close(rt, 'req', 'trace', {
		'cursor': 'last'
	}, 'client_write_error')
	assert probe.rows == ['close']
	assert probe.close_request.state == {
		'cursor': 'last'
	}
	assert probe.close_request.reason == 'client_write_error'
}
