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
		logic_executor: new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
			thread_count: 1
		})
	}
	snapshot := app.admin_runtime_snapshot()
	assert snapshot.logic_executor == 'vjsx'
	assert snapshot.logic_executor_model == 'embedded'
	assert snapshot.logic_provider == 'vjsx'
}

fn test_internal_admin_runtime_exposes_worker_logic_executor_identity() {
	mut app := App{
		logic_executor: SocketWorkerExecutor{}
	}
	resp := app.internal_admin_dispatch(InternalAdminRequest{
		mode:   'vhttpd_admin'
		method: 'GET'
		path:   '/admin/runtime'
	})
	assert resp.status == 200
	snapshot := json.decode(AdminRuntimeSummary, resp.body) or { panic(err) }
	assert snapshot.logic_executor == 'php'
	assert snapshot.logic_executor_model == 'worker'
	assert snapshot.logic_provider == 'php-worker'
}
