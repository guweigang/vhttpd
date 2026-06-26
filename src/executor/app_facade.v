module executor

import upstream.transport
import net.http
import net.unix
import x.json2

pub interface RuntimeConfigFacade {
	get_runtime_config_json() string
	get_runtime_plan_json() string
}

pub interface WorkerBackendConfigFacade {
	worker_backend_read_timeout_ms() int
	worker_backend_sockets_len() int
	worker_env() map[string]string
	worker_env_for_kind(kind string) map[string]string
	worker_backend_read_timeout_ms_for_kind(kind string) int
}

pub interface WorkerSocketFacade {
mut:
	worker_backend_select_socket_queued() !string
	worker_backend_select_socket_for_kind(kind string) !string
	on_worker_request_started(socket_path string)
	on_worker_request_finished(socket_path string)
	worker_websocket_open(mut conn unix.StreamConn, req http.Request, remote_addr string, path string, req_id string, trace_id string) !(bool, int, string)
}

pub interface WorkerStreamDispatchFacade {
mut:
	worker_backend_dispatch_stream(req transport.StreamDispatchRequest) !transport.StreamDispatchResponse
}

pub interface WorkerMcpDispatchFacade {
mut:
	worker_backend_dispatch_mcp(req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse
}

pub interface WorkerWebSocketDispatchFacade {
mut:
	worker_backend_dispatch_websocket_upstream(req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse
	worker_backend_dispatch_websocket_event(frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse
	execute_websocket_dispatch_commands_result(commands []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult
}

pub interface PlatformFacade {
mut:
	emit(kind string, fields map[string]string)
	admin_runtime_snapshot() AdminRuntimeSummary
}

pub interface ProviderBridgeFacade {
mut:
	provider_bridge_dispatch_callback(provider string, app_name string, trace_id string, summary FeishuRuntimeEventSummary, payload string) !FeishuCardBridgeResult
}

pub interface CommandDispatchFacade {
mut:
	run_command_envelopes(request_id string, dispatch_ctx DispatchContext, commands []transport.WorkerWebSocketUpstreamCommand) string
}

pub interface AppFacade {
	RuntimeConfigFacade
	WorkerBackendConfigFacade
	WorkerSocketFacade
	WorkerStreamDispatchFacade
	WorkerMcpDispatchFacade
	WorkerWebSocketDispatchFacade
	PlatformFacade
	ProviderBridgeFacade
	CommandDispatchFacade
}

pub struct WorkerStreamDispatchPort {
mut:
	inner AppFacade
}

pub fn worker_stream_dispatch_port(inner AppFacade) WorkerStreamDispatchPort {
	return WorkerStreamDispatchPort{
		inner: inner
	}
}

pub fn (mut port WorkerStreamDispatchPort) worker_backend_dispatch_stream(req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	return port.inner.worker_backend_dispatch_stream(req)
}

pub struct WorkerMcpDispatchPort {
mut:
	inner AppFacade
}

pub fn worker_mcp_dispatch_port(inner AppFacade) WorkerMcpDispatchPort {
	return WorkerMcpDispatchPort{
		inner: inner
	}
}

pub fn (mut port WorkerMcpDispatchPort) worker_backend_dispatch_mcp(req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	return port.inner.worker_backend_dispatch_mcp(req)
}

pub struct WorkerWebSocketDispatchPort {
mut:
	inner AppFacade
}

pub fn worker_websocket_dispatch_port(inner AppFacade) WorkerWebSocketDispatchPort {
	return WorkerWebSocketDispatchPort{
		inner: inner
	}
}

pub fn (mut port WorkerWebSocketDispatchPort) worker_backend_dispatch_websocket_upstream(req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	return port.inner.worker_backend_dispatch_websocket_upstream(req)
}

pub fn (mut port WorkerWebSocketDispatchPort) worker_backend_dispatch_websocket_event(frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	return port.inner.worker_backend_dispatch_websocket_event(frame)
}

pub fn (mut port WorkerWebSocketDispatchPort) execute_websocket_dispatch_commands_result(commands []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult {
	return port.inner.execute_websocket_dispatch_commands_result(commands)
}

pub struct WorkerBackendConfigPort {
	inner AppFacade
}

pub fn worker_backend_config_port(inner AppFacade) WorkerBackendConfigPort {
	return WorkerBackendConfigPort{
		inner: inner
	}
}

pub fn (port WorkerBackendConfigPort) worker_backend_read_timeout_ms() int {
	return port.inner.worker_backend_read_timeout_ms()
}

pub fn (port WorkerBackendConfigPort) worker_backend_sockets_len() int {
	return port.inner.worker_backend_sockets_len()
}

pub fn (port WorkerBackendConfigPort) worker_env() map[string]string {
	return port.inner.worker_env()
}

pub fn (port WorkerBackendConfigPort) worker_env_for_kind(kind string) map[string]string {
	return port.inner.worker_env_for_kind(kind)
}

pub fn (port WorkerBackendConfigPort) worker_backend_read_timeout_ms_for_kind(kind string) int {
	return port.inner.worker_backend_read_timeout_ms_for_kind(kind)
}

pub struct WorkerSocketPort {
mut:
	inner AppFacade
}

pub fn worker_socket_port(inner AppFacade) WorkerSocketPort {
	return WorkerSocketPort{
		inner: inner
	}
}

pub fn (mut port WorkerSocketPort) worker_backend_select_socket_queued() !string {
	return port.inner.worker_backend_select_socket_queued()
}

pub fn (mut port WorkerSocketPort) worker_backend_select_socket_for_kind(kind string) !string {
	return port.inner.worker_backend_select_socket_for_kind(kind)
}

pub fn (mut port WorkerSocketPort) on_worker_request_started(socket_path string) {
	port.inner.on_worker_request_started(socket_path)
}

pub fn (mut port WorkerSocketPort) on_worker_request_finished(socket_path string) {
	port.inner.on_worker_request_finished(socket_path)
}

pub fn (mut port WorkerSocketPort) worker_websocket_open(mut conn unix.StreamConn, req http.Request, remote_addr string, path string, req_id string, trace_id string) !(bool, int, string) {
	return port.inner.worker_websocket_open(mut conn, req, remote_addr, path, req_id, trace_id)
}

// NoOpAppFacade is a no-op implementation of AppFacade used as a default value
// for struct fields that hold an AppFacade reference.
pub struct NoOpAppFacade {
mut:
	reserved int
}

pub fn (a NoOpAppFacade) get_runtime_config_json() string {
	return '{}'
}

pub fn (a NoOpAppFacade) get_runtime_plan_json() string {
	return '{}'
}

pub fn (a NoOpAppFacade) worker_backend_read_timeout_ms() int {
	return 0
}

pub fn (a NoOpAppFacade) worker_backend_read_timeout_ms_for_kind(kind string) int {
	return 0
}

pub fn (a NoOpAppFacade) worker_backend_sockets_len() int {
	return 0
}

pub fn (a NoOpAppFacade) worker_env() map[string]string {
	return map[string]string{}
}

pub fn (a NoOpAppFacade) worker_env_for_kind(kind string) map[string]string {
	return map[string]string{}
}

pub fn (mut a NoOpAppFacade) worker_backend_select_socket_queued() !string {
	return error('noop')
}

pub fn (mut a NoOpAppFacade) worker_backend_select_socket_for_kind(kind string) !string {
	return error('noop')
}

pub fn (mut a NoOpAppFacade) on_worker_request_started(_socket_path string) {}

pub fn (mut a NoOpAppFacade) on_worker_request_finished(_socket_path string) {}

pub fn (mut a NoOpAppFacade) worker_websocket_open(mut _conn unix.StreamConn, _req http.Request, _remote_addr string, _path string, _req_id string, _trace_id string) !(bool, int, string) {
	return error('noop')
}

pub fn (mut a NoOpAppFacade) worker_backend_dispatch_stream(_req transport.StreamDispatchRequest) !transport.StreamDispatchResponse {
	return error('noop')
}

pub fn (mut a NoOpAppFacade) worker_backend_dispatch_mcp(_req transport.WorkerMcpDispatchRequest) !transport.WorkerMcpDispatchResponse {
	return error('noop')
}

pub fn (mut a NoOpAppFacade) worker_backend_dispatch_websocket_upstream(_req transport.WorkerWebSocketUpstreamDispatchRequest) !transport.WorkerWebSocketUpstreamDispatchResponse {
	return error('noop')
}

pub fn (mut a NoOpAppFacade) worker_backend_dispatch_websocket_event(_frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	return error('noop')
}

pub fn (mut a NoOpAppFacade) emit(_kind string, _fields map[string]string) {}

pub fn (mut a NoOpAppFacade) admin_runtime_snapshot() AdminRuntimeSummary {
	return AdminRuntimeSummary{}
}

pub fn (mut a NoOpAppFacade) provider_bridge_dispatch_callback(_provider string, _app_name string, _trace_id string, _summary FeishuRuntimeEventSummary, _payload string) !FeishuCardBridgeResult {
	return error('noop')
}

pub fn (mut a NoOpAppFacade) execute_websocket_dispatch_commands_result(_commands []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult {
	return transport.WorkerWebSocketDispatchCommandsResult{}
}

pub fn (mut a NoOpAppFacade) run_command_envelopes(_request_id string, _dispatch_ctx DispatchContext, _commands []transport.WorkerWebSocketUpstreamCommand) string {
	return ''
}

pub struct FeishuRuntimeEventSummary {
pub mut:
	event_id          string
	event_kind        string
	event_type        string
	message_id        string
	message_type      string
	chat_id           string
	chat_type         string
	target_type       string
	target            string
	open_message_id   string
	root_id           string
	parent_id         string
	create_time       string
	sender_id         string
	sender_id_type    string
	sender_tenant_key string
	action_tag        string
	action_value      string
	token             string
}

fn feishu_json_field_string(obj map[string]json2.Any, key string) string {
	return FeishuRuntimeEventSummary.json_field_string(obj, key)
}

fn FeishuRuntimeEventSummary.json_field_string(obj map[string]json2.Any, key string) string {
	return (obj[key] or { json2.Any('') }).str()
}

fn feishu_json_map_field(obj map[string]json2.Any, key string) map[string]json2.Any {
	return FeishuRuntimeEventSummary.json_map_field(obj, key)
}

fn FeishuRuntimeEventSummary.json_map_field(obj map[string]json2.Any, key string) map[string]json2.Any {
	return (obj[key] or { json2.Any(map[string]json2.Any{}) }).as_map()
}

pub fn feishu_runtime_event_summary(payload string) FeishuRuntimeEventSummary {
	return FeishuRuntimeEventSummary.from_payload(payload)
}

pub fn FeishuRuntimeEventSummary.from_payload(payload string) FeishuRuntimeEventSummary {
	parsed := json2.decode[json2.Any](payload) or { return FeishuRuntimeEventSummary{} }
	root := parsed.as_map()
	header := FeishuRuntimeEventSummary.json_map_field(root, 'header')
	event := FeishuRuntimeEventSummary.json_map_field(root, 'event')
	context := FeishuRuntimeEventSummary.json_map_field(root, 'context')
	operator := FeishuRuntimeEventSummary.json_map_field(root, 'operator')
	message := FeishuRuntimeEventSummary.json_map_field(event, 'message')
	sender := FeishuRuntimeEventSummary.json_map_field(event, 'sender')
	sender_id := FeishuRuntimeEventSummary.json_map_field(sender, 'sender_id')
	mut action := FeishuRuntimeEventSummary.json_map_field(event, 'action')
	if action.len == 0 {
		action = FeishuRuntimeEventSummary.json_map_field(root, 'action')
	}
	mut operator_id_type := ''
	mut operator_id_value := ''
	for key, value in operator {
		candidate := value.str()
		if candidate == '' {
			continue
		}
		operator_id_type = key
		operator_id_value = candidate
		break
	}
	mut sender_id_type := ''
	mut sender_id_value := ''
	for key, value in sender_id {
		candidate := value.str()
		if candidate == '' {
			continue
		}
		sender_id_type = key
		sender_id_value = candidate
		break
	}
	action_value := if action_value_any := action['value'] {
		action_value_any.str()
	} else {
		''
	}
	open_message_id := if FeishuRuntimeEventSummary.json_field_string(event, 'open_message_id') != '' {
		FeishuRuntimeEventSummary.json_field_string(event, 'open_message_id')
	} else if FeishuRuntimeEventSummary.json_field_string(context, 'open_message_id') != '' {
		FeishuRuntimeEventSummary.json_field_string(context, 'open_message_id')
	} else {
		FeishuRuntimeEventSummary.json_field_string(action, 'open_message_id')
	}
	mut event_kind := 'event'
	if message.len > 0 || FeishuRuntimeEventSummary.json_field_string(message, 'message_id') != '' {
		event_kind = 'message'
	}
	if action.len > 0 || FeishuRuntimeEventSummary.json_field_string(action, 'tag') != '' {
		event_kind = 'action'
	}
	mut target_type := ''
	mut target := ''
	chat_id := FeishuRuntimeEventSummary.json_field_string(message, 'chat_id')
	if chat_id != '' {
		target_type = 'chat_id'
		target = chat_id
	} else if open_message_id != '' {
		target_type = 'open_message_id'
		target = open_message_id
	}
	return FeishuRuntimeEventSummary{
		event_id:          FeishuRuntimeEventSummary.json_field_string(header, 'event_id')
		event_kind:        event_kind
		event_type:        FeishuRuntimeEventSummary.json_field_string(header, 'event_type')
		message_id:        FeishuRuntimeEventSummary.json_field_string(message, 'message_id')
		message_type:      FeishuRuntimeEventSummary.json_field_string(message, 'message_type')
		chat_id:           chat_id
		chat_type:         FeishuRuntimeEventSummary.json_field_string(message, 'chat_type')
		target_type:       target_type
		target:            target
		open_message_id:   open_message_id
		root_id:           FeishuRuntimeEventSummary.json_field_string(message, 'root_id')
		parent_id:         FeishuRuntimeEventSummary.json_field_string(message, 'parent_id')
		create_time:       FeishuRuntimeEventSummary.json_field_string(message, 'create_time')
		sender_id:         if sender_id_value != '' { sender_id_value } else { operator_id_value }
		sender_id_type:    if sender_id_type != '' { sender_id_type } else { operator_id_type }
		sender_tenant_key: if FeishuRuntimeEventSummary.json_field_string(root, 'tenant_key') != '' {
			FeishuRuntimeEventSummary.json_field_string(root, 'tenant_key')
		} else {
			FeishuRuntimeEventSummary.json_field_string(sender, 'tenant_key')
		}
		action_tag:        FeishuRuntimeEventSummary.json_field_string(action, 'tag')
		action_value:      action_value
		token:             FeishuRuntimeEventSummary.json_field_string(root, 'token')
	}
}
