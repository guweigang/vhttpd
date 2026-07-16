module main

import executor

pub fn (mut app App) admin_logic_executor_specs_snapshot() []executor.AdminLogicExecutorSpecSnapshot {
	_ = app
	specs := executor.builtin_executor_spec_all()
	mut snapshots := []executor.AdminLogicExecutorSpecSnapshot{cap: specs.len}
	for spec in specs {
		snapshots << spec.admin_snapshot()
	}
	return snapshots
}
