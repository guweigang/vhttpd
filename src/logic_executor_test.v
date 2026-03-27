module main

fn test_socket_worker_executor_identity() {
	executor := SocketWorkerExecutor{}
	assert executor.kind() == 'php'
	assert executor.provider() == 'php-worker'
}

fn test_logic_executor_can_hold_inproc_vjsx_executor() {
	mut executor := LogicExecutor(new_inproc_vjsx_executor(VjsxRuntimeFacadeConfig{
		thread_count: 1
	}))
	assert executor.kind() == 'vjsx'
	assert executor.provider() == 'vjsx'
}
