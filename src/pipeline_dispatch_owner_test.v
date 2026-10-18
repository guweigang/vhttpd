module main

import dispatch
import relay
import runtime_plan
import time

fn pipeline_owner_plan(version string) runtime_plan.RuntimePlan {
	return runtime_plan.RuntimePlan{
		relays:     {
			'edge': runtime_plan.RelayPlan{ id: 'edge' }
		}
		pipelines:  [runtime_plan.PipelinePlan{
			id:         version
			ingress:    runtime_plan.ResourceRef{ domain: .provider, id: 'events' }
			transforms: [runtime_plan.ResourceRef{ domain: .transform, id: 'first' },
				runtime_plan.ResourceRef{ domain: .transform, id: 'last' }]
			egress:     runtime_plan.ResourceRef{ domain: .adapter, id: 'reply' }
		}, runtime_plan.PipelinePlan{
			id:      'relay-${version}'
			ingress: runtime_plan.ResourceRef{ domain: .relay, id: 'edge' }
			egress:  runtime_plan.ResourceRef{ domain: .adapter, id: 'reply' }
		}]
		transforms: {
			'first': runtime_plan.TransformPlan{ id: 'first', kind: 'native', handler: 'noop' }
			'last':  runtime_plan.TransformPlan{
				id:      'last'
				kind:    'native'
				handler: 'protocol.bridge'
				options: runtime_plan.PlanOptions{
					strings: {
						'target': version
					}
				}
			}
		}
		adapters:   {
			'reply': runtime_plan.AdapterPlan{
				id:      'reply'
				kind:    'fixed-response'
				options: runtime_plan.PlanOptions{
					strings: {
						'body':   version
						'status': '201'
					}
					ints:    {
						'status': 201
					}
				}
			}
		}
	}
}

fn pipeline_owner_publish(mut app App, plan runtime_plan.RuntimePlan) {
	app.mu.@lock()
	app.plan = plan
	app.transformers = TransformerRuntimeHub.from_plan(plan)
	app.pipelines.relay = RelayPipelineRuntime.new(plan)
	app.mu.unlock()
}

fn pipeline_owner_exchange() dispatch.Exchange {
	return runtime_event_exchange('request', 'trace', 'provider:events', 'old', '', '', '', {})
}

fn test_transform_chain_retains_registry_when_callback_publishes_replacement() {
	mut app := &App{}
	pipeline_owner_publish(mut app, pipeline_owner_plan('old'))
	mut services := dispatch.RuntimeServices(EventDispatchServices{
		trace:   'trace'
		emit_fn: fn [mut app] (_ string, fields map[string]string) {
			if fields['transformer'] == 'first' {
				pipeline_owner_publish(mut app, pipeline_owner_plan('new'))
			}
		}
	})
	mut exchange := pipeline_owner_exchange()
	result := app.run_transform_refs(['transform:first', 'transform:last'], mut services, mut exchange) or { panic(err) }
	assert result.action.target == 'old'
	assert app.pipeline_dispatch_view().plan.pipelines[0].id == 'new'
	mut next := pipeline_owner_exchange()
	mut noop := noop_dispatch_services('trace')
	assert app.run_transform_refs(['last'], mut noop, mut next)!.action.target == 'new'
}

fn test_transform_chain_does_not_adopt_newly_registered_entry_mid_request() {
	mut app := &App{}
	full := pipeline_owner_plan('new')
	mut old_transforms := full.transforms.clone()
	old_transforms.delete('last')
	pipeline_owner_publish(mut app, runtime_plan.RuntimePlan{ ...full, transforms: old_transforms })
	mut services := dispatch.RuntimeServices(EventDispatchServices{
		emit_fn: fn [mut app, full] (_ string, _ map[string]string) {
			pipeline_owner_publish(mut app, full)
		}
	})
	mut exchange := pipeline_owner_exchange()
	app.run_transform_refs(['first', 'last'], mut services, mut exchange) or {
		assert err.msg() == 'transformer not registered: last'
		return
	}
	assert false, 'an admitted chain must not acquire transforms from a later publication'
}

