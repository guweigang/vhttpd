module main

import log
import time

pub struct CommandExecutor {
pub mut:
	app            &App = unsafe { nil }
	codex_enabled  bool
	codex          ProviderCommandHandler
	feishu_enabled bool
	feishu         ProviderCommandHandler
	ollama_enabled bool
	ollama         ProviderCommandHandler
	generic        ProviderCommandHandler
}

pub fn CommandExecutor.new(mut app App) CommandExecutor {
	mut codex_handler := ProviderCommandHandler(CodexCommandHandler.new(mut app))
	mut feishu_handler := ProviderCommandHandler(FeishuCommandHandler.new(mut app))
	mut ollama_handler := ProviderCommandHandler(GenericUpstreamCommandHandler.new(mut app))
	mut generic_handler := ProviderCommandHandler(GenericUpstreamCommandHandler.new(mut app))
	mut codex_enabled := CommandExecutor.codex_route_enabled()
	mut feishu_enabled := CommandExecutor.feishu_route_enabled()
	mut ollama_enabled := CommandExecutor.ollama_route_enabled()

	if spec := app.get_provider_spec('codex') {
		codex_handler = spec.handler
		codex_enabled = codex_enabled && app.provider_enabled('codex')
	}
	if spec := app.get_provider_spec('feishu') {
		feishu_handler = spec.handler
		feishu_enabled = feishu_enabled && app.provider_enabled('feishu')
	}
	if spec := app.get_provider_spec('ollama') {
		ollama_handler = spec.handler
		ollama_enabled = ollama_enabled && app.provider_enabled('ollama')
	}

	return CommandExecutor{
		app:            app
		codex_enabled:  codex_enabled
		codex:          codex_handler
		feishu_enabled: feishu_enabled
		feishu:         feishu_handler
		ollama_enabled: ollama_enabled
		ollama:         ollama_handler
		generic:        generic_handler
	}
}

fn (mut exec CommandExecutor) route_from_normalized(normalized NormalizedCommand) ProviderRouteKind {
	if normalized.is_codex_control() && exec.codex_enabled {
		return .codex
	}
	for spec in exec.app.provider_specs_copy() {
		if !spec.enabled {
			continue
		}
		if normalized.should_route_to_provider(spec.name) {
			return spec.route_kind
		}
		for matcher in spec.command_matchers {
			if matcher.matches(normalized.routing_type()) {
				return spec.route_kind
			}
		}
	}
	return .generic
}

fn (mut exec CommandExecutor) route_from_specs(command WorkerWebSocketUpstreamCommand) ProviderRouteKind {
	return exec.route_from_normalized(NormalizedCommand.from_worker_command(command))
}

pub fn CommandExecutor.codex_route_enabled() bool {
	$if no_codex_routes ? {
		return false
	}
	return true
}

pub fn CommandExecutor.feishu_route_enabled() bool {
	$if no_feishu_routes ? {
		return false
	}
	return true
}

pub fn CommandExecutor.ollama_route_enabled() bool {
	$if no_ollama_routes ? {
		return false
	}
	return true
}

// Object method: execute command envelopes against current runtime.
pub fn (mut exec CommandExecutor) execute(source_activity_id string, ctx DispatchContext, commands []WorkerWebSocketUpstreamCommand) ([]WebSocketUpstreamCommandActivity, string) {
	_ = ctx
	return exec.execute_websocket_upstream_commands(source_activity_id, commands)
}

fn (exec CommandExecutor) new_snapshot(source_activity_id string, index int, command WorkerWebSocketUpstreamCommand) WebSocketUpstreamCommandActivity {
	return WebSocketUpstreamCommandActivity{
		event:                command.event
		provider:             command.provider
		instance:             command.instance
		target_type:          command.target_type
		target:               command.target
		message_type:         command.message_type
		content:              command.content
		content_fields:       command.content_fields.clone()
		text:                 command.text
		uuid:                 command.uuid
		metadata:             command.metadata.clone()
		type_:                command.type_
		stream_id:            command.stream_id
		session_key:          command.session_key
		task_type:            command.task_type
		prompt:               command.prompt
		source_activity_id:   source_activity_id
		source_command_index: index
		status:               'skipped'
		executed_at:          time.now().unix()
	}
}

