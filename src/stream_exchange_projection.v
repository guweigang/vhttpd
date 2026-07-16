module main

import dispatch
import time
import upstream.transport

pub struct StreamExchangeContext {
pub:
	request_id string
	trace_id   string
	ingress    string
	pipeline   string
	stream_id  string
}

pub fn stream_exchange_identity(ctx StreamExchangeContext, suffix string) dispatch.ExchangeIdentity {
	base_id := if ctx.stream_id.trim_space() != '' {
		ctx.stream_id.trim_space()
	} else if ctx.request_id.trim_space() != '' {
		ctx.request_id.trim_space()
	} else {
		'stream'
	}
	return dispatch.ExchangeIdentity{
		id:         '${base_id}:${suffix}'
		request_id: ctx.request_id
		trace_id:   ctx.trace_id
		parent_id:  base_id
	}
}

pub fn worker_stream_open_exchange(start transport.WorkerStreamFrame, ctx StreamExchangeContext) dispatch.Exchange {
	stream_id := if start.id.trim_space() != '' { start.id.trim_space() } else { ctx.stream_id }
	stream_type := if start.stream_type.trim_space() != '' {
		start.stream_type.trim_space()
	} else {
		'sse'
	}
	mut metadata := start.headers.clone()
	metadata['stream.strategy'] = if start.strategy != '' { start.strategy } else { 'direct' }
	metadata['stream.type'] = stream_type
	metadata['stream.status'] = '${if start.status > 0 { start.status } else { 200 }}'
	metadata['stream.content_type'] = start.content_type
	metadata['stream.source'] = 'worker'
	return dispatch.Exchange{
		identity:      stream_exchange_identity(StreamExchangeContext{
			...ctx
			stream_id: stream_id
		}, 'open')
		kind:          .stream_open
		ingress:       ctx.ingress
		pipeline:      ctx.pipeline
		created_at_ms: time.now().unix_milli()
		headers:       start.headers.clone()
		metadata:      metadata
		payload:       dispatch.StreamPayload{
			session_id: stream_id
		}
	}
}

pub fn worker_stream_chunk_exchange(frame transport.WorkerStreamFrame, ctx StreamExchangeContext) dispatch.Exchange {
	stream_id := if frame.id.trim_space() != '' { frame.id.trim_space() } else { ctx.stream_id }
	mut metadata := map[string]string{}
	metadata['stream.strategy'] = if frame.strategy != '' { frame.strategy } else { 'direct' }
	metadata['stream.source'] = 'worker'
	if frame.sse_id != '' {
		metadata['sse.id'] = frame.sse_id
	}
	if frame.sse_event != '' {
		metadata['sse.event'] = frame.sse_event
	}
	if frame.sse_retry > 0 {
		metadata['sse.retry'] = '${frame.sse_retry}'
	}
	return dispatch.Exchange{
		identity:      stream_exchange_identity(StreamExchangeContext{
			...ctx
			stream_id: stream_id
		}, 'chunk')
		kind:          .stream_chunk
		ingress:       ctx.ingress
		pipeline:      ctx.pipeline
		created_at_ms: time.now().unix_milli()
		headers:       map[string]string{}
		metadata:      metadata
		payload:       dispatch.StreamPayload{
			session_id: stream_id
			chunk:      if frame.data != '' { frame.data } else { frame.data_base64 }
		}
	}
}

pub fn worker_stream_end_exchange(frame transport.WorkerStreamFrame, ctx StreamExchangeContext, reason string) dispatch.Exchange {
	stream_id := if frame.id.trim_space() != '' { frame.id.trim_space() } else { ctx.stream_id }
	mut metadata := map[string]string{}
	metadata['stream.strategy'] = if frame.strategy != '' { frame.strategy } else { 'direct' }
	metadata['stream.source'] = 'worker'
	if frame.error_class != '' {
		metadata['error_class'] = frame.error_class
	}
	return dispatch.Exchange{
		identity:      stream_exchange_identity(StreamExchangeContext{
			...ctx
			stream_id: stream_id
		}, 'end')
		kind:          .stream_end
		ingress:       ctx.ingress
		pipeline:      ctx.pipeline
		created_at_ms: time.now().unix_milli()
		headers:       map[string]string{}
		metadata:      metadata
		payload:       dispatch.StreamPayload{
			session_id: stream_id
			reason:     if reason != '' {
				reason
			} else if frame.error != '' {
				frame.error
			} else {
				'completed'
			}
		}
	}
}

pub fn stream_dispatch_open_exchange(open_resp transport.StreamDispatchResponse, ctx StreamExchangeContext) dispatch.Exchange {
	stream_id := if open_resp.id.trim_space() != '' {
		open_resp.id.trim_space()
	} else {
		ctx.stream_id
	}
	stream_type := if open_resp.stream_type.trim_space() != '' {
		open_resp.stream_type.trim_space()
	} else {
		'sse'
	}
	mut metadata := open_resp.state.clone()
	metadata['stream.strategy'] = 'dispatch'
	metadata['stream.type'] = stream_type
	metadata['stream.source'] = 'dispatch'
	return dispatch.Exchange{
		identity:      stream_exchange_identity(StreamExchangeContext{
			...ctx
			stream_id: stream_id
		}, 'open')
		kind:          .stream_open
		ingress:       ctx.ingress
		pipeline:      ctx.pipeline
		created_at_ms: time.now().unix_milli()
		headers:       open_resp.headers.clone()
		metadata:      metadata
		payload:       dispatch.StreamPayload{
			session_id: stream_id
		}
	}
}

pub fn stream_dispatch_chunk_exchange(chunk transport.StreamDispatchChunk, ctx StreamExchangeContext) dispatch.Exchange {
	mut metadata := map[string]string{}
	metadata['stream.strategy'] = 'dispatch'
	metadata['stream.source'] = 'dispatch'
	if chunk.event != '' {
		metadata['sse.event'] = chunk.event
	}
	if chunk.id != '' {
		metadata['sse.id'] = chunk.id
	}
	if chunk.retry > 0 {
		metadata['sse.retry'] = '${chunk.retry}'
	}
	return dispatch.Exchange{
		identity:      stream_exchange_identity(ctx, 'chunk')
		kind:          .stream_chunk
		ingress:       ctx.ingress
		pipeline:      ctx.pipeline
		created_at_ms: time.now().unix_milli()
		headers:       map[string]string{}
		metadata:      metadata
		payload:       dispatch.StreamPayload{
			session_id: ctx.stream_id
			chunk:      chunk.data
		}
	}
}

pub fn stream_dispatch_end_exchange(ctx StreamExchangeContext, reason string) dispatch.Exchange {
	return dispatch.Exchange{
		identity:      stream_exchange_identity(ctx, 'end')
		kind:          .stream_end
		ingress:       ctx.ingress
		pipeline:      ctx.pipeline
		created_at_ms: time.now().unix_milli()
		headers:       map[string]string{}
		metadata:      {
			'stream.strategy': 'dispatch'
			'stream.source':   'dispatch'
		}
		payload:       dispatch.StreamPayload{
			session_id: ctx.stream_id
			reason:     if reason != '' { reason } else { 'completed' }
		}
	}
}
