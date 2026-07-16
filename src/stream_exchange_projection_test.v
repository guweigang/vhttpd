module main

import dispatch
import upstream.transport

fn test_worker_stream_frames_project_to_exchange_lifecycle() {
	ctx := StreamExchangeContext{
		request_id: 'req-1'
		trace_id:   'trace-1'
		ingress:    'listener:web'
		pipeline:   'stream.pipeline'
	}
	open := worker_stream_open_exchange(transport.WorkerStreamFrame{
		id:           'worker-stream-1'
		strategy:     'sse'
		status:       201
		stream_type:  'sse'
		content_type: 'text/event-stream'
		headers:      {
			'x-stream': 'yes'
		}
	}, ctx)
	assert open.kind == .stream_open
	assert open.identity.id == 'worker-stream-1:open'
	assert open.identity.parent_id == 'worker-stream-1'
	assert open.identity.trace_id == 'trace-1'
	assert open.metadata['stream.source'] == 'worker'
	assert open.metadata['stream.strategy'] == 'sse'
	assert open.metadata['stream.status'] == '201'
	assert open.headers['x-stream'] == 'yes'
	match open.payload {
		dispatch.StreamPayload {
			assert open.payload.session_id == 'worker-stream-1'
		}
		else {
			assert false
		}
	}

	chunk := worker_stream_chunk_exchange(transport.WorkerStreamFrame{
		id:        'worker-stream-1'
		data:      'hello'
		sse_id:    'sse-1'
		sse_event: 'message'
	}, StreamExchangeContext{
		...ctx
		stream_id: 'worker-stream-1'
	})
	assert chunk.kind == .stream_chunk
	assert chunk.metadata['sse.id'] == 'sse-1'
	assert chunk.metadata['sse.event'] == 'message'
	match chunk.payload {
		dispatch.StreamPayload {
			assert chunk.payload.session_id == 'worker-stream-1'
			assert chunk.payload.chunk == 'hello'
		}
		else {
			assert false
		}
	}

	end := worker_stream_end_exchange(transport.WorkerStreamFrame{
		id: 'worker-stream-1'
	}, StreamExchangeContext{
		...ctx
		stream_id: 'worker-stream-1'
	}, 'client_closed')
	assert end.kind == .stream_end
	match end.payload {
		dispatch.StreamPayload {
			assert end.payload.session_id == 'worker-stream-1'
			assert end.payload.reason == 'client_closed'
		}
		else {
			assert false
		}
	}
}

fn test_dispatch_stream_frames_project_to_exchange_lifecycle() {
	ctx := StreamExchangeContext{
		request_id: 'req-2'
		trace_id:   'trace-2'
		ingress:    'listener:web'
		pipeline:   'dispatch.pipeline'
		stream_id:  'dispatch-1'
	}
	open := stream_dispatch_open_exchange(transport.StreamDispatchResponse{
		id:          'dispatch-1'
		stream_type: 'text'
		headers:     {
			'x-dispatch': 'yes'
		}
		state:       {
			'cursor': '0'
		}
	}, ctx)
	assert open.kind == .stream_open
	assert open.metadata['stream.source'] == 'dispatch'
	assert open.metadata['stream.strategy'] == 'dispatch'
	assert open.metadata['stream.type'] == 'text'
	assert open.metadata['cursor'] == '0'

	chunk := stream_dispatch_chunk_exchange(transport.StreamDispatchChunk{
		id:    'chunk-1'
		event: 'delta'
		data:  'part'
		retry: 25
	}, ctx)
	assert chunk.kind == .stream_chunk
	assert chunk.metadata['sse.event'] == 'delta'
	assert chunk.metadata['sse.retry'] == '25'
	match chunk.payload {
		dispatch.StreamPayload {
			assert chunk.payload.session_id == 'dispatch-1'
			assert chunk.payload.chunk == 'part'
		}
		else {
			assert false
		}
	}

	end := stream_dispatch_end_exchange(ctx, '')
	assert end.kind == .stream_end
	match end.payload {
		dispatch.StreamPayload {
			assert end.payload.session_id == 'dispatch-1'
			assert end.payload.reason == 'completed'
		}
		else {
			assert false
		}
	}
}
