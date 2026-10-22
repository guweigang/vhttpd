module executor

import vjsx

fn exception_owner_throw(ctx &vjsx.Context, value vjsx.Value) {
	marker := ctx.js_throw(value.dup_value())
	marker.free()
}

fn test_js_error_bridge_preserves_error_already_consumed_by_sdk() {
	mut session := vjsx.new_runtime_session()
	defer { session.close() }
	ctx := session.context()
	handler := ctx.eval('(() => { throw new Error("handler-owned-error"); })') or { panic(err) }
	defer { handler.free() }
	if value := session.call(handler) {
		value.free()
		assert false
	} else {
		message := InProcVjsxError.context_message(ctx, err.msg(), 'fallback')
		assert message.contains('handler-owned-error')
		assert message.contains('Error:')
	}
}

fn test_js_error_bridge_empty_slot_does_not_mask_supplied_error_or_fallback() {
	mut session := vjsx.new_runtime_session()
	defer { session.close() }
	ctx := session.context()
	assert InProcVjsxError.context_message(ctx, 'transport failed', 'fallback') == 'transport failed'
	assert InProcVjsxError.context_message(ctx, '', 'fallback') == 'fallback'
	assert InProcVjsxError.context_message(ctx, '{}', 'fallback') == 'fallback'
}

fn test_js_error_bridge_serializes_its_owned_exception_before_release() {
	mut session := vjsx.new_runtime_session()
	defer { session.close() }
	ctx := session.context()
	failure := ctx.json_parse('{"code":"owned-error","detail":42}')
	defer { failure.free() }
	exception_owner_throw(ctx, failure)
	message := InProcVjsxError.context_message(ctx, '', 'fallback')
	assert message.contains('"code":"owned-error"')
	assert message.contains('"detail":42')
	// The caller's original reference remains borrowed by the throw bridge.
	assert failure.json_stringify().contains('owned-error')
	remaining := ctx.js_exception_value()
	defer { remaining.free() }
	assert remaining.is_null() || remaining.is_uninitialized()
}

fn exception_owner_pending_error(ctx &vjsx.Context) {
	failure := ctx.eval('new Error("pending-owned-error")') or { panic(err) }
	defer { failure.free() }
	exception_owner_throw(ctx, failure)
	message := InProcVjsxError.context_message(ctx, '', 'fallback')
	assert message.contains('pending-owned-error')
}

fn test_js_error_bridge_releases_pending_error_and_diagnostic_values() {
	mut session := vjsx.new_runtime_session()
	defer { session.close() }
	ctx := session.context()
	for _ in 0 .. 2 { exception_owner_pending_error(ctx) }
	session.runtime().run_gc()
	before := session.memory_usage()
	for _ in 0 .. 200 { exception_owner_pending_error(ctx) }
	session.runtime().run_gc()
	after := session.memory_usage()
	assert after.object_count <= before.object_count + 8
	assert after.string_count <= before.string_count + 8
}

fn exception_owner_cyclic(ctx &vjsx.Context) bool {
	failure := ctx.eval('(() => { const value={}; value.self=value; return value; })()') or { panic(err) }
	defer { failure.free() }
	exception_owner_throw(ctx, failure)
	message := InProcVjsxError.context_message(ctx, 'original-failure', 'fallback')
	remaining := ctx.js_exception_value()
	defer { remaining.free() }
	result := ctx.eval('6*7') or { panic(err) }
	defer { result.free() }
	return message == 'original-failure' && (remaining.is_null() || remaining.is_uninitialized()) && result.to_int() == 42
}

fn test_js_error_bridge_cleans_failed_json_diagnostics_and_keeps_context_usable() {
	mut session := vjsx.new_runtime_session()
	defer { session.close() }
	ctx := session.context()
	for _ in 0 .. 2 {
		assert exception_owner_cyclic(ctx)
	}
	session.runtime().run_gc()
	before := session.memory_usage()
	for _ in 0 .. 200 {
		assert exception_owner_cyclic(ctx)
	}
	session.runtime().run_gc()
	after := session.memory_usage()
	assert after.object_count <= before.object_count + 8
	assert after.string_count <= before.string_count + 8
}
