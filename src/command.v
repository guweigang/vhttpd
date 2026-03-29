module main

pub struct CommandTarget {
pub:
	id    string
	type_ string
}

pub struct CommandCorrelation {
pub:
	stream_id   string
	session_key string
	task_id     string
	thread_id   string
	turn_id     string
	request_id  string
}

pub struct NormalizedCommand {
pub:
	version      string
	legacy_type  string
	kind         string
	provider     string
	instance     string
	event        string
	target       CommandTarget
	message_type string
	content      string
	content_fields map[string]string
	text         string
	uuid         string
	metadata     map[string]string
	correlation  CommandCorrelation
	task_type    string
	prompt       string
	method       string
	params       string
	config_raw   string
	desired_state string
	working_dir  string
	response_message_id string
	rpc_id       string
	rpc_result   string
	stream_finish bool
}

pub struct CommandEnvelope {
pub:
	type_     string
	provider  string
	instance  string
	target    string
	payload   string
	metadata  map[string]string
}

pub fn CommandEnvelope.from_worker_command(cmd WorkerWebSocketUpstreamCommand) CommandEnvelope {
	return CommandEnvelope{
		type_:    cmd.type_
		provider: cmd.provider
		instance: cmd.instance
		target:   cmd.target
		payload:  cmd.content
		metadata: cmd.metadata.clone()
	}
}

fn normalized_command_kind_for_legacy_type(command_type string) string {
	return match command_type {
		'codex.rpc.send' { 'provider.rpc.call' }
		'codex.rpc.reply' { 'provider.rpc.reply' }
		'codex.turn.start' { 'session.turn.start' }
		'feishu.message.send' { 'provider.message.send' }
		'feishu.message.update' { 'provider.message.update' }
		'feishu.message.patch' { 'stream.append' }
		'feishu.message.flush' { 'stream.finish' }
		else {
			if command_type.ends_with('.message.send') {
				'provider.message.send'
			} else if command_type.ends_with('.message.update') {
				'provider.message.update'
			} else {
				command_type
			}
		}
	}
}

fn normalized_command_infer_provider(command_type string, declared_provider string) string {
	if declared_provider.trim_space() != '' {
		return declared_provider.trim_space()
	}
	if command_type.contains('.') {
		return command_type.split('.')[0]
	}
	return ''
}

fn normalized_command_string_bool(raw string) bool {
	value := raw.trim_space().to_lower()
	return value in ['1', 'true', 'yes', 'on']
}

pub fn NormalizedCommand.from_worker_command(cmd WorkerWebSocketUpstreamCommand) NormalizedCommand {
	thread_id := cmd.metadata['thread_id'] or { '' }
	turn_id := cmd.metadata['turn_id'] or { '' }
	request_id := cmd.metadata['request_id'] or { '' }
	task_id := if cmd.stream_id.starts_with('codex:') {
		cmd.stream_id.replace('codex:', '')
	} else {
		cmd.metadata['task_id'] or { '' }
	}
	working_dir := cmd.metadata['cwd'] or { '' }
	response_message_id := if cmd.target_type == 'message_id' && cmd.target.trim_space() != '' {
		cmd.target.trim_space()
	} else {
		cmd.metadata['message_id'] or { '' }
	}
	rpc_id := cmd.metadata['id'] or { '' }
	rpc_result := if cmd.content.trim_space() != '' { cmd.content } else { cmd.metadata['result'] or { '{}' } }
	mode_raw := cmd.metadata['mode'] or { '' }
	finish_raw := cmd.metadata['finish'] or { '' }
	stream_finish := mode_raw == 'finish' || normalized_command_string_bool(finish_raw)
	return NormalizedCommand{
		version:     '1'
		legacy_type: cmd.type_
		kind:        normalized_command_kind_for_legacy_type(cmd.type_)
		provider:    normalized_command_infer_provider(cmd.type_, cmd.provider)
		instance:    cmd.instance
		event:       cmd.event
		target: CommandTarget{
			id:    cmd.target
			type_: cmd.target_type
		}
		message_type:  cmd.message_type
		content:       cmd.content
		content_fields: cmd.content_fields.clone()
		text:          cmd.text
		uuid:          cmd.uuid
		metadata:      cmd.metadata.clone()
		correlation: CommandCorrelation{
			stream_id:   cmd.stream_id
			session_key: cmd.session_key
			task_id:     task_id
			thread_id:   thread_id
			turn_id:     turn_id
			request_id:  request_id
		}
		task_type: cmd.task_type
		prompt:    cmd.prompt
		method:    cmd.method
		params:    cmd.params
		config_raw: if normalized_command_kind_for_legacy_type(cmd.type_) == 'provider.instance.upsert' {
			cmd.content
		} else {
			''
		}
		desired_state: cmd.metadata['desired_state'] or { '' }
		working_dir: working_dir
		response_message_id: response_message_id
		rpc_id:     rpc_id
		rpc_result: rpc_result
		stream_finish: stream_finish
	}
}

