module main

import runtime_plan
import provider
import time

fn projection_plan(label string) runtime_plan.RuntimePlan {
	return runtime_plan.RuntimePlan{
		source:      runtime_plan.PlanSource{ config_path: '/private/tmp/vhttpd-projection-${label}/app.toml' }
		listeners:   {
			label: runtime_plan.ListenerPlan{ id: label, protocol: 'http', host: label }
		}
		engines:     {
			label: runtime_plan.EnginePlan{
				id:      label
				kind:    label
				options: runtime_plan.PlanOptions{
					strings: {
						'entry': '${label}.ts'
					}
				}
			}
		}
		adapters:    {
			label: runtime_plan.AdapterPlan{ id: label, kind: 'http-handler', engine: runtime_plan.ResourceRef{ domain: .engine, id: label } }
		}
		pipelines:   [runtime_plan.PipelinePlan{ id: label, group: 'site:${label}', ingress: runtime_plan.ResourceRef{ domain: .listener, id: label }, egress: runtime_plan.ResourceRef{ domain: .adapter, id: label } }]
		diagnostics: [runtime_plan.PlanDiagnostic{ code: label }]
	}
}

fn projection_publish(mut app App, label string) {
	plan := projection_plan(label)
	app.mu.@lock()
	app.plan = plan
	app.protocols.runtime_plan_json = label
	app.pipelines.http = HttpRoutingRuntime{ listener_id: label }
	app.transformers = TransformerRuntimeHub{
		registry: TransformerRuntimeRegistry{
			entries: {
				label: TransformerRuntimeEntry{ id: label, kind: 'native', available: true }
			}
		}
	}
	app.mu.unlock()
}

fn projection_wait(done chan bool) {
	select {
		_ := <-done {
		}
		5 * time.second {
			panic('admin projection timed out')
		}
	}
}

fn test_retained_plan_view_projects_original_apps_graph_and_source_paths() {
	mut app := &App{}
	projection_publish(mut app, 'old')
	view := app.admin_plan_view()
	projection_publish(mut app, 'new')
	assert view.json == 'old'
	assert admin_apps_from_plan(view.plan).apps[0].id == 'old'
	graph := admin_graph_from_plan(view.plan)
	assert graph.nodes.all(it.id == 'old')
	files := admin_source_files_from_plan(view.plan)
	assert files.len == 2
	assert files[0].path.contains('vhttpd-projection-old')
	assert files[1].path.ends_with('/old.ts')
	assert app.admin_plan_view().json == 'new'
	assert app.admin_apps_snapshot().apps[0].id == 'new'
	assert app.admin_runtime_graph_snapshot().nodes.all(it.id == 'new')
}

fn test_apps_diagnostics_are_detached_from_published_plan() {
	mut app := &App{}
	projection_publish(mut app, 'old')
	snapshot := app.admin_apps_snapshot()
	// Deliberately alias the returned buffer to verify that it is detached.
	mut diagnostics := unsafe { snapshot.diagnostics }
	diagnostics[0] = runtime_plan.PlanDiagnostic{ code: 'poison' }
	assert app.admin_apps_snapshot().diagnostics[0].code == 'old'
}

fn test_concurrent_plan_projection_reads_do_not_mix_publications() {
	mut app := &App{}
	projection_publish(mut app, 'old')
	done := chan bool{cap: 2}
	spawn fn [mut app, done] () {
		for i in 0 .. 100 { projection_publish(mut app, if i % 2 == 0 { 'old' } else { 'new' }) }
		done <- true
	}()
	spawn fn [mut app, done] () {
		for _ in 0 .. 100 {
			view := app.admin_plan_view()
			assert view.plan.listeners.keys() == [view.json]
			apps := app.admin_apps_snapshot()
			label := apps.listeners[0].id
			assert apps.apps[0].id == label
			assert apps.apps[0].engines[0].id == label
			assert apps.pipelines[0].id == label
			assert apps.diagnostics[0].code == label
			graph := app.admin_runtime_graph_snapshot()
			marker := graph.nodes[0].id
			assert graph.nodes.all(it.id == marker)
			for edge in graph.edges {
				assert edge.from.all_after(':') == edge.to.all_after(':')
			}
			_ := app.admin_pipeline_runtime_snapshot()
			transformers := app.admin_transformer_snapshot()
			assert transformers.total == 1
			assert transformers.entries[0].id in ['old', 'new']
		}
		done <- true
	}()
	projection_wait(done)
	projection_wait(done)
}

