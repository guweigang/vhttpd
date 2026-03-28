module main

import json

fn test_socket_worker_executor_identity() {
	executor := SocketWorkerExecutor{}
	assert executor.model() == .worker
	assert executor.kind() == 'php'
	assert executor.provider() == 'php-worker'
}

fn test_logic_executor_can_hold_inproc_vjsx_executor() {
	mut executor := LogicExecutor(new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count: 1
	}))
	assert executor.model() == .embedded
	assert executor.kind() == 'vjsx'
	assert executor.provider() == 'vjsx'
}

fn test_admin_runtime_snapshot_exposes_embedded_logic_executor_identity() {
	mut app := App{
		worker_backend_mode:      .disabled
		logic_executor_lifecycle: 'embedded_host'
		logic_executor:           new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count:    1
			module_root:     '/tmp/demo'
			signature_root:  '/tmp/demo'
			runtime_profile: 'node'
			enable_fs:       true
		})
	}
	snapshot := app.admin_runtime_snapshot()
	assert snapshot.logic_executor == 'vjsx'
	assert snapshot.logic_executor_lifecycle == 'embedded_host'
	assert snapshot.logic_executor_model == 'embedded'
	assert snapshot.logic_provider == 'vjsx'
	assert snapshot.worker_backend_mode == 'disabled'
	assert snapshot.logic_executor_details.kind == 'vjsx'
	assert snapshot.logic_executor_details.model == 'embedded'
	assert snapshot.logic_executor_details.runtime_profile == 'node'
	assert snapshot.logic_executor_details.lane_count == 1
	assert snapshot.logic_executor_details.module_root == '/tmp/demo'
	assert snapshot.logic_executor_details.enable_fs
}

fn test_internal_admin_runtime_exposes_worker_logic_executor_identity() {
	mut app := App{
		worker_backend_mode:      .required
		logic_executor_lifecycle: 'php_worker_host'
		logic_executor:           SocketWorkerExecutor{}
	}
	resp := app.internal_admin_dispatch(InternalAdminRequest{
		mode:   'vhttpd_admin'
		method: 'GET'
		path:   '/admin/runtime'
	})
	assert resp.status == 200
	snapshot := json.decode(AdminRuntimeSummary, resp.body) or { panic(err) }
	assert snapshot.logic_executor == 'php'
	assert snapshot.logic_executor_lifecycle == 'php_worker_host'
	assert snapshot.logic_executor_model == 'worker'
	assert snapshot.logic_provider == 'php-worker'
	assert snapshot.worker_backend_mode == 'required'
	assert snapshot.logic_executor_details.kind == 'php'
	assert snapshot.logic_executor_details.model == 'worker'
	assert snapshot.logic_executor_details.runtime_profile == ''
	assert snapshot.logic_executor_details.lane_count == 0
}
