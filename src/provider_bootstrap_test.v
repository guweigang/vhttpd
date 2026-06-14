module main
import command
import upstream.transport
import executor
import provider

fn test_provider_noop_handlers_and_runtime_smoke() {
	// Ensure NoopProviderCommandHandler and NoopProviderRuntime behave as expected
	h := provider.NoopProviderCommandHandler{}
	mut r := NoopProviderRuntime{}

	// execute should return (false, '')
	cmd := transport.WorkerWebSocketUpstreamCommand{}
	normalized := command.NormalizedCommand.from_worker_command(cmd)
	mut snap := executor.WebSocketUpstreamCommandActivity{}
	ok, msg := h.execute(cmd, normalized, mut snap)
	assert ok == false
	assert msg == ''

	// runtime snapshot and lifecycle hooks should be callable
	mut ctx := provider.RuntimeContext{}
	_ = r.snapshot(mut ctx)
	r.start(mut ctx) or { panic(err) }
	r.stop(mut ctx) or { panic(err) }
}
