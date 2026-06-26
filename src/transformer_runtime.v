module main

import dispatch
import feishu
import runtime_plan

struct TransformerRuntimeEntry {
	id           string
	kind         string
	handler      string
	engine       string
	available    bool
	capabilities dispatch.Capabilities
}

struct TransformerRuntimeRegistry {
mut:
	entries map[string]TransformerRuntimeEntry
	native  map[string]NativeTransformer
}

struct TransformerRuntimeHub {
mut:
	registry TransformerRuntimeRegistry
}

struct TransformPipelineResult {
	action    dispatch.TransformAction
	halted    bool
	transform string
}

struct NativeTransformer {
	id           string
	handler      string
	capabilities dispatch.Capabilities
}

fn TransformerRuntimeHub.from_plan(plan runtime_plan.RuntimePlan) TransformerRuntimeHub {
	return TransformerRuntimeHub{
		registry: TransformerRuntimeRegistry.from_plan(plan)
	}
}

fn TransformerRuntimeRegistry.from_plan(plan runtime_plan.RuntimePlan) TransformerRuntimeRegistry {
	mut registry := TransformerRuntimeRegistry{
		entries: map[string]TransformerRuntimeEntry{}
		native:  map[string]NativeTransformer{}
	}
	for id, transform in plan.transforms {
		descriptor := dispatch.transform_descriptor_from_plan(transform)
		engine_ref := if engine := transform.engine { engine.str() } else { '' }
		kind := transform.kind.trim_space().to_lower()
		available := kind in ['native', 'vjsx']
		registry.entries[id] = TransformerRuntimeEntry{
			id:           id
			kind:         kind
			handler:      transform.handler
			engine:       engine_ref
			available:    available
			capabilities: descriptor.capabilities
		}
		if kind == 'native' {
			registry.native[id] = NativeTransformer{
				id:           id
				handler:      transform.handler
				capabilities: descriptor.capabilities
			}
		}
	}
	return registry
}

fn (hub TransformerRuntimeHub) has(id string) bool {
	return hub.registry.has(id)
}

fn (hub TransformerRuntimeHub) available(id string) bool {
	return hub.registry.available(id)
}

fn (hub TransformerRuntimeHub) entry(id string) ?TransformerRuntimeEntry {
	return hub.registry.entry(id)
}

fn (mut hub TransformerRuntimeHub) transform(id string, mut services dispatch.RuntimeServices, mut exchange dispatch.Exchange) !dispatch.TransformAction {
	return hub.registry.transform(id, mut services, mut exchange)!
}

fn (mut hub TransformerRuntimeHub) run_transform_refs(refs []string, mut services dispatch.RuntimeServices, mut exchange dispatch.Exchange) !TransformPipelineResult {
	for ref in refs {
		id := transform_id_from_ref(ref)
		action := hub.transform(id, mut services, mut exchange)!
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

fn transform_id_from_ref(ref string) string {
	if ref.starts_with('transform:') {
		return ref.all_after('transform:')
	}
	return ref
}

fn (registry TransformerRuntimeRegistry) has(id string) bool {
	_ := registry.entries[id] or { return false }
	return true
}

fn (registry TransformerRuntimeRegistry) available(id string) bool {
	entry := registry.entries[id] or { return false }
	return entry.available
}

fn (registry TransformerRuntimeRegistry) entry(id string) ?TransformerRuntimeEntry {
	return registry.entries[id] or { return none }
}

fn (mut registry TransformerRuntimeRegistry) transform(id string, mut services dispatch.RuntimeServices, mut exchange dispatch.Exchange) !dispatch.TransformAction {
	mut transformer := registry.native[id] or { return error('transformer unavailable: ${id}') }
	return transformer.transform(mut services, mut exchange)!
}

fn (transformer NativeTransformer) id() string {
	return transformer.id
}

fn (transformer NativeTransformer) capabilities() dispatch.Capabilities {
	return transformer.capabilities
}

fn (mut transformer NativeTransformer) warmup(mut services dispatch.RuntimeServices) ! {
	services.emit('transformer.warmup', {
		'transformer': transformer.id
		'kind':        'native'
		'handler':     transformer.handler
		'trace_id':    services.trace_id()
	})
}

fn (mut transformer NativeTransformer) transform(mut services dispatch.RuntimeServices, mut exchange dispatch.Exchange) !dispatch.TransformAction {
	services.emit('transformer.transform', {
		'transformer': transformer.id
		'kind':        'native'
		'handler':     transformer.handler
		'trace_id':    services.trace_id()
		'exchange_id': exchange.identity.id
		'pipeline':    exchange.pipeline
	})
	match transformer.handler {
		'feishu.event.summary' {
			return transformer.transform_feishu_event_summary(mut exchange)!
		}
		else {}
	}

	return dispatch.continue_pipeline_action()
}

fn (transformer NativeTransformer) transform_feishu_event_summary(mut exchange dispatch.Exchange) !dispatch.TransformAction {
	payload := match exchange.payload {
		dispatch.EventPayload { exchange.payload.data }
		else { '' }
	}

	if payload.trim_space() == '' {
		return error('feishu_transform_missing_event_payload:${transformer.id}')
	}
	summary := feishu.RuntimeEventSnapshot.summary_from_payload(payload)
	exchange.metadata['feishu.event_kind'] = summary.event_kind
	exchange.metadata['feishu.event_type'] = summary.event_type
	exchange.metadata['feishu.event_id'] = summary.event_id
	exchange.metadata['feishu.message_id'] = summary.message_id
	exchange.metadata['feishu.message_type'] = summary.message_type
	exchange.metadata['feishu.chat_id'] = summary.chat_id
	exchange.metadata['feishu.chat_type'] = summary.chat_type
	exchange.metadata['feishu.target_type'] = summary.target_type
	exchange.metadata['feishu.target'] = summary.target
	exchange.metadata['feishu.open_message_id'] = summary.open_message_id
	exchange.metadata['feishu.root_id'] = summary.root_id
	exchange.metadata['feishu.parent_id'] = summary.parent_id
	exchange.metadata['feishu.sender_id'] = summary.sender_id
	exchange.metadata['feishu.sender_id_type'] = summary.sender_id_type
	exchange.metadata['feishu.sender_tenant_key'] = summary.sender_tenant_key
	exchange.metadata['feishu.action_tag'] = summary.action_tag
	exchange.metadata['feishu.action_value'] = summary.action_value
	return dispatch.continue_pipeline_action()
}

fn (mut transformer NativeTransformer) close() {
	_ = transformer
}