fn test_event_view_keeps_route_and_transforms_from_same_publication() {
	mut app := App{}
	pipeline_owner_publish(mut app, pipeline_owner_plan('old'))
	view := app.pipeline_dispatch_view()
	pipeline_owner_publish(mut app, pipeline_owner_plan('new'))
	pipeline := view.runtime_event_pipeline('provider:events', '', {})!
	assert pipeline.id == 'old'
	assert view.runtime_event_pipeline('provider:events', 'pipeline:old', {})!.id == 'old'
	mut exchange := pipeline_owner_exchange()
	mut services := noop_dispatch_services('trace')
	result := app.run_transform_refs_on_view(view.transform_dispatch_view(), pipeline.transforms.map(it.str()), mut services, mut exchange)!
	assert result.action.target == 'old'
	assert app.runtime_event_pipeline('provider:events', '', {})!.id == 'new'
}

fn test_relay_view_keeps_ingress_and_adapter_after_replacement() {
	mut app := App{}
	pipeline_owner_publish(mut app, pipeline_owner_plan('old'))
	view := app.pipeline_dispatch_view()
	pipeline_owner_publish(mut app, pipeline_owner_plan('new'))
	exchanges := view.relay.ingress_exchanges('edge', 'carrier', relay.WireFrame{ id: 'frame' }, 1)
	assert exchanges.len == 1
	mut exchange := exchanges[0]
	assert exchange.pipeline == 'relay-old'
	outcome := app.dispatch_relay_pipeline_exchange_on_view(view, mut exchange)
	assert outcome.status == 201
	assert outcome.body == 'old'
	mut current := exchange
	assert app.dispatch_relay_pipeline_exchange(mut current).error_class == 'relay_pipeline_unknown'
}

fn pipeline_owner_replace_many(mut app App, done chan bool) {
	for i in 0 .. 300 {
		pipeline_owner_publish(mut app, pipeline_owner_plan(if i % 2 == 0 { 'old' } else { 'new' }))
	}
	done <- true
}

fn test_pipeline_view_captures_coherent_concurrent_publications() {
	mut app := &App{}
	pipeline_owner_publish(mut app, pipeline_owner_plan('old'))
	done := chan bool{cap: 1}
	spawn pipeline_owner_replace_many(mut app, done)
	for _ in 0 .. 500 {
		view := app.pipeline_dispatch_view()
		version := view.plan.pipelines[0].id
		assert view.transformers.entry('last')?.options.strings['target'] == version
		assert view.relay.pipeline_descriptors('edge')[0].id == 'relay-${version}'
	}
	select {
		_ := <-done {
		}
		3 * time.second {
			panic('publication did not finish')
		}
	}
}

fn test_event_view_preserves_ingress_and_metadata_validation() {
	mut app := App{}
	plan := pipeline_owner_plan('old')
	mut pipelines := plan.pipelines.clone()
	pipelines[0] = runtime_plan.PipelinePlan{
		...pipelines[0]
		match: runtime_plan.MatchPlan{
			metadata: {
				'instance': 'main'
			}
		}
	}
	pipeline_owner_publish(mut app, runtime_plan.RuntimePlan{ ...plan, pipelines: pipelines })
	for request in [
		['provider:other', 'old', 'runtime_event_ingress_mismatch:old:provider:other'],
		['provider:events', 'old', 'runtime_event_metadata_mismatch:old'],
		['provider:events', '', 'runtime_event_pipeline_not_found:provider:events'],
	] {
		app.runtime_event_pipeline(request[0], request[1], {}) or {
			assert err.msg() == request[2]
			continue
		}
		assert false
	}
	assert app.runtime_event_pipeline('provider:events', '', {
		'instance': 'main'
	})!.id == 'old'
}