fn projection_spec(name string, snapshot_fn fn () string) ProviderSpec {
	return ProviderSpec{
		name:          name
		enabled:       true
		has_runtime:   true
		provider:      DbProvider{}
		handler:       provider.NoopProviderCommandHandler{}
		runtime:       ProviderRuntimeAdapter{ provider: DbProvider{} }
		lifecycle_ctx: provider.RuntimeContext{ start: fn () ! {}, stop: fn () ! {}, emit: fn (_ string, _ map[string]string) {}, snapshot: snapshot_fn }
	}
}

fn projection_provider_settings(label string) provider.ProviderRuntimeSettings {
	return provider.ProviderRuntimeSettings{
		runtime_drivers:      {
			'a':                   label
			'b':                   label
			'configured-${label}': label
		}
		runtime_protocols:    {
			'a': 'protocol-${label}'
			'b': 'protocol-${label}'
		}
		runtime_plugins:      {
			'a': 'plugin-${label}'
			'b': 'plugin-${label}'
		}
		runtime_capabilities: {
			'a': {
				'version': label
			}
			'b': {
				'version': label
			}
		}
		runtime_hooks:        {
			'a': {
				'hook': label
			}
			'b': {
				'hook': label
			}
		}
	}
}

fn test_provider_callbacks_cannot_mix_metadata_and_selected_specs() {
	mut app := &App{}
	app.register_provider_spec(projection_spec('a', fn [mut app] () string {
		app.mu.@lock()
		app.providers.apply_provider_runtime_settings(projection_provider_settings('new'))
		app.mu.unlock()
		app.register_provider_spec(projection_spec('b', fn () string { return 'new-b' }))
		return 'old-a'
	}))
	app.register_provider_spec(projection_spec('b', fn () string { return 'old-b' }))
	app.mu.@lock()
	app.providers.apply_provider_runtime_settings(projection_provider_settings('old'))
	app.mu.unlock()
	rows := app.admin_provider_runtimes_snapshot()
	assert rows.map(it.name) == ['a', 'b', 'configured-old']
	assert rows[0].snapshot == 'old-a'
	assert rows[1].snapshot == 'old-b'
	for row in rows {
		assert row.runtime_driver == 'old'
	}
	assert rows[0].protocol == 'protocol-old'
	assert rows[1].plugin == 'plugin-old'
	assert rows[0].capabilities['version'] == 'old'
	assert rows[1].hooks['hook'] == 'old'
}

fn test_provider_metadata_maps_do_not_alias_live_registry() {
	mut app := &App{}
	app.register_provider_spec(projection_spec('a', fn () string { return 'payload' }))
	app.providers.apply_provider_runtime_settings(projection_provider_settings('old'))
	rows := app.admin_provider_runtimes_snapshot()
	mut caps := rows[0].capabilities
	mut hooks := rows[0].hooks
	caps['version'] = 'poison'
	hooks['hook'] = 'poison'
	fresh := app.admin_provider_runtimes_snapshot()
	assert fresh[0].capabilities['version'] == 'old'
	assert fresh[0].hooks['hook'] == 'old'
}

fn test_blocked_provider_snapshot_does_not_block_publication() {
	mut app := &App{}
	entered := chan bool{cap: 1}
	release := chan bool{cap: 1}
	done := chan bool{cap: 1}
	app.register_provider_spec(projection_spec('a', fn [entered, release] () string {
		entered <- true
		_ := <-release
		return 'old'
	}))
	app.providers.apply_provider_runtime_settings(projection_provider_settings('old'))
	spawn fn [mut app, done] () {
		rows := app.admin_provider_runtimes_snapshot()
		assert rows[0].runtime_driver == 'old'
		assert rows[0].snapshot == 'old'
		done <- true
	}()
	projection_wait(entered)
	published := chan bool{cap: 1}
	spawn fn [mut app, published] () {
		app.mu.@lock()
		app.providers.apply_provider_runtime_settings(projection_provider_settings('new'))
		app.mu.unlock()
		published <- true
	}()
	projection_wait(published)
	release <- true
	projection_wait(done)
}

fn test_transformer_and_pipeline_snapshots_remain_values_after_replacement() {
	mut app := &App{}
	projection_publish(mut app, 'old')
	transformers := app.admin_transformer_snapshot()
	pipeline := app.admin_pipeline_runtime_snapshot()
	projection_publish(mut app, 'new')
	assert transformers.entries[0].id == 'old'
	assert pipeline.listener_id == 'old'
	assert app.admin_transformer_snapshot().entries[0].id == 'new'
	assert app.admin_pipeline_runtime_snapshot().listener_id == 'new'
}
