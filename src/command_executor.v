module main

import upstream.transport
import provider
import command
import executor

// CommandHandlerAdapter wraps a provider.ProviderCommandHandler as a command.Handler.
struct CommandHandlerAdapter {
	handler provider.ProviderCommandHandler
}

fn (a CommandHandlerAdapter) execute(cmd transport.WorkerWebSocketUpstreamCommand, normalized command.NormalizedCommand, mut snapshot executor.WebSocketUpstreamCommandActivity) (bool, string) {
	mut h := a.handler
	return h.execute(cmd, normalized, mut snapshot)
}

// build_command_context constructs a command.RuntimeContext whose closures
// capture App, bridging the command sub-module to the main program.
fn (mut app App) build_command_context() command.RuntimeContext {
	mut generic_handler := GenericUpstreamCommandHandler.new(mut app)
	generic_adapter := CommandHandlerAdapter{handler: generic_handler}
	resolver_fn := fn [mut app] (normalized command.NormalizedCommand) command.ProviderRouteKind {
		if normalized.is_codex_control() && command.CommandExecutor.codex_route_enabled() {
			return .codex
		}
		for spec in app.provider_specs_copy() {
			if !spec.enabled {
				continue
			}
			if normalized.should_route_to_provider(spec.name) {
				return command.ProviderRouteKind(spec.route_kind)
			}
			for matcher in spec.command_matchers {
				if matcher.matches(normalized.routing_type()) {
					return command.ProviderRouteKind(spec.route_kind)
				}
			}
		}
		return .generic
	}
	handler_fn := fn [mut app, generic_adapter] (route command.ProviderRouteKind) ?command.Handler {
		if route == .generic {
			return command.Handler(generic_adapter)
		}
		name := match route {
			.codex { 'codex' }
			.feishu { 'feishu' }
			.ollama { 'ollama' }
			else { return none }
		}
		enabled := match route {
			.codex { command.CommandExecutor.codex_route_enabled() }
			.feishu { command.CommandExecutor.feishu_route_enabled() }
			.ollama { command.CommandExecutor.ollama_route_enabled() }
			else { false }
		}
		if !enabled || !app.provider_enabled(name) {
			return none
		}
		spec := app.get_provider_spec(name) or { return none }
		return command.Handler(CommandHandlerAdapter{handler: spec.handler})
	}
	upsert_fn := fn [mut app] (prov string, inst string, config string, state string) !command.InstanceOutcome {
		spec := app.provider_instance_upsert(provider.ProviderInstanceSpec{
			provider:      prov
			instance:      inst
			config_json:   config
			desired_state: state
		})
		app.provider_instance_apply(spec)!
		return command.InstanceOutcome{
			provider: spec.provider
			instance: spec.instance
		}
	}
	ensure_fn := fn [mut app] (prov string, inst string) !command.InstanceOutcome {
		spec := app.provider_instance_ensure(prov, inst)!
		return command.InstanceOutcome{
			provider: spec.provider
			instance: spec.instance
		}
	}
	return command.RuntimeContext{
		route_resolver:        resolver_fn
		route_handler:         handler_fn
		instance_upsert_apply: upsert_fn
		instance_ensure:       ensure_fn
	}
}

// Unified App-level entrypoint, now backed by CommandExecutor object.
pub fn (mut app App) execute_command_envelopes(source_activity_id string, ctx DispatchContext, commands []transport.WorkerWebSocketUpstreamCommand) string {
	cmd_ctx := app.build_command_context()
	mut ce := command.CommandExecutor.new(cmd_ctx)
	_, err_msg := ce.execute(source_activity_id, ctx, commands)
	return err_msg
}

// App-level entrypoint that also returns command snapshots for kernel dispatch.
fn (mut app App) execute_command_envelopes_with_snapshots(source_activity_id string, ctx DispatchContext, commands []transport.WorkerWebSocketUpstreamCommand) ([]executor.WebSocketUpstreamCommandActivity, string) {
	cmd_ctx := app.build_command_context()
	mut ce := command.CommandExecutor.new(cmd_ctx)
	return ce.execute(source_activity_id, ctx, commands)
}
