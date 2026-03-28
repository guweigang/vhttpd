module main

fn test_provider_noop_handlers_and_runtime_smoke() {
	// Ensure NoopProviderCommandHandler and NoopProviderRuntime behave as expected
	h := NoopProviderCommandHandler{}
	r := NoopProviderRuntime{}

	// execute should return (false, '')
	cmd := WorkerWebSocketUpstreamCommand{}
	normalized := NormalizedCommand.from_worker_command(cmd)
	mut snap := WebSocketUpstreamCommandActivity{}
	ok, msg := h.execute(cmd, normalized, mut snap)
	assert ok == false
	assert msg == ''

	// runtime snapshot and lifecycle hooks should be callable
	_ = r.snapshot(mut App{})
	mut app := App{}
	r.start(mut app) or { panic(err) }
	r.stop(mut app) or { panic(err) }
}
