module main

import os

fn refactor_contract_source_file(name string) string {
	return os.read_file(os.join_path(os.dir(@FILE), name)) or { panic(err) }
}

fn assert_call_guarded_by_compatibility(source string, call string) {
	lines := source.split_into_lines()
	for i, line in lines {
		if !line.contains(call) {
			continue
		}
		mut guarded := false
		mut j := i - 1
		for j >= 0 && i - j <= 4 {
			if lines[j].contains('.source.compatibility') {
				guarded = true
				break
			}
			j--
		}
		assert guarded
	}
}

fn test_refactor_contract_provider_global_fallbacks_are_compatibility_only() {
	source := refactor_contract_source_file('runtime_plan_provider_builder.v')
	assert_call_guarded_by_compatibility(source, 'return plan.first_adapter_by_kind(kind)')
	assert_call_guarded_by_compatibility(source, "return plan.first_relay_by_carrier('websocket')")
}

fn test_refactor_contract_upload_completion_legacy_fallback_is_compatibility_only() {
	source := refactor_contract_source_file('engine_runtime_builder.v')
	assert source.contains('.source.compatibility && route.upload_completed_engine_ids.len == 0')
	assert source.contains("route.on_completed.trim_space().starts_with('vjsx:')")
}

fn test_refactor_contract_v2_routes_do_not_project_legacy_upload_completion() {
	source := refactor_contract_source_file('runtime_plan_route_builder.v')
	assert_call_guarded_by_compatibility(source,
		'route.on_completed = legacy_completion_handler_from_plan')
	assert source.contains('route.upload_completed_engine_ids = completed_engine_ids_from_plan')
}

fn test_refactor_contract_generic_runtime_builders_do_not_special_case_wordpress() {
	for file in [
		'app_runtime_builder.v',
		'engine_runtime_builder.v',
		'relay_runtime_builder.v',
		'runtime_plan_provider_builder.v',
		'runtime_plan_route_builder.v',
		'runtime_plan_runtime_diagnostics.v',
	] {
		source := refactor_contract_source_file(file)
		assert !source.to_lower().contains('wordpress')
	}
}

fn test_refactor_contract_app_runtime_builder_does_not_construct_provider_specific_state() {
	source := refactor_contract_source_file('app_runtime_builder.v')
	assert !source.contains('import codex')
	assert !source.contains('import feishu')
	assert !source.contains('codex.CodexState')
	assert !source.contains('feishu.FeishuState')
	assert source.contains('ProviderRuntimeHub.new(plan_provider_settings)')
}

fn test_refactor_contract_provider_runtime_builder_uses_provider_state_constructors() {
	source := refactor_contract_source_file('provider_runtime_builder.v')
	assert !source.contains('codex.CodexState{')
	assert !source.contains('codex.ProviderRuntime{')
	assert !source.contains('feishu.FeishuState{')
	assert !source.contains('map[int]codex.PendingRpc{}')
	assert !source.contains('map[string]feishu.ProviderRuntime{}')
	assert source.contains('codex.CodexState.new(')
	assert source.contains('feishu.FeishuState.new(')
}

fn test_refactor_contract_app_runtime_builder_uses_runtime_hub_builders() {
	source := refactor_contract_source_file('app_runtime_builder.v')
	assert !source.contains('import admin')
	assert !source.contains('import cachex')
	assert !source.contains('import dbx')
	assert !source.contains('import plugin')
	assert !source.contains('import json')
	assert !source.contains('import time')
	assert !source.contains('ProtocolRuntimeHub{')
	assert !source.contains('TransportRuntimeHub{')
	assert source.contains('ProtocolRuntimeHub.from_plan(cfg, runtime_plan_for_app, plan_listener_id)')
	assert source.contains('TransportRuntimeHub.from_plan(runtime_plan_for_app, plan_listener_id)')
	assert source.contains('ControlPlaneRuntime.new(build_cfg)')
	assert source.contains('ProcessLifecycle.started_now()')
	assert source.contains('config.AssetsRuntime.new(')
}

fn test_refactor_contract_startup_runtime_is_split_by_domain() {
	orchestrator := refactor_contract_source_file('server_runtime_orchestrator.v')
	assert !os.exists(os.join_path(os.dir(@FILE), 'server_startup_hooks.v'))
	for runtime_name in [
		'TransportStartupRuntime.initialize(',
		'ProviderStartupRuntime.initialize(',
		'AssetStartupRuntime.mount(',
		'ControlPlaneStartupRuntime.emit_server_started(',
		'ProviderStartupRuntime.start_upstreams(',
	] {
		assert orchestrator.contains(runtime_name)
	}
}

fn test_refactor_contract_runtime_plan_replacement_uses_runtime_builders() {
	action_sources := [
		refactor_contract_source_file('admin_runtime_plan_replacement_apply.v'),
		refactor_contract_source_file('admin_runtime_plan_replacement_finalize.v'),
		refactor_contract_source_file('admin_runtime_plan_replacement_cancel.v'),
	].join('\n')
	runtime_source := refactor_contract_source_file('admin_runtime_plan_replacement_runtime.v')
	assert !action_sources.contains('import json')
	assert !action_sources.contains('mcp_state_from_plan')
	assert !action_sources.contains('openai_state_from_plan')
	assert !action_sources.contains('app.protocols.runtime_plan_json =')
	assert !action_sources.contains('app.protocols.mcp =')
	assert !action_sources.contains('app.protocols.openai =')
	assert !action_sources.contains('PipelineRuntime.new(')
	assert !action_sources.contains('TransformerRuntimeHub.from_plan(')
	assert !action_sources.contains('protocol_runtime_plan_update_from_plan(')
	assert !action_sources.contains('app.protocols.apply_plan_update(')
	assert runtime_source.contains('RuntimePlanRuntimeProjection.from_plan(')
	assert runtime_source.contains('app.apply_runtime_plan_runtime_projection(')
}
