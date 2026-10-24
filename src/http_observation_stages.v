module main

import executor
import time

// Completion exports values only; retained admin samples never own request state.
fn (ctx &Context) observed_stages(total_ns i64) executor.AdminHttpStages {
	if timing := ctx.observed_timing { return timing.snapshot(total_ns) }
	return executor.AdminHttpStages{}
}

// Nested response/terminal calls form one union of adapter intervals.
fn (mut ctx Context) begin_observed_adapter() {
	if ctx.observed_timing == none { return }
	if ctx.observed_adapter_depth == 0 { ctx.observed_adapter_started = time.sys_mono_now() }
	ctx.observed_adapter_depth++
}

fn (mut ctx Context) end_observed_adapter() {
	mut timing := ctx.observed_timing or { return }
	if ctx.observed_adapter_depth == 0 { return }
	ctx.observed_adapter_depth--
	if ctx.observed_adapter_depth == 0 {
		timing.adapter_ns += time.sys_mono_now() - ctx.observed_adapter_started
		timing.adapter_observed = true
	}
}
