module main

import provider
import codex
import json2 as json
import time

fn control_spec(i int) provider.ProviderInstanceSpec {
	return provider.ProviderInstanceSpec{ provider: 'codex', instance: 'shared', config_json: '{"url":"ws://control/${i}","model":"model-${i}"}', desired_state: 'state-${i}' }
}

fn control_wait(done chan bool) {
	select {
		_ := <-done {
		}
		5 * time.second {
			panic('provider control timed out')
		}
	}
}

fn test_invalid_command_does_not_publish_provider_instance() {
	mut app := &App{}
	ctx := app.build_command_context()
	if _ := ctx.instance_upsert_apply('codex', 'broken', '{bad json', 'connected') {
		assert false
	} else {
		assert err.msg().starts_with('provider_instance_invalid_codex_config:')
	}
	assert app.provider_instance_get('codex', 'broken') == none
	assert app.providers.codex.instances.len == 0
}

fn test_failed_admin_update_preserves_registry_and_runtime() {
	mut app := &App{}
	first := app.configure_provider_instance(control_spec(1)) or { panic(err) }
	if _ := app.admin_provider_instance_upsert_from_body('{"provider":"codex","instance":"shared","config_json":"{bad json"}') {
		assert false
	}
	after := app.provider_instance_get('codex', 'shared') or { panic('missing') }
	rt := app.providers.codex.snapshot('shared')
	assert after.config_json == first.spec.config_json
	assert after.created_at == first.spec.created_at
	assert rt.url == 'ws://control/1'
	assert rt.model == 'model-1'
}

fn test_concurrent_command_commits_keep_runtime_and_registry_together() {
	mut app := &App{}
	done := chan bool{cap: 32}
	for i in 0 .. 32 {
		spawn fn [mut app, i, done] () {
			ctx := app.build_command_context()
			spec := control_spec(i)
			ctx.instance_upsert_apply(spec.provider, spec.instance, spec.config_json, spec.desired_state) or { panic(err) }
			done <- true
		}()
	}
	for _ in 0 .. 32 { control_wait(done) }
	stored := app.provider_instance_get('codex', 'shared') or { panic('missing') }
	cfg := json.decode[map[string]string](stored.config_json) or { panic(err) }
	rt := app.providers.codex.snapshot('shared')
	assert rt.url == cfg['url']
	assert rt.model == cfg['model']
	assert rt.configuration_generation == 32
}

fn test_each_concurrent_admin_response_describes_its_own_commit() {
	mut app := &App{}
	done := chan bool{cap: 16}
	for i in 0 .. 16 {
		spawn fn [mut app, i, done] () {
			spec := control_spec(i)
			raw := json.encode(AdminProviderInstanceUpsertRequest{ provider: spec.provider, instance: spec.instance, config_json: spec.config_json, desired_state: spec.desired_state })
			result := app.admin_provider_instance_upsert_from_body(raw) or { panic(err) }
			assert result.snapshot.desired_state == spec.desired_state
			assert result.snapshot.config_fields == ['model', 'url']
			done <- true
		}()
	}
	for _ in 0 .. 16 { control_wait(done) }
}

fn test_snapshot_readers_never_observe_half_committed_instance_rows() {
	mut app := &App{}
	done := chan bool{cap: 2}
	spawn fn [mut app, done] () {
		for i in 0 .. 100 {
			field := if i % 2 == 0 { 'url' } else { 'model' }
			value := if field == 'url' { 'ws://control/${i}' } else { 'm-${i}' }
			app.configure_provider_instance(provider.ProviderInstanceSpec{ provider: 'codex', instance: 'shared', config_json: '{"${field}":"${value}"}', desired_state: field }) or { panic(err) }
		}
		done <- true
	}()
	spawn fn [mut app, done] () {
		for _ in 0 .. 100 {
			for row in app.admin_provider_instance_snapshots('codex') {
				assert row.config_fields == [row.desired_state]
			}
			_ := app.build_provider_runtime_dispatch_context().upstream_launches()
			_ := app.admin_runtime_snapshot()
		}
		done <- true
	}()
	control_wait(done)
	control_wait(done)
}

