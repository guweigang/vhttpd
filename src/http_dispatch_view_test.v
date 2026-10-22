module main

import executor
import net.http
import os
import runtime_plan
import time
import upstream.transport
import worker

struct HttpViewExecutor {
	executor.DisabledLogicExecutor
	label    string
	model_fn fn () executor.LogicExecutorModel @[required]
}

fn (e HttpViewExecutor) model() executor.LogicExecutorModel { return e.model_fn() }

fn (e HttpViewExecutor) kind() string { return e.label }

fn (e HttpViewExecutor) dispatch_http(mut _ executor.AppFacade, req executor.HttpLogicDispatchRequest) !executor.HttpLogicDispatchOutcome {
	return executor.HttpLogicDispatchOutcome{ response: transport.WorkerResponse{ status: 200, body: '${e.label}:${req.path}' } }
}

fn http_view_executor(label string) executor.LogicExecutor {
	return HttpViewExecutor{
		label:    label
		model_fn: fn () executor.LogicExecutorModel {
			return .embedded
		}
	}
}

fn http_view_publish(mut app App, version string, value executor.LogicExecutor) {
	app.mu.@lock()
	defer { app.mu.unlock() }
	app.plan = runtime_plan.RuntimePlan{
		transforms: {
			'noop': runtime_plan.TransformPlan{ id: 'noop', kind: 'native', handler: version }
		}
	}
	app.pipelines = PipelineRuntime{ http: HttpRoutingRuntime{ listener_id: version, assets_root: version, document_root: version, rules: [RuntimeRouteRule{ pipeline_id: version, match_path: ['/*'], executor: 'logic', rewrite: '/${version}' }] } }
	app.transformers = TransformerRuntimeHub.from_plan(app.plan)
	app.engines = EngineRuntime{ primary: &worker.WorkerState{ logic_executor: value } }
	app.lifecycle.data_plane_scheme = if version == 'old' { 'https' } else { 'http' }
}

fn http_view_request(mut app App, view HttpDispatchView) Context {
	mut ctx := Context{ req: http.Request{ method: .get, url: '/request' } }
	HttpIngressRuntime.handle_on_view(mut app, mut ctx, 'GET', '/request', '', view)
	return ctx
}

fn test_http_request_keeps_route_and_executor_across_reentrant_model_callback() {
	mut app := &App{}
	http_view_publish(mut app, 'old', HttpViewExecutor{
		label:    'old'
		model_fn: fn [mut app] () executor.LogicExecutorModel {
			http_view_publish(mut app, 'new', http_view_executor('new'))
			return .embedded
		}
	})
	done := chan bool{cap: 1}
	spawn fn [mut app, done] () {
		old := http_view_request(mut app, app.http_dispatch_view())
		assert old.res.status_code == 200
		assert old.res.body == 'old:/old'
		assert (old.req.header.get(.x_forwarded_proto) or { panic('missing scheme header') }) == 'https'
		next := http_view_request(mut app, app.http_dispatch_view())
		assert next.res.body == 'new:/new'
		done <- true
	}()
	select {
		_ := <-done {
		}
		3 * time.second {
			panic('HTTP executor metadata held App.mu')
		}
	}
}

fn test_http_route_transforms_use_the_registry_captured_with_the_rule() {
	mut app := App{}
	http_view_publish(mut app, 'old', http_view_executor('old'))
	app.pipelines.http = HttpRoutingRuntime{ rules: [RuntimeRouteRule{ pipeline_id: 'old', match_path: ['/*'], transform_refs: ['noop'], status: 201, body: 'old-route' }] }
	view := app.http_dispatch_view()
	http_view_publish(mut app, 'new', http_view_executor('new'))
	app.transformers = TransformerRuntimeHub{}
	ctx := http_view_request(mut app, view)
	assert ctx.res.status_code == 201
	assert ctx.res.body == 'old-route'
}