pub fn (mut exec CommandExecutor) execute_websocket_upstream_commands(source_activity_id string, commands []WorkerWebSocketUpstreamCommand) ([]WebSocketUpstreamCommandActivity, string) {
	mut last_error := ''
	mut snapshots := []WebSocketUpstreamCommandActivity{}
	log.info('[ws-cmd] executing ${commands.len} commands from ${source_activity_id}')
	for index, command in commands {
		normalized := NormalizedCommand.from_worker_command(command)
		log.info('[ws-cmd]   #${index}: type=${normalized.routing_type()} kind=${normalized.kind} event=${normalized.normalized_event('')} provider=${normalized.normalized_provider('')} stream_id=${normalized.correlation.stream_id}')
		mut snapshot := exec.new_snapshot(source_activity_id, index, command)
		if normalized.is_provider_instance_command() {
			handled, exec_err := exec.execute_provider_instance_command(normalized, mut snapshot)
			if handled {
				if exec_err != '' {
					last_error = exec_err
				}
				snapshots << snapshot
				continue
			}
		}
		route := exec.route_from_normalized(normalized)
		handled, exec_err := exec.execute_routed_command(route, command, normalized, mut snapshot)
		if handled {
			if exec_err != '' {
				last_error = exec_err
			}
			snapshots << snapshot
			continue
		}

		if normalized.routing_type() != '' && !normalized.routing_type().starts_with('feishu.') {
			snapshot.error = 'unsupported_command_type'
		} else {
			snapshot.error = 'unsupported_command_event'
		}
		snapshots << snapshot
	}
	return snapshots, last_error
}

fn (mut exec CommandExecutor) execute_provider_instance_command(normalized NormalizedCommand, mut snapshot WebSocketUpstreamCommandActivity) (bool, string) {
	mut app := exec.app
	if normalized.is_provider_instance_upsert() {
		spec := app.provider_instance_upsert(ProviderInstanceSpec{
			provider:      normalized.provider
			instance:      normalized.instance
			config_json:   normalized.config_raw
			desired_state: normalized.desired_state
		})
		app.provider_instance_apply(spec) or {
			snapshot.status = 'error'
			snapshot.error = err.msg()
			return true, err.msg()
		}
		snapshot.status = 'upserted'
		snapshot.provider = spec.provider
		snapshot.instance = spec.instance
		return true, ''
	}
	if normalized.is_provider_instance_ensure() {
		spec := app.provider_instance_ensure(normalized.provider, normalized.instance) or {
			snapshot.status = 'error'
			snapshot.error = err.msg()
			return true, err.msg()
		}
		snapshot.status = 'ensured'
		snapshot.provider = spec.provider
		snapshot.instance = spec.instance
		return true, ''
	}
	return false, ''
}

fn (mut exec CommandExecutor) execute_routed_command(route ProviderRouteKind, command WorkerWebSocketUpstreamCommand, normalized NormalizedCommand, mut snapshot WebSocketUpstreamCommandActivity) (bool, string) {
	return match route {
		.codex {
			if exec.codex_enabled {
				exec.codex.execute(command, normalized, mut snapshot)
			} else {
				false, ''
			}
		}
		.feishu {
			if exec.feishu_enabled {
				exec.feishu.execute(command, normalized, mut snapshot)
			} else {
				false, ''
			}
		}
		.ollama {
			if exec.ollama_enabled {
				exec.ollama.execute(command, normalized, mut snapshot)
			} else {
				false, ''
			}
		}
		.generic {
			exec.generic.execute(command, normalized, mut snapshot)
		}
	}
}
// Unified App-level entrypoint, now backed by CommandExecutor object.
fn (mut app App) execute_command_envelopes(source_activity_id string, ctx DispatchContext, commands []WorkerWebSocketUpstreamCommand) ([]WebSocketUpstreamCommandActivity, string) {
	mut executor := CommandExecutor.new(mut app)
	return executor.execute(source_activity_id, ctx, commands)
}
