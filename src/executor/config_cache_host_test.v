module executor

import vjsx

struct ConfigCacheTestHost {
	NoOpAppFacade
mut:
	config_json string
}

fn (h ConfigCacheTestHost) get_runtime_config_json() string { return h.config_json }

fn config_cache_eval(ctx &vjsx.Context, code string) string {
	value := ctx.eval(code) or { panic(err) }
	defer { value.free() }
	return value.to_string()
}

fn test_config_callback_cache_keeps_live_config_and_request_access_rules() {
	mut session := vjsx.new_runtime_session()
	defer { session.close() }
	mut ctx := session.context()
	mut state := &VjsxExecutorState{
		hosts: [VjsxLaneHost.empty()]
		lanes: [VjsxExecutionLane{ id: 'lane_0' }]
	}
	mut cache := InProcVjsxHostApi.install(mut ctx, mut state, 0)
	defer { cache.close() }
	exec := InProcVjsxExecutor{ state: state }
	mut host := &ConfigCacheTestHost{ config_json: '{"value":1}' }
	exec.activate_lane_request_context(0, mut host, 'lane_0', HttpLogicDispatchRequest{})
	assert config_cache_eval(ctx, 'vhttpdHost.config("value")') == '1'
	assert config_cache_eval(ctx, 'vhttpdHost.config("value")') == '1'
	assert cache.entry_count() == 1
	assert config_cache_eval(ctx, 'vhttpdHost.config("new")') == ''
	host.config_json = '{"value":2,"new":false}'
	assert config_cache_eval(ctx, 'vhttpdHost.config("value")') == '2'
	assert config_cache_eval(ctx, 'vhttpdHost.config("new")') == 'false'
	assert cache.entry_count() == 2
	host.config_json = '{'
	assert config_cache_eval(ctx, 'vhttpdHost.config("value")') == ''
	host.config_json = '{"value":3}'
	exec.clear_lane_request_context(0)
	assert config_cache_eval(ctx, 'vhttpdHost.config("value")') == ''
	exec.activate_lane_request_context(0, mut host, 'lane_0', HttpLogicDispatchRequest{})
	assert config_cache_eval(ctx, 'vhttpdHost.config("value")') == '3'
	// Teardown drops retained data even if a native callback keeps the cache alive.
	state.hosts[0].config_cache = cache
	state.hosts[0].destroy()
	assert cache.is_closed()
	assert cache.entry_count() == 0
}

fn test_config_callback_caches_are_not_shared_between_runtime_sessions() {
	mut first := vjsx.new_runtime_session()
	defer { first.close() }
	mut second := vjsx.new_runtime_session()
	defer { second.close() }
	mut first_ctx := first.context()
	mut second_ctx := second.context()
	mut a := &VjsxExecutorState{ hosts: [VjsxLaneHost.empty()], lanes: [VjsxExecutionLane{ id: 'a' }] }
	mut b := &VjsxExecutorState{ hosts: [VjsxLaneHost.empty()], lanes: [VjsxExecutionLane{ id: 'b' }] }
	mut ca := InProcVjsxHostApi.install(mut first_ctx, mut a, 0)
	defer { ca.close() }
	mut cb := InProcVjsxHostApi.install(mut second_ctx, mut b, 0)
	defer { cb.close() }
	ea := InProcVjsxExecutor{ state: a }
	eb := InProcVjsxExecutor{ state: b }
	mut ha := &ConfigCacheTestHost{ config_json: '{"value":11}' }
	mut hb := &ConfigCacheTestHost{ config_json: '{"value":22}' }
	ea.activate_lane_request_context(0, mut ha, 'a', HttpLogicDispatchRequest{})
	eb.activate_lane_request_context(0, mut hb, 'b', HttpLogicDispatchRequest{})
	for _ in 0 .. 3 {
		assert config_cache_eval(first_ctx, 'vhttpdHost.config("value")') == '11'
		assert config_cache_eval(second_ctx, 'vhttpdHost.config("value")') == '22'
	}
	ca.close()
	assert ca.entry_count() == 0 && cb.entry_count() == 1
	assert config_cache_eval(second_ctx, 'vhttpdHost.config("value")') == '22'
}
