module main

import crypto.sha256
import os
import runtime_plan

fn runtime_plan_replacement_config_hash(config_path string) !string {
	text := os.read_file(config_path)!
	return sha256.sum(text.bytes()).hex().to_lower()
}

fn (mut app App) emit_runtime_plan_replacement_rejected(result RuntimePlanReplacementApplyResult) {
	app.emit('runtime.plan.replacement.rejected', {
		'config_path':          result.config_path
		'config_hash':          result.config_hash
		'changed_pipelines':    result.preview.changed_pipelines.join(',')
		'drain_engines':        result.preview.drain_engines.join(',')
		'error':                result.error
		'replacement_strategy': result.strategy
		'status':               result.status
	})
}

fn runtime_plan_diagnostic_codes(plan runtime_plan.RuntimePlan) string {
	mut codes := []string{}
	for diagnostic in plan.diagnostics {
		if diagnostic.code != '' && diagnostic.code !in codes {
			codes << diagnostic.code
		}
	}
	codes.sort()
	return codes.join(',')
}

fn (mut app App) emit_runtime_plan_replacement_finalize_rejected(result RuntimePlanReplacementFinalizeResult) {
	app.emit('runtime.plan.replacement.finalize_rejected', {
		'config_path':          result.config_path
		'error':                result.error
		'operation':            'finalize'
		'replacement_strategy': result.strategy
		'status':               result.status
	})
}

fn (mut app App) emit_runtime_plan_replacement_cancel_rejected(result RuntimePlanReplacementCancelResult) {
	app.emit('runtime.plan.replacement.cancel_rejected', {
		'config_path':          result.pending.config_path
		'error':                result.error
		'operation':            'cancel'
		'replacement_strategy': result.pending.strategy
		'status':               result.status
	})
}