fn test_http_adapter_lookup_does_not_adopt_entries_registered_after_capture() {
	for kind in ['relay-delivery', 'provider-action'] {
		log_path := os.join_path(os.temp_dir(), 'http-view-${kind}-${os.getpid()}-${time.now().unix_micro()}.ndjson')
		defer { os.rm(log_path) or {} }
		mut app := App{ control_plane: ControlPlaneRuntime{ event_log: log_path } }
		http_view_publish(mut app, 'old', http_view_executor('old'))
		app.pipelines.http = HttpRoutingRuntime{ rules: [RuntimeRouteRule{ pipeline_id: 'old', match_path: ['/*'], executor: kind, egress_ref: 'adapter:late' }] }
		view := app.http_dispatch_view()
		app.plan = runtime_plan.RuntimePlan{
			adapters: {
				'late': runtime_plan.AdapterPlan{
					id:      'late'
					kind:    'reject'
					options: runtime_plan.PlanOptions{
						ints:    {
							'status': 403
						}
						strings: {
							'error': 'new-adapter'
						}
					}
				}
			}
		}
		ctx := http_view_request(mut app, view)
		assert ctx.res.status_code == 502
		assert (os.read_file(log_path) or { panic(err) }).contains(if kind == 'relay-delivery' {
			'relay_delivery_adapter_missing:late'
		} else {
			'provider_action_adapter_missing:late'
		})
	}
}

fn test_http_view_retains_named_pool_registry_and_static_root() {
	mut app := App{}
	http_view_publish(mut app, 'old', http_view_executor('old'))
	old := &worker.WorkerState{ logic_executor: http_view_executor('old-named') }
	app.engines.additional['named'] = old
	view := app.http_dispatch_view()
	app.engines.additional['named'] = &worker.WorkerState{ logic_executor: http_view_executor('new-named') }
	app.engines.additional.delete('named')
	http_view_publish(mut app, 'new', http_view_executor('new'))
	assert view.engines.dispatch_selection('named').state == old
	assert view.engines.dispatch_selection('named').executor_kind() == 'old-named'
	assert view.pipelines.http_static_root(RuntimeRouteRule{}) == 'old'
	assert view.pipelines.http.document_root == 'old'
	assert view.pipelines.has_protocol_http_override(ProtocolHttpRequest{ method: 'GET', normalized_target: '/request' })
}

fn test_upload_completion_uses_the_http_requests_retained_transform_registry() {
	mut app := App{}
	http_view_publish(mut app, 'old', http_view_executor('old'))
	view := app.http_dispatch_view()
	app.transformers = TransformerRuntimeHub{}
	result := app.dispatch_upload_completed_transforms_on_view(view.transform_dispatch_view(), RuntimeRouteRule{ upload_completed_transform_refs: ['noop'] }, '', UploadResponse{}, {})
	assert result.attempted
	assert result.ok
	assert !app.dispatch_upload_completed_transforms(RuntimeRouteRule{ upload_completed_transform_refs: ['noop'] }, '', UploadResponse{}, {}).ok
}

fn http_view_publish_many(mut app App, done chan bool) {
	for i in 0 .. 250 {
		version := if i % 2 == 0 { 'old' } else { 'new' }
		http_view_publish(mut app, version, http_view_executor(version))
	}
	done <- true
}

fn test_http_dispatch_view_captures_coherent_concurrent_publications() {
	mut app := &App{}
	http_view_publish(mut app, 'old', http_view_executor('old'))
	done := chan bool{cap: 1}
	spawn http_view_publish_many(mut app, done)
	for _ in 0 .. 400 {
		view := app.http_dispatch_view()
		version := view.pipelines.http.listener_id
		assert view.plan.transforms['noop'].handler == version
		assert view.transformers.entry('noop')?.handler == version
		assert view.engines.primary_kind() == version
		assert view.scheme == if version == 'old' { 'https' } else { 'http' }
	}
	select {
		_ := <-done {
		}
		3 * time.second {
			panic('HTTP publication did not finish')
		}
	}
}
