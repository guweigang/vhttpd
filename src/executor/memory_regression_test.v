module executor

import os
import time
import vjsx
import vjsx.runtimejs

fn test_compiler_context_resolves_target_profile_without_installing_business_modules() ! {
	dir := os.join_path(os.temp_dir(), 'vhttpd_compiler_profile_${os.getpid()}')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	source := os.join_path(dir, 'app.mts')
	os.write_file(source, 'export const answer: number = 42;')!
	entry := os.real_path(source)
	for profile in ['script', 'node'] {
		mut compiler := InProcVjsxRuntimeSessionFactory.new_compiler(VjsxRuntimeFacadeConfig{
			runtime_profile: profile
			app_entry:       entry
		})
		assert compiler.context().runtime_modules().len == 0
		graph := runtimejs.resolve_module_graph(compiler.context(), entry, profile)!
		assert graph.runtime_profile == profile
		emitted := runtimejs.build_runtime_module_entry(compiler.context(), entry, true, os.join_path(dir, profile))!
		assert os.exists(emitted)
		assert os.read_file(os.join_path(dir, profile, '.complete'))! == graph.cache_key
		assert compiler.context().runtime_modules().len == 0
		compiler.close()
	}
}

fn test_database_worker_callback_scopes_keep_parallel_results_separate() ! {
	mut session := vjsx.new_runtime_session()
	defer { session.close() }
	left := session.start_host_async_operation()!
	right := session.start_host_async_operation()!
	backend := DatabaseBackend{
		run_fn:   fn (request string, cancelled fn () bool) !string {
			assert !cancelled()
			time.sleep(time.millisecond)
			assert !cancelled()
			return request
		}
		close_fn: fn () {}
	}
	mut bridge := &VjsxDatabaseBridge{ workers: 2 }
	req := DatabaseWireRequest{ timeout_ms: 5000 }
	spawn vjsx_database_worker(mut bridge, backend, req, 'left', left.completion, left.cancel)
	spawn vjsx_database_worker(mut bridge, backend, req, 'right', right.completion, right.cancel)
	deadline := time.now().unix_milli() + 5000
	for session.pending_host_async_operation_count() > 0 {
		session.drain_host_async_events()!
		assert time.now().unix_milli() < deadline
		time.sleep(time.millisecond)
	}
	left_value := session.resolve_value(left.promise)!
	right_value := session.resolve_value(right.promise)!
	assert left_value.to_string() == 'left'
	assert right_value.to_string() == 'right'
	left_value.free()
	right_value.free()
	left.promise.free()
	right.promise.free()
}

fn database_memory_batch(mut session vjsx.RuntimeSession, backend DatabaseBackend, count int) ! {
	for _ in 0 .. count {
		operation := session.start_host_async_operation()!
		run_scoped_database_work(&VjsxDatabaseWork{
			database:     backend
			req:          DatabaseWireRequest{ timeout_ms: 5000 }
			request_json: 'x'.repeat(32768)
			port:         operation.completion
			token:        operation.cancel
		})!
		assert session.drain_host_async_events()! == 1
		session.drain_ready_tasks()!
		operation.promise.free()
	}
}

fn test_database_worker_releases_temporary_callbacks_and_their_request_buffers() ! {
	mut session := vjsx.new_runtime_session()
	defer { session.close() }
	backend := DatabaseBackend{
		run_fn:   fn (request string, cancelled fn () bool) !string {
			// A native backend may build borrowed callbacks while processing a
			// large request. They must not retain that buffer after it returns.
			check := fn [request, cancelled] () bool { return request.len == 32768 && !cancelled() }
			assert check()
			return 'ok'
		}
		close_fn: fn () {}
	}
	database_memory_batch(mut session, backend, 32)!
	gc_collect()
	before := gc_memory_use()
	database_memory_batch(mut session, backend, 512)!
	gc_collect()
	after := gc_memory_use()
	if gc_is_enabled() {
		assert after <= before + 2 * 1024 * 1024, 'completed database callbacks retained request buffers: ${before} -> ${after}'
	}
}

fn test_commonjs_detection_does_not_load_typescript_and_keeps_detection_semantics() ! {
	dir := os.join_path(os.temp_dir(), 'vhttpd_cjs_detection_${os.getpid()}')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	path := os.join_path(dir, 'app.js')
	mut compiler := InProcVjsxRuntimeSessionFactory.new_compiler(VjsxRuntimeFacadeConfig{})
	defer { compiler.close() }
	fixtures := {
		'globalThis.__vhttpd_handle = c => c.json({ok:true});':  false
		'module.exports = () => 42;':                            true
		'exports.answer = 42;':                                  true
		'const value = require("./dependency");':                true
		'Object.defineProperty(exports, "answer", {value:42});': true
		'export default () => require("./dependency");':         false
		'const url = import.meta.url; module.exports = 42;':     false
	}
	for source, expected in fixtures {
		os.write_file(path, source)!
		assert runtimejs.is_commonjs_module(compiler.context(), path)! == expected
	}
	ready := compiler.context().js_global('__vjs_typescript_runtime_ready')
	defer { ready.free() }
	assert ready.is_undefined()
	assert compiler.memory_usage().memory_used_size < 1024 * 1024
	// Later TS compilation must still work in a context that detected CommonJS.
	os.write_file(os.join_path(dir, 'answer.mts'), 'export const answer: number = 42;')!
	emitted := runtimejs.build_runtime_module_entry(compiler.context(), os.real_path(os.join_path(dir, 'answer.mts')), true, os.join_path(dir, 'build'))!
	assert os.exists(emitted)
}
