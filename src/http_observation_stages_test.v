module main

import executor
import time

fn test_unobserved_request_adapter_calls_remain_absent() {
	mut ctx := Context{}
	ctx.begin_observed_adapter()
	ctx.end_observed_adapter()
	assert ctx.observed_timing == none
	assert ctx.observed_adapter_depth == 0
	assert !ctx.observed_stages(1000).available
}

fn test_nested_adapter_intervals_and_completion_snapshot_belong_to_request() {
	mut owned := &executor.HttpRequestTiming{}
	mut ctx := Context{ observed_timing: owned }
	ctx.begin_observed_adapter()
	ctx.begin_observed_adapter()
	ctx.observed_adapter_started = time.sys_mono_now() - time.millisecond
	ctx.end_observed_adapter()
	assert ctx.observed_adapter_depth == 1
	assert !owned.adapter_observed
	ctx.end_observed_adapter()
	assert ctx.observed_adapter_depth == 0
	assert owned.adapter_observed
	assert owned.adapter_ns >= time.millisecond
	recorded := owned.adapter_ns
	ctx.end_observed_adapter()
	assert owned.adapter_ns == recorded
	snapshot := ctx.observed_stages(recorded + 1000000)
	ctx.observed_timing = none
	owned.adapter_ns = 0
	assert snapshot.available && snapshot.adapter_observed
	assert snapshot.adapter_ms >= 1
	assert snapshot.other_ms == 1
	assert !ctx.observed_stages(1000).available
}
