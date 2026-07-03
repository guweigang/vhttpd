module main

import dispatch
import json
import runtime_plan
import time

struct RuntimeEventDispatchRequest {
pub:
	ingress    string            @[json: 'ingress']
	pipeline   string            @[json: 'pipeline']
	topic      string            @[json: 'topic']
	name       string            @[json: 'name']
	data       string            @[json: 'data']
	metadata   map[string]string @[json: 'metadata']
	request_id string            @[json: 'request_id']
	trace_id   string            @[json: 'trace_id']
}

struct RuntimeEventDispatchResponse {
pub:
	accepted   bool              @[json: 'accepted']
	ingress    string            @[json: 'ingress']
	pipeline   string            @[json: 'pipeline']
	topic      string            @[json: 'topic']
	name       string            @[json: 'name']
	transform  string            @[json: 'transform']
	trace_id   string            @[json: 'trace_id']
	request_id string            @[json: 'request_id']
	metadata   map[string]string @[json: 'metadata']
}

fn (mut app App) dispatch_runtime_event(raw string, fallback_request_id string, fallback_trace_id string) !RuntimeEventDispatchResponse {
	req := json.decode(RuntimeEventDispatchRequest, raw)!
	trace_id := if req.trace_id.trim_space() != '' {
		req.trace_id.trim_space()
	} else {
		fallback_trace_id
	}
	request_id := if req.request_id.trim_space() != '' {
		req.request_id.trim_space()
	} else {
		fallback_request_id
	}
	mut metadata := req.metadata.clone()
	name := if req.name.trim_space() != '' { req.name.trim_space() } else { req.topic.trim_space() }
	topic := req.topic.trim_space()
	if name != '' {
		metadata['event'] = name
	}
	if topic != '' {
		metadata['topic'] = topic
	}
	pipeline := app.runtime_event_pipeline(req.ingress, req.pipeline, metadata)!
	mut exchange := runtime_event_exchange(request_id, trace_id, pipeline.ingress.str(),
		pipeline.id, topic, name, req.data, metadata)
	mut services := app_dispatch_services(mut app, trace_id)
	result := app.run_transform_refs(pipeline.transforms.map(it.str()), mut services, mut exchange) or {
		app.emit('runtime.event.dispatch_failed', {
			'request_id': request_id
			'trace_id':   trace_id
			'ingress':    pipeline.ingress.str()
			'pipeline':   pipeline.id
			'event':      name
			'topic':      topic
			'error':      err.msg()
		})
		return err
	}
	mut fields := runtime_event_dispatch_fields(request_id, trace_id, pipeline, name, topic,
		result.transform, exchange.metadata)
	transform_refs := pipeline.transforms.map(it.str()).join(',')
	if transform_refs != '' {
		fields['transforms'] = transform_refs
	}
	app.emit('runtime.event.dispatch', fields)
	return RuntimeEventDispatchResponse{
		accepted:   true
		ingress:    pipeline.ingress.str()
		pipeline:   pipeline.id
		topic:      topic
		name:       name
		transform:  if result.transform != '' { result.transform } else { transform_refs }
		trace_id:   trace_id
		request_id: request_id
		metadata:   fields.clone()
	}
}

fn runtime_event_exchange(request_id string, trace_id string, ingress string, pipeline string, topic string, name string, data string, metadata map[string]string) dispatch.Exchange {
	return dispatch.Exchange{
		identity:      dispatch.ExchangeIdentity{
			id:         request_id
			request_id: request_id
			trace_id:   trace_id
		}
		kind:          .event
		ingress:       ingress
		pipeline:      pipeline
		created_at_ms: time.now().unix_milli()
		headers:       map[string]string{}
		metadata:      metadata.clone()
		payload:       dispatch.EventPayload{
			topic:    topic
			name:     name
			data:     data
			metadata: metadata.clone()
		}
	}
}

fn (app App) runtime_event_pipeline(ingress string, pipeline string, metadata map[string]string) !runtime_plan.PipelinePlan {
	if pipeline.trim_space() != '' {
		return app.runtime_event_pipeline_by_id(pipeline.trim_space(), ingress, metadata)!
	}
	ingress_ref := normalize_event_ingress_ref(ingress)
	for candidate in app.plan.pipelines {
		if candidate.ingress.str() != ingress_ref {
			continue
		}
		if runtime_event_match(candidate.match.metadata, metadata) {
			return candidate
		}
	}
	return error('runtime_event_pipeline_not_found:${ingress_ref}')
}

fn (app App) runtime_event_pipeline_by_id(pipeline string, ingress string, metadata map[string]string) !runtime_plan.PipelinePlan {
	pipeline_id := normalize_pipeline_id(pipeline)
	candidate := app.plan.pipeline(pipeline_id) or {
		return error('runtime_event_pipeline_not_found:${pipeline_id}')
	}
	ingress_ref := normalize_event_ingress_ref(ingress)
	if ingress_ref != '' && candidate.ingress.str() != ingress_ref {
		return error('runtime_event_ingress_mismatch:${pipeline_id}:${ingress_ref}')
	}
	if !runtime_event_match(candidate.match.metadata, metadata) {
		return error('runtime_event_metadata_mismatch:${pipeline_id}')
	}
	return candidate
}

fn runtime_event_dispatch_fields(request_id string, trace_id string, pipeline runtime_plan.PipelinePlan, name string, topic string, transform string, metadata map[string]string) map[string]string {
	mut fields := {
		'request_id': request_id
		'trace_id':   trace_id
		'ingress':    pipeline.ingress.str()
		'pipeline':   pipeline.id
		'event':      name
		'topic':      topic
	}
	if transform != '' {
		fields['transform'] = transform
	}
	for key, value in metadata {
		if key != '' && value != '' && key !in fields {
			fields[key] = value
		}
	}
	return fields
}

fn runtime_event_match(required map[string]string, metadata map[string]string) bool {
	for key, expected in required {
		actual := metadata[key] or { return false }
		if !dispatch.match_value_pattern(expected, actual) {
			return false
		}
	}
	return true
}

fn normalize_event_ingress_ref(raw string) string {
	clean := raw.trim_space()
	if clean == '' {
		return ''
	}
	if clean.contains(':') {
		return clean
	}
	return 'adapter:${clean}'
}

fn normalize_pipeline_id(raw string) string {
	clean := raw.trim_space()
	if clean.starts_with('pipeline:') {
		return clean.all_after('pipeline:')
	}
	return clean
}
