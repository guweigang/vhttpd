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
			if lines[j].contains('if plan.source.compatibility') {
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
	assert source.contains('if plan.source.compatibility && route.upload_completed_engine_ids.len == 0')
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

fn test_refactor_contract_runtime_plan_replacement_uses_runtime_builders() {
	source := refactor_contract_source_file('admin_runtime_plan_replacement.v')
	assert !source.contains('import json')
	assert !source.contains('mcp_state_from_plan')
	assert !source.contains('openai_state_from_plan')
	assert !source.contains('app.protocols.runtime_plan_json =')
	assert !source.contains('app.protocols.mcp =')
	assert !source.contains('app.protocols.openai =')
	assert !source.contains('PipelineRuntime.new(')
	assert !source.contains('TransformerRuntimeHub.from_plan(')
	assert !source.contains('protocol_runtime_plan_update_from_plan(')
	assert !source.contains('app.protocols.apply_plan_update(')
	assert source.contains('RuntimePlanRuntimeProjection.from_plan(')
	assert source.contains('app.apply_runtime_plan_runtime_projection(')
}
