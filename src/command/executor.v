module command

import transport
import executor
import log
import time

pub struct CommandExecutor {
	ctx            RuntimeContext
	codex_enabled  bool
	feishu_enabled bool
	ollama_enabled bool
}

pub fn CommandExecutor.new(ctx RuntimeContext) CommandExecutor {
	return CommandExecutor{
		ctx:            ctx
		codex_enabled:  CommandExecutor.codex_route_enabled()
		feishu_enabled: CommandExecutor.feishu_route_enabled()
		ollama_enabled: CommandExecutor.ollama_route_enabled()
	}
}

fn (mut exec CommandExecutor) route_from_normalized(normalized NormalizedCommand) ProviderRouteKind {
	return exec.ctx.route_resolver(normalized)
}

pub fn (mut exec CommandExecutor) route_from_specs(cmd transport.WorkerWebSocketUpstreamCommand) ProviderRouteKind {
	return exec.route_from_normalized(NormalizedCommand.from_worker_command(cmd))
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
pub fn (mut exec CommandExecutor) execute(source_activity_id string, ctx executor.DispatchContext, commands []transport.WorkerWebSocketUpstreamCommand) ([]executor.WebSocketUpstreamCommandActivity, string) {
	mut enriched := []transport.WorkerWebSocketUpstreamCommand{cap: commands.len}
	for cmd in commands {
		mut next := cmd
		mut metadata := cmd.metadata.clone()
		if (metadata['trace_id'] or { '' }).trim_space() == ''
			&& ctx.session.trace_id.trim_space() != '' {
			metadata['trace_id'] = ctx.session.trace_id
		}
		if (metadata['request_id'] or { '' }).trim_space() == ''
			&& ctx.session.request_id.trim_space() != '' {
			metadata['request_id'] = ctx.session.request_id
		}
		next.metadata = metadata.clone()
		enriched << next
	}
	return exec.execute_commands(source_activity_id, enriched)
}

fn (exec CommandExecutor) new_snapshot(source_activity_id string, index int, cmd transport.WorkerWebSocketUpstreamCommand) executor.WebSocketUpstreamCommandActivity {
	return executor.WebSocketUpstreamCommandActivity{
		event:                cmd.event
		provider:             cmd.provider
		instance:             cmd.instance
		target_type:          cmd.target_type
		target:               cmd.target
		message_type:         cmd.message_type
		content:              cmd.content
		content_fields:       cmd.content_fields.clone()
		text:                 cmd.text
		uuid:                 cmd.uuid
		metadata:             cmd.metadata.clone()
		type_:                cmd.type_
		stream_id:            cmd.stream_id
		session_key:          cmd.session_key
		task_type:            cmd.task_type
		prompt:               cmd.prompt
		source_activity_id:   source_activity_id
		source_command_index: index
		status:               'skipped'
		executed_at:          time.now().unix()
	}
}

pub fn (mut exec CommandExecutor) execute_commands(source_activity_id string, commands []transport.WorkerWebSocketUpstreamCommand) ([]executor.WebSocketUpstreamCommandActivity, string) {
	mut last_error := ''
	mut snapshots := []executor.WebSocketUpstreamCommandActivity{}
	log.info('[ws-cmd] executing ${commands.len} commands from ${source_activity_id}')
	for index, cmd in commands {
		normalized := NormalizedCommand.from_worker_command(cmd)
		log.info('[ws-cmd]   #${index}: type=${normalized.routing_type()} kind=${normalized.kind} event=${normalized.normalized_event('')} provider=${normalized.normalized_provider('')} stream_id=${normalized.correlation.stream_id} trace_id=${normalized.metadata['trace_id'] or {
			''
		}} request_id=${normalized.correlation.request_id}')
		mut snapshot := exec.new_snapshot(source_activity_id, index, cmd)
		if normalized.is_provider_instance_command() {
			handled, exec_err := exec.execute_instance_command(normalized, mut
				snapshot)
			if handled {
				if exec_err != '' {
					last_error = exec_err
				}
				snapshots << snapshot
				continue
			}
		}
		route := exec.route_from_normalized(normalized)
		handled, exec_err := exec.execute_routed_command(route, cmd, normalized, mut
			snapshot)
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

pub fn (mut exec CommandExecutor) execute_instance_command(normalized NormalizedCommand, mut snapshot executor.WebSocketUpstreamCommandActivity) (bool, string) {
	if normalized.is_provider_instance_upsert() {
		outcome := exec.ctx.instance_upsert_apply(normalized.provider, normalized.instance, normalized.config_raw, normalized.desired_state) or {
			snapshot.status = 'error'
			snapshot.error = err.msg()
			return true, err.msg()
		}
		snapshot.status = 'upserted'
		snapshot.provider = outcome.provider
		snapshot.instance = outcome.instance
		return true, ''
	}
	if normalized.is_provider_instance_ensure() {
		outcome := exec.ctx.instance_ensure(normalized.provider, normalized.instance) or {
			snapshot.status = 'error'
			snapshot.error = err.msg()
			return true, err.msg()
		}
		snapshot.status = 'ensured'
		snapshot.provider = outcome.provider
		snapshot.instance = outcome.instance
		return true, ''
	}
	return false, ''
}

fn (mut exec CommandExecutor) execute_routed_command(route ProviderRouteKind, cmd transport.WorkerWebSocketUpstreamCommand, normalized NormalizedCommand, mut snapshot executor.WebSocketUpstreamCommandActivity) (bool, string) {
	mut handler := exec.ctx.route_handler(route) or { return false, '' }
	return handler.execute(cmd, normalized, mut snapshot)
}
