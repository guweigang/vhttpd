module main
import upstream.transport
import executor

fn test_kernel_dispatch_envelope_from_websocket_upstream() {
	req := transport.WorkerWebSocketUpstreamDispatchRequest{
		id: 'evt-1'
		provider: 'feishu'
		instance: 'main'
		trace_id: 'trace-1'
		event_type: 'feishu.message.receive'
		payload: '{"text":"hi"}'
	}
	env := executor.KernelDispatchEnvelope.from_websocket_upstream(req)
	assert env.kind == .websocket_upstream
	assert env.context.session.provider == 'feishu'
	assert env.context.event == 'feishu.message.receive'
}

fn test_kernel_dispatch_envelope_from_stream_dispatch() {
	req := transport.StreamDispatchRequest{
		id: 'stream-1'
		request_id: 'req-1'
		trace_id: 'trace-1'
		method: 'GET'
		path: '/stream'
		body: ''
		event: 'open'
		strategy: 'dispatch'
	}
	env := executor.KernelDispatchEnvelope.from_stream_dispatch(req)
	assert env.kind == .stream
	assert env.context.session.transport == 'worker_backend'
	assert env.context.session.request_id == 'req-1'
	assert env.context.session.trace_id == 'trace-1'
	assert env.context.session.stream_type == 'dispatch'
	assert env.context.session.source == 'open'
}
