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
	assert source.contains('provider_runtime_hub_from_settings(plan_provider_settings)')
}