pub fn (cmd NormalizedCommand) routing_type() string {
	if cmd.legacy_type.trim_space() != '' {
		return cmd.legacy_type
	}
	return cmd.kind
}

pub fn (cmd NormalizedCommand) is_provider_message() bool {
	return cmd.kind.starts_with('provider.message.')
}

pub fn (cmd NormalizedCommand) is_provider_message_send() bool {
	return cmd.kind == 'provider.message.send'
}

pub fn (cmd NormalizedCommand) is_provider_message_update() bool {
	return cmd.kind == 'provider.message.update'
}

pub fn (cmd NormalizedCommand) is_provider_rpc() bool {
	return cmd.kind.starts_with('provider.rpc.')
}

pub fn (cmd NormalizedCommand) is_provider_rpc_call() bool {
	return cmd.kind == 'provider.rpc.call'
}

pub fn (cmd NormalizedCommand) is_provider_rpc_reply() bool {
	return cmd.kind == 'provider.rpc.reply'
}

pub fn (cmd NormalizedCommand) is_provider_instance_command() bool {
	return cmd.kind.starts_with('provider.instance.')
}

pub fn (cmd NormalizedCommand) is_provider_instance_upsert() bool {
	return cmd.kind == 'provider.instance.upsert'
}

pub fn (cmd NormalizedCommand) is_provider_instance_ensure() bool {
	return cmd.kind == 'provider.instance.ensure'
}

pub fn (cmd NormalizedCommand) is_stream_command() bool {
	return cmd.kind.starts_with('stream.')
}

pub fn (cmd NormalizedCommand) is_stream_append() bool {
	return cmd.kind == 'stream.append'
}

pub fn (cmd NormalizedCommand) is_stream_finish() bool {
	return cmd.kind == 'stream.finish'
}

pub fn (cmd NormalizedCommand) is_stream_fail() bool {
	return cmd.kind == 'stream.fail'
}

pub fn (cmd NormalizedCommand) is_session_command() bool {
	return cmd.kind.starts_with('session.')
}

pub fn (cmd NormalizedCommand) is_session_bind() bool {
	return cmd.kind == 'session.bind'
}

pub fn (cmd NormalizedCommand) is_session_clear() bool {
	return cmd.kind == 'session.clear'
}

pub fn (cmd NormalizedCommand) is_session_turn_start() bool {
	return cmd.kind == 'session.turn.start'
}

pub fn (cmd NormalizedCommand) should_route_to_provider(provider_name string) bool {
	if cmd.provider.trim_space() == '' || provider_name.trim_space() == '' {
		return false
	}
	if cmd.provider != provider_name {
		return false
	}
	return cmd.is_provider_message() || cmd.is_provider_rpc() || cmd.is_stream_command()
		|| cmd.is_session_command()
}

// Object method: semantic classification on a normalized command instance.
pub fn (cmd NormalizedCommand) is_codex_control() bool {
	return cmd.provider == 'codex'
		&& (cmd.is_provider_rpc_call() || cmd.is_provider_rpc_reply() || cmd.is_session_turn_start())
}

// Object method: infer provider with explicit field first, then type prefix fallback.
pub fn (cmd NormalizedCommand) normalized_provider(default_provider string) string {
	if cmd.provider.trim_space() != '' {
		return cmd.provider
	}
	return default_provider
}

// Object method: infer command event from normalized kind if legacy event field is empty.
pub fn (cmd NormalizedCommand) normalized_event(default_event string) string {
	if cmd.event.trim_space() != '' {
		return cmd.event
	}
	if default_event.trim_space() != '' {
		return default_event
	}
	return match cmd.kind {
		'provider.message.send' { 'send' }
		'provider.message.update', 'stream.append', 'stream.finish', 'stream.fail' { 'update' }
		else { '' }
	}
}

// Object method: semantic classification on an envelope instance.
pub fn (cmd CommandEnvelope) is_codex_control() bool {
	return cmd.type_ in ['codex.turn.start', 'codex.rpc.reply', 'codex.rpc.send']
}

// Object method: infer provider with instance data first, then type prefix fallback.
pub fn (cmd CommandEnvelope) normalized_provider(default_provider string) string {
	if cmd.provider.trim_space() != '' {
		return cmd.provider
	}
	if cmd.type_.contains('.') {
		return cmd.type_.split('.')[0]
	}
	return default_provider
}

// Object method: infer command event from type if legacy event field is empty.
pub fn (cmd CommandEnvelope) normalized_event(default_event string) string {
	if default_event.trim_space() != '' {
		return default_event
	}
	if cmd.type_ == 'feishu.message.send' {
		return 'send'
	}
	if cmd.type_ in ['feishu.message.update', 'feishu.message.patch', 'feishu.message.flush'] {
		return 'update'
	}
	return ''
}