fn test_partial_config_commit_preserves_runtime_resources_and_activity() {
	mut app := &App{}
	app.configure_provider_instance(control_spec(1)) or { panic(err) }
	mut rt := app.providers.codex.snapshot('shared')
	rt.connected = true
	rt.thread_id = 'thread'
	rt.received_frames = 42
	rt.pending_rpcs[7] = codex.PendingRpc{ method: 'keep' }
	app.providers.codex.update('shared', rt)
	app.configure_provider_instance(provider.ProviderInstanceSpec{ provider: 'codex', instance: 'shared', config_json: '{"model":"new-model"}' }) or { panic(err) }
	next := app.providers.codex.snapshot('shared')
	assert next.url == 'ws://control/1'
	assert next.model == 'new-model'
	assert next.connected
	assert next.thread_id == 'thread'
	assert next.received_frames == 42
	assert next.pending_rpcs[7].method == 'keep'
}

fn test_delayed_activity_update_cannot_restore_old_command_configuration() {
	mut app := &App{}
	app.configure_provider_instance(control_spec(1)) or { panic(err) }
	mut old := app.providers.codex.snapshot('shared')
	app.configure_provider_instance(control_spec(2)) or { panic(err) }
	old.received_frames = 99
	old.thread_id = 'activity-survives'
	app.providers.codex.update('shared', old)
	current := app.providers.codex.snapshot('shared')
	assert current.url == 'ws://control/2'
	assert current.model == 'model-2'
	assert current.received_frames == 99
	assert current.thread_id == 'activity-survives'
	assert current.configuration_generation == 2
}

fn test_ensure_and_upsert_cannot_replay_a_stale_instance_spec() {
	mut app := &App{}
	app.configure_provider_instance(control_spec(0)) or { panic(err) }
	done := chan bool{cap: 2}
	spawn fn [mut app, done] () {
		for i in 1 .. 50 { app.configure_provider_instance(control_spec(i)) or { panic(err) } }
		done <- true
	}()
	spawn fn [mut app, done] () {
		for _ in 0 .. 50 { app.provider_instance_ensure('codex', 'shared') or { panic(err) } }
		done <- true
	}()
	control_wait(done)
	control_wait(done)
	stored := app.provider_instance_get('codex', 'shared') or { panic('missing') }
	cfg := json.decode[map[string]string](stored.config_json) or { panic(err) }
	assert app.providers.codex.snapshot('shared').url == cfg['url']
	assert app.providers.codex.snapshot('shared').model == cfg['model']
}

fn test_registry_readers_and_writers_share_the_map_lock() {
	mut registry := &provider.ProviderInstanceRegistry{}
	done := chan bool{cap: 8}
	for i in 0 .. 8 {
		spawn fn [mut registry, i, done] () {
			for n in 0 .. 50 {
				registry.upsert(provider.ProviderInstanceSpec{ provider: 'codex', instance: '${i}', config_json: '${n}' })
				_ := registry.list('codex')
				assert registry.get('codex', '${i}') != none
			}
			done <- true
		}()
	}
	for _ in 0 .. 8 { control_wait(done) }
	assert registry.list('codex').len == 8
}

fn test_shutdown_rejects_new_provider_control_writes_but_allows_snapshots() {
	mut app := &App{}
	app.configure_provider_instance(control_spec(1)) or { panic(err) }
	assert app.lifecycle.shutdown.claim()
	if _ := app.configure_provider_instance(control_spec(2)) {
		assert false
	} else {
		assert err.msg() == 'provider_instance_app_stopping'
	}
	if _ := app.provider_instance_ensure('codex', 'shared') {
		assert false
	} else {
		assert err.msg() == 'provider_instance_app_stopping'
	}
	app.provider_instance_apply(control_spec(3)) or { assert err.msg() == 'provider_instance_app_stopping' }
	assert app.provider_instance_get('codex', 'shared') or { panic('missing') }.desired_state == 'state-1'
	assert app.providers.codex.snapshot('shared').url == 'ws://control/1'
	assert app.admin_provider_instance_snapshots('codex').len == 1
	app.lifecycle.shutdown.wait_started()
	app.lifecycle.shutdown.finish('')
}
