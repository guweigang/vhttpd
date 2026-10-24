module executor

import json2 as json
import state_store
import time
import vjsx

fn session_ttl_call(ctx &vjsx.Context, mut state VjsxExecutorState, req InProcVjsxHostSessionStoreRequest) !InProcVjsxHostSessionStoreResponse {
	builder := InProcVjsxHostApi.session_store_builder(mut state, 0)
	callback := builder(ctx)
	defer { callback.free() }
	payload := ctx.js_string(json.encode(req))
	defer { payload.free() }
	result := ctx.call(callback, payload)!
	defer { result.free() }
	return json.decode[InProcVjsxHostSessionStoreResponse](result.to_string())!
}

fn test_embedded_session_set_and_cas_reject_overflow_and_preserve_state() ! {
	mut session := InProcVjsxRuntimeSessionFactory.new(VjsxRuntimeFacadeConfig{ runtime_profile: 'script' })!
	defer { session.close() }
	ctx := session.context()
	mut state := &VjsxExecutorState{ session_store: state_store.MemoryStateStore.new[string]() }
	for op in ['set', 'patch'] {
		state.session_store.set('ns:key', 'keep')!
		result := session_ttl_call(ctx, mut state, InProcVjsxHostSessionStoreRequest{ op: op, namespace: 'ns', key: 'key', value: 'rejected', expected_found: true, expected_value: 'keep', ttl_ms: i64(9223372036855) })!
		assert !result.ok
		assert result.error == 'state_store_ttl_out_of_range'
		assert state.session_store.get('ns:key')! == 'keep'
	}
}

fn test_embedded_session_cas_negative_ttl_stays_nonexpiring() ! {
	mut session := InProcVjsxRuntimeSessionFactory.new(VjsxRuntimeFacadeConfig{ runtime_profile: 'script' })!
	defer { session.close() }
	ctx := session.context()
	mut state := &VjsxExecutorState{ session_store: state_store.MemoryStateStore.new[string]() }
	state.session_store.set('ns:key', 'before')!
	result := session_ttl_call(ctx, mut state, InProcVjsxHostSessionStoreRequest{ op: 'patch', namespace: 'ns', key: 'key', value: 'after', expected_found: true, expected_value: 'before', ttl_ms: i64(-9223372036854775807) })!
	assert result.ok
	time.sleep(10 * time.millisecond)
	assert state.session_store.get('ns:key')! == 'after'
}
