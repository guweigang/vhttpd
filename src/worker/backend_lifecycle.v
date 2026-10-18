module worker

import executor
import upstream.transport

@[heap]
struct BackendStart {
	done      chan bool = chan bool{}
	lifecycle executor.LogicExecutorLifecycle @[required]
}

@[heap]
struct BackendStop {
	done chan bool = chan bool{}
}

// Called under mu. The context exclusively owns the handles until publication
// or retirement; its configuration is a snapshot, never written back.
fn (mut state WorkerState) take_lifecycle_context_unlocked(port LifecyclePort) executor.LifecycleRuntimeContext {
	ctx := executor.LifecycleRuntimeContext{
		worker_backend_autostart:       state.worker_backend.autostart
		worker_backend_cmd:             state.worker_backend.cmd
		worker_backend_env:             state.worker_backend.env.clone()
		worker_backend_sockets:         state.worker_backend.sockets.clone()
		worker_backend_workdir:         state.worker_backend.workdir
		worker_backend_managed_workers: state.worker_backend.managed_workers
		emit:                           port.emit_fn
	}
	state.worker_backend.managed_workers = []transport.ManagedWorker{}
	return ctx
}

fn (state &WorkerState) backend_admission_error_unlocked() string {
	if state.backend_stop != none { return 'worker_backend_stopping' }
	if state.backend_start != none && !state.backend_started { return 'worker_backend_starting' }
	return ''
}

pub fn (mut state WorkerState) start_backend(lifecycle executor.LogicExecutorLifecycle, port LifecyclePort) {
	state.mu.@lock()
	if state.backend_stop != none {
		state.mu.unlock()
		return
	}
	if run := state.backend_start {
		state.mu.unlock()
		_ := <-run.done
		return
	}
	run := &BackendStart{ lifecycle: lifecycle }
	state.backend_start = run
	mut ctx := state.take_lifecycle_context_unlocked(port)
	state.mu.unlock()
	lifecycle.start(mut ctx)
	state.mu.@lock()
	// Stop closes admission before waiting for this publication, then takes
	// these exact resources. It cannot finish while startup still owns them.
	state.worker_backend.managed_workers = ctx.worker_backend_managed_workers
	state.backend_started = true
	run.done.close()
	state.mu.unlock()
}

pub fn (mut state WorkerState) stop_backend(lifecycle executor.LogicExecutorLifecycle, port LifecyclePort) {
	state.mu.@lock()
	if stop := state.backend_stop {
		state.mu.unlock()
		_ := <-stop.done
		return
	}
	stop := &BackendStop{}
	state.backend_stop = stop
	for _, mut generation in state.slot_generations { generation.retire() }
	start := state.backend_start
	state.mu.unlock()
	if run := start { _ := <-run.done }
	state.mu.@lock()
	mut ctx := state.take_lifecycle_context_unlocked(port)
	owned_lifecycle := if run := start { run.lifecycle } else { lifecycle }
	state.mu.unlock()
	owned_lifecycle.stop(mut ctx)
	// The state owns final native cleanup even when a custom callback retains
	// slots. Repeated native retirement is identity-checked and harmless.
	transport.ManagedWorkerPool.stop(mut ctx.worker_backend_managed_workers)
	stop.done.close()
}

pub fn (mut state WorkerState) apply_scheme(scheme string) {
	normalized := if scheme.trim_space() == 'https' { 'https' } else { 'http' }
	state.mu.@lock()
	state.worker_backend.env['VHTTPD_SCHEME'] = normalized
	state.worker_backend.env['VHTTPD_REQUEST_SCHEME'] = normalized
	state.mu.unlock()
}

pub fn (mut state WorkerState) set_env(key string, value string) {
	if key == '' { return }
	state.mu.@lock()
	state.worker_backend.env[key] = value
	state.mu.unlock()
}

pub fn (state &WorkerState) env_snapshot() map[string]string {
	state.mu.@lock()
	defer { state.mu.unlock() }
	return state.worker_backend.env.clone()
}

pub fn (state &WorkerState) backend_retiring() bool {
	state.mu.@lock()
	defer { state.mu.unlock() }
	return state.backend_stop != none
}
