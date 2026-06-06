module command

import transport
import executor

// Handler is the command module's handler interface, mirroring
// provider.ProviderCommandHandler to avoid circular imports.
pub interface Handler {
	execute(command transport.WorkerWebSocketUpstreamCommand, normalized NormalizedCommand, mut snapshot executor.WebSocketUpstreamCommandActivity) (bool, string)
}

// InstanceOutcome is a lightweight result for provider instance operations.
pub struct InstanceOutcome {
pub:
	provider string
	instance string
}

// RuntimeContext carries closures that bridge the command sub-module
// to the main App. Each closure captures what it needs from App,
// so command/ never imports main or provider/.
pub struct RuntimeContext {
pub:
	// route_resolver resolves a normalized command to a routing target.
	route_resolver fn (NormalizedCommand) ProviderRouteKind = unsafe { nil }
	// route_handler returns the handler for a given route kind.
	route_handler fn (ProviderRouteKind) ?Handler = unsafe { nil }
	// instance_upsert_apply creates/updates an instance and applies it.
	instance_upsert_apply fn (string, string, string, string) !InstanceOutcome = unsafe { nil }
	// instance_ensure ensures an instance exists.
	instance_ensure fn (string, string) !InstanceOutcome = unsafe { nil }
}
