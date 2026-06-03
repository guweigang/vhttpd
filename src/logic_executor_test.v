module main

import json

fn test_disabled_logic_executor_identity() {
	executor := DisabledLogicExecutor{}
	assert executor.model() == .worker
	assert executor.kind() == 'none'
	assert executor.provider() == 'none'
}

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
		worker: WorkerState{
			worker_backend_mode: .disabled
			lifecycle:           'embedded_host'
			logic_executor:      new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
				thread_count:    1
				module_root:     '/tmp/demo'
				build_root:      '/tmp/demo-build'
				signature_root:  '/tmp/demo'
				runtime_profile: 'node'
				enable_fs:       true
			})
		}
	}
	snapshot := app.admin_runtime_snapshot()
	assert snapshot.logic_executor.kind == 'vjsx'
	assert snapshot.logic_executor.lifecycle == 'embedded_host'
	assert snapshot.logic_executor.model == 'embedded'
	assert snapshot.logic_executor.provider == 'vjsx'
	assert snapshot.worker_pool.backend_mode == 'disabled'
	assert snapshot.logic_executor.details.kind == 'vjsx'
	assert snapshot.logic_executor.details.model == 'embedded'
	assert snapshot.logic_executor.details.runtime_profile == 'node'
	assert snapshot.logic_executor.details.lane_count == 1
	assert snapshot.logic_executor.details.module_root == '/tmp/demo'
	assert snapshot.logic_executor.details.build_root == '/tmp/demo-build'
	assert snapshot.logic_executor.details.enable_fs
}

fn test_internal_admin_runtime_exposes_worker_logic_executor_identity() {
	mut app := App{
		worker: WorkerState{
			worker_backend_mode: .required
			lifecycle:           'php_worker_host'
			logic_executor:      SocketWorkerExecutor{}
		}
	}
	resp := app.internal_admin_dispatch(InternalAdminRequest{
		mode:   'vhttpd_admin'
		method: 'GET'
		path:   '/admin/runtime'
	})
	assert resp.status == 200
	snapshot := json.decode(AdminRuntimeSummary, resp.body) or { panic(err) }
	assert snapshot.logic_executor.kind == 'php'
	assert snapshot.logic_executor.lifecycle == 'php_worker_host'
	assert snapshot.logic_executor.model == 'worker'
	assert snapshot.logic_executor.provider == 'php-worker'
	assert snapshot.worker_pool.backend_mode == 'required'
	assert snapshot.logic_executor.details.kind == 'php'
	assert snapshot.logic_executor.details.model == 'worker'
	assert snapshot.logic_executor.details.runtime_profile == ''
	assert snapshot.logic_executor.details.lane_count == 0
}
