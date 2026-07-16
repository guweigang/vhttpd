module main

import dispatch
import json

struct VjsxTransformerPayload {
	transform_id string
	handler      string
	exchange_id  string
	request_id   string
	trace_id     string
	ingress      string
	pipeline     string
	kind         string
	event_topic  string
	event_name   string
	event_data   string
	headers      map[string]string
	metadata     map[string]string
}

fn vjsx_transformer_event_name(exchange dispatch.Exchange) string {
	match exchange.payload {
		dispatch.EventPayload {
			if exchange.payload.name.trim_space() != '' {
				return exchange.payload.name.trim_space()
			}
			if exchange.payload.topic.trim_space() != '' {
				return exchange.payload.topic.trim_space()
			}
		}
		else {}
	}

	if exchange.pipeline.trim_space() != '' {
		return exchange.pipeline.trim_space()
	}
	return 'transform'
}

fn vjsx_transformer_payload(entry TransformerRuntimeEntry, exchange dispatch.Exchange) VjsxTransformerPayload {
	mut event_topic := ''
	mut event_name := ''
	mut event_data := ''
	match exchange.payload {
		dispatch.EventPayload {
			event_topic = exchange.payload.topic
			event_name = exchange.payload.name
			event_data = exchange.payload.data
		}
		else {}
	}

	return VjsxTransformerPayload{
		transform_id: entry.id
		handler:      entry.handler
		exchange_id:  exchange.identity.id
		request_id:   exchange.identity.request_id
		trace_id:     exchange.identity.trace_id
		ingress:      exchange.ingress
		pipeline:     exchange.pipeline
		kind:         '${exchange.kind}'
		event_topic:  event_topic
		event_name:   event_name
		event_data:   event_data
		headers:      exchange.headers.clone()
		metadata:     exchange.metadata.clone()
	}
}

fn vjsx_transformer_dispatch_request(entry TransformerRuntimeEntry, exchange dispatch.Exchange) VjsxEventDispatchRequest {
	payload := vjsx_transformer_payload(entry, exchange)
	return VjsxEventDispatchRequest{
		event:      vjsx_transformer_event_name(exchange)
		handler:    entry.handler
		executor:   vjsx_transformer_executor(entry)
		payload:    json.encode(payload)
		trace_id:   exchange.identity.trace_id
		request_id: exchange.identity.request_id
	}
}

fn vjsx_transformer_executor(entry TransformerRuntimeEntry) string {
	engine_ref := entry.engine.trim_space()
	if engine_ref.starts_with('engine:') {
		return engine_ref.all_after('engine:')
	}
	return engine_ref
}

fn (mut app App) dispatch_vjsx_transformer(entry TransformerRuntimeEntry, exchange dispatch.Exchange) !dispatch.TransformAction {
	if entry.handler.trim_space() == '' {
		return error('vjsx_transformer_missing_handler:${entry.id}')
	}
	req := vjsx_transformer_dispatch_request(entry, exchange)
	outcome := app.dispatch_vjsx_event(req)!
	if outcome.kind != .response {
		return dispatch.continue_pipeline_action()
	}
	status := if outcome.response.status > 0 { outcome.response.status } else { 200 }
	if status >= 400 {
		return dispatch.reject_action(status, 'vjsx transformer failed', 'vjsx_transformer_failed')
	}
	return dispatch.continue_pipeline_action()
}

fn (mut app App) run_transform_refs(refs []string, mut services dispatch.RuntimeServices, mut exchange dispatch.Exchange) !TransformPipelineResult {
	for ref in refs {
		id := transform_id_from_ref(ref)
		entry := app.transformers.entry(id) or { return error('transformer not registered: ${id}') }
		action := if entry.kind == 'vjsx' {
			app.dispatch_vjsx_transformer(entry, exchange)!
		} else {
			app.transformers.transform(id, mut services, mut exchange)!
		}
		if action.kind != .continue_pipeline {
			return TransformPipelineResult{
				action:    action
				halted:    true
				transform: id
			}
		}
	}
	return TransformPipelineResult{
		action: dispatch.continue_pipeline_action()
	}
}
