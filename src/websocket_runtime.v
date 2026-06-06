module main

import transport
import ws
import json
import net.websocket
import net.unix
import sync

// ws type aliases
type WebSocketDispatchConnState = ws.DispatchConnState
type WebSocketDispatchConnPhase = ws.DispatchConnPhase
type HubConn = ws.HubConn
type HubPendingMessage = ws.HubPendingMessage
type HubSendTarget = ws.HubSendTarget
type HubDispatchTarget = ws.HubDispatchTarget
type AdminWebSocketConnSnapshot = ws.ConnSnapshot
type AdminWebSocketRoomSnapshot = ws.RoomSnapshot
type AdminWebSocketRuntimeSnapshot = ws.RuntimeSnapshot

// ws function aliases — use DispatchConnState receiver methods directly

struct WebSocketHubRuntime {}

struct WebSocketPresenceSnapshot {
	room_members    map[string][]string
	member_metadata map[string]map[string]string
	room_counts     map[string]int
	presence_users  map[string][]string
}

struct WebSocketRuntimeContext {
	dispatch_targets_fn fn (string, string) []HubDispatchTarget = unsafe { nil }
	presence_fn         fn (string) WebSocketPresenceSnapshot   = unsafe { nil }
	rooms_fn            fn (string) []string                    = unsafe { nil }
	metadata_fn         fn (string) map[string]string           = unsafe { nil }
	register_conn_fn    fn (string, string, string, string, string, string, map[string]string, map[string]string, string, &websocket.Client, &WebSocketDispatchConnState) = unsafe { nil }
	mark_closing_fn     fn (string) bool                        = unsafe { nil }
	flush_pending_fn    fn (string)                             = unsafe { nil }
	cleanup_conn_fn     fn (string)                             = unsafe { nil }
	unregister_conn_fn  fn (string)                             = unsafe { nil }
	send_to_fn          fn (string, string, string) bool        = unsafe { nil }
	join_fn             fn (string, string) bool                = unsafe { nil }
	leave_fn            fn (string, string) bool                = unsafe { nil }
	set_meta_fn         fn (string, string, string) bool        = unsafe { nil }
	clear_meta_fn       fn (string, string) bool                = unsafe { nil }
	broadcast_fn        fn (string, string, string, string) int = unsafe { nil }
	build_frame_fn      fn (string, string, string, map[string]string, map[string]string, string, string, string, string, string, int, string, []string, map[string]string, WebSocketPresenceSnapshot) transport.WorkerWebSocketFrame = unsafe { nil }
	dispatch_event_fn   fn (transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse        = unsafe { nil }
	command_result_fn   fn ([]transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult = unsafe { nil }
	followup_failure_fn fn (string, string, string, map[string]string, map[string]string, string, string, string, []transport.WorkerWebSocketDispatchCommandFailure) ?transport.WorkerWebSocketFrame = unsafe { nil }
	close_target_fn     fn (string, int, string) = unsafe { nil }
}

fn (rt WebSocketRuntimeContext) dispatch_targets(room string, except_id string) []HubDispatchTarget {
	return rt.dispatch_targets_fn(room, except_id)
}

fn (rt WebSocketRuntimeContext) presence(conn_id string) WebSocketPresenceSnapshot {
	return rt.presence_fn(conn_id)
}

fn (rt WebSocketRuntimeContext) rooms(conn_id string) []string {
	return rt.rooms_fn(conn_id)
}

fn (rt WebSocketRuntimeContext) metadata(conn_id string) map[string]string {
	return rt.metadata_fn(conn_id)
}

fn (rt WebSocketRuntimeContext) register_conn(conn_id string, worker_socket string, method string, req_id string, trace_id string, path string, query map[string]string, headers map[string]string, remote_addr string, client &websocket.Client, lifecycle &WebSocketDispatchConnState) {
	rt.register_conn_fn(conn_id, worker_socket, method, req_id, trace_id, path, query, headers,
		remote_addr, client, lifecycle)
}

fn (rt WebSocketRuntimeContext) mark_closing(conn_id string) bool {
	return rt.mark_closing_fn(conn_id)
}

fn (rt WebSocketRuntimeContext) flush_pending(conn_id string) {
	rt.flush_pending_fn(conn_id)
}

fn (rt WebSocketRuntimeContext) cleanup_conn(conn_id string) {
	rt.cleanup_conn_fn(conn_id)
}

fn (rt WebSocketRuntimeContext) unregister_conn(conn_id string) {
	rt.unregister_conn_fn(conn_id)
}

fn (rt WebSocketRuntimeContext) send_to(conn_id string, data string, opcode string) bool {
	return rt.send_to_fn(conn_id, data, opcode)
}

fn (rt WebSocketRuntimeContext) join(conn_id string, room string) bool {
	return rt.join_fn(conn_id, room)
}

fn (rt WebSocketRuntimeContext) leave(conn_id string, room string) bool {
	return rt.leave_fn(conn_id, room)
}

fn (rt WebSocketRuntimeContext) set_meta(conn_id string, key string, value string) bool {
	return rt.set_meta_fn(conn_id, key, value)
}

fn (rt WebSocketRuntimeContext) clear_meta(conn_id string, key string) bool {
	return rt.clear_meta_fn(conn_id, key)
}

fn (rt WebSocketRuntimeContext) broadcast(room string, data string, opcode string, except_id string) int {
	return rt.broadcast_fn(room, data, opcode, except_id)
}

fn (rt WebSocketRuntimeContext) build_frame(event string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, opcode string, data string, code int, reason string, rooms []string, metadata map[string]string, presence WebSocketPresenceSnapshot) transport.WorkerWebSocketFrame {
	return rt.build_frame_fn(event, method, path, query, headers, remote_addr, req_id, trace_id,
		opcode, data, code, reason, rooms, metadata, presence)
}

fn (rt WebSocketRuntimeContext) dispatch_event(frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	return rt.dispatch_event_fn(frame)
}

fn (rt WebSocketRuntimeContext) command_result(commands []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult {
	return rt.command_result_fn(commands)
}

fn (rt WebSocketRuntimeContext) followup_failure(conn_id string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, failures []transport.WorkerWebSocketDispatchCommandFailure) ?transport.WorkerWebSocketFrame {
	return rt.followup_failure_fn(conn_id, method, path, query, headers, remote_addr, req_id,
		trace_id, failures)
}

fn (rt WebSocketRuntimeContext) close_target(conn_id string, code int, reason string) {
	rt.close_target_fn(conn_id, code, reason)
}

fn (rt WebSocketRuntimeContext) process_worker_frame(frame transport.WorkerWebSocketFrame) ?transport.WorkerWebSocketDispatchCommandFailure {
	return WebSocketHubRuntime.process_worker_frame(rt, frame)
}

fn (mut app App) build_websocket_runtime_context() WebSocketRuntimeContext {
	return WebSocketRuntimeContext{
		dispatch_targets_fn: fn [mut app] (room string, except_id string) []HubDispatchTarget {
			return WebSocketHubRuntime.dispatch_targets(mut app.ws_hub, room, except_id)
		}
		presence_fn:         fn [mut app] (conn_id string) WebSocketPresenceSnapshot {
			room_members, member_metadata, room_counts, presence_users :=
				app.ws_hub_presence_snapshot(conn_id)
			return WebSocketPresenceSnapshot{
				room_members:    room_members
				member_metadata: member_metadata
				room_counts:     room_counts
				presence_users:  presence_users
			}
		}
		rooms_fn:            fn [mut app] (conn_id string) []string {
			return app.ws_hub_rooms_snapshot(conn_id)
		}
		metadata_fn:         fn [mut app] (conn_id string) map[string]string {
			return app.ws_hub_meta_snapshot(conn_id)
		}
		register_conn_fn:    fn [mut app] (conn_id string, worker_socket string, method string, req_id string, trace_id string, path string, query map[string]string, headers map[string]string, remote_addr string, client &websocket.Client, lifecycle &WebSocketDispatchConnState) {
			app.ws_hub.register_conn(conn_id, worker_socket, method, req_id, trace_id, path,
				query, headers, remote_addr, client, lifecycle)
		}
		mark_closing_fn:     fn [mut app] (conn_id string) bool {
			return app.ws_hub.mark_closing(conn_id)
		}
		flush_pending_fn:    fn [mut app] (conn_id string) {
			app.ws_hub.flush_pending(conn_id)
		}
		cleanup_conn_fn:     fn [mut app] (conn_id string) {
			app.ws_hub.cleanup_conn(conn_id)
		}
		unregister_conn_fn:  fn [mut app] (conn_id string) {
			app.ws_hub.unregister_conn(conn_id)
		}
		send_to_fn:          fn [mut app] (conn_id string, data string, opcode string) bool {
			return WebSocketHubRuntime.send_to(mut app.ws_hub, conn_id, data, opcode)
		}
		join_fn:             fn [mut app] (conn_id string, room string) bool {
			return app.ws_hub.join(conn_id, room)
		}
		leave_fn:            fn [mut app] (conn_id string, room string) bool {
			return app.ws_hub.leave(conn_id, room)
		}
		set_meta_fn:         fn [mut app] (conn_id string, key string, value string) bool {
			return app.ws_hub.set_meta(conn_id, key, value)
		}
		clear_meta_fn:       fn [mut app] (conn_id string, key string) bool {
			return app.ws_hub.clear_meta(conn_id, key)
		}
		broadcast_fn:        fn [mut app] (room string, data string, opcode string, except_id string) int {
			return WebSocketHubRuntime.broadcast(mut app.ws_hub, room, data, opcode, except_id)
		}
		build_frame_fn:      fn [mut app] (event string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, opcode string, data string, code int, reason string, rooms []string, metadata map[string]string, presence WebSocketPresenceSnapshot) transport.WorkerWebSocketFrame {
			return app.kernel_websocket_dispatch_frame(event, method, path, query, headers,
				remote_addr, req_id, trace_id, opcode, data, code, reason, rooms, metadata,
				presence.room_members, presence.member_metadata, presence.room_counts,
				presence.presence_users)
		}
		dispatch_event_fn:   fn [mut app] (frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
			return app.kernel_dispatch_websocket_event(frame)
		}
		command_result_fn:   fn [mut app] (commands []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult {
			return app.execute_websocket_dispatch_commands_result(commands)
		}
		followup_failure_fn: fn [mut app] (conn_id string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, failures []transport.WorkerWebSocketDispatchCommandFailure) ?transport.WorkerWebSocketFrame {
			return app.websocket_dispatch_followup_failures(conn_id, method, path, query, headers,
				remote_addr, req_id, trace_id, failures)
		}
		close_target_fn:     fn [mut app] (conn_id string, code int, reason string) {
			WebSocketHubRuntime.close_target(mut app.ws_hub, conn_id, code, reason)
		}
	}
}

@[heap]
struct WebSocketBridgeState {
mut:
	worker_conn            unix.StreamConn
	rt                     WebSocketRuntimeContext
	worker_socket          string
	conn_id                string
	method                 string
	path                   string
	request_id             string
	trace_id               string
	start_ms               i64
	worker_initiated_close bool
	close_notified         bool
	cb_mu                  sync.Mutex
}

@[heap]
struct WebSocketDispatchBridgeState {
mut:
	lifecycle     &WebSocketDispatchConnState = unsafe { nil }
	rt            WebSocketRuntimeContext
	open_commands []transport.WorkerWebSocketFrame
	conn_id       string
	method        string
	path          string
	query         map[string]string
	headers       map[string]string
	remote_addr   string
	request_id    string
	trace_id      string
	start_ms      i64
}

fn (mut app App) websocket_dispatch_command_failures_frame(conn_id string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, failures []transport.WorkerWebSocketDispatchCommandFailure) transport.WorkerWebSocketFrame {
	room_members, member_metadata, room_counts, presence_users :=
		app.ws_hub_presence_snapshot(conn_id)
	base_frame := app.kernel_websocket_dispatch_frame('info', method, path, query, headers,
		remote_addr, req_id, trace_id, 'text', json.encode(transport.WorkerWebSocketDispatchFailureEnvelope{
		event:    'command_failures'
		failures: failures
	}), 0, '', app.ws_hub_rooms_snapshot(conn_id), app.ws_hub_meta_snapshot(conn_id), room_members,
		member_metadata, room_counts, presence_users)
	return transport.WorkerWebSocketFrame{
		...base_frame
		error:       'websocket_dispatch_command_failed'
		error_class: 'websocket_send_failed'
	}
}

fn (mut app App) websocket_dispatch_followup_failures(conn_id string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, failures []transport.WorkerWebSocketDispatchCommandFailure) ?transport.WorkerWebSocketFrame {
	_ = app
	_ = conn_id
	_ = method
	_ = path
	_ = query
	_ = headers
	_ = remote_addr
	_ = req_id
	_ = trace_id
	_ = failures
	// Upstream relay keeps transport-level send failures out of the session actor.
	// Mirror that here by not feeding command failures back into the app's
	// websocket handler as synthetic `info` events.
	return none
}

fn (mut app App) ws_hub_cleanup_conn(conn_id string) {
	app.ws_hub.cleanup_conn(conn_id)
}

fn (mut app App) ws_hub_register_conn(conn_id string, worker_socket string, method string, req_id string, trace_id string, path string, query map[string]string, headers map[string]string, remote_addr string, client &websocket.Client, lifecycle &WebSocketDispatchConnState) {
	app.ws_hub.register_conn(conn_id, worker_socket, method, req_id, trace_id, path, query,
		headers, remote_addr, client, lifecycle)
}

fn (mut app App) ws_hub_mark_closing(conn_id string) bool {
	return app.ws_hub.mark_closing(conn_id)
}

fn (mut app App) ws_hub_flush_pending(conn_id string) {
	app.ws_hub.flush_pending(conn_id)
}

fn (mut app App) ws_hub_rooms_snapshot(conn_id string) []string {
	return app.ws_hub.rooms_snapshot(conn_id)
}

fn (mut app App) ws_hub_meta_snapshot(conn_id string) map[string]string {
	return app.ws_hub.meta_snapshot(conn_id)
}

fn (mut app App) ws_hub_set_meta(conn_id string, key string, value string) bool {
	return app.ws_hub.set_meta(conn_id, key, value)
}

fn (mut app App) ws_hub_clear_meta(conn_id string, key string) bool {
	return app.ws_hub.clear_meta(conn_id, key)
}

fn (mut app App) ws_hub_presence_snapshot(conn_id string) (map[string][]string, map[string]map[string]string, map[string]int, map[string][]string) {
	return app.ws_hub.presence_snapshot(conn_id)
}

fn (mut app App) ws_hub_unregister_conn(conn_id string) {
	app.ws_hub.unregister_conn(conn_id)
}

fn (mut app App) ws_hub_join(conn_id string, room string) bool {
	return app.ws_hub.join(conn_id, room)
}

fn (mut app App) ws_hub_leave(conn_id string, room string) bool {
	return app.ws_hub.leave(conn_id, room)
}

fn (mut app App) ws_hub_send_client(conn_id string, client &websocket.Client, data string, opcode string) bool {
	return app.ws_hub.send_client(conn_id, client, data, opcode)
}

fn (mut app App) ws_hub_send_to(conn_id string, data string, opcode string) bool {
	return WebSocketHubRuntime.send_to(mut app.ws_hub, conn_id, data, opcode)
}

fn WebSocketHubRuntime.send_to(mut hub ws.HubState, conn_id string, data string, opcode string) bool {
	if conn_id == '' {
		return false
	}
	mut client := &websocket.Client(unsafe { nil })
	mut queued := false
	hub.mu.@lock()
	if hub_conn := hub.conns[conn_id] {
		if !hub_conn.lifecycle.can_send() {
			if hub_conn.lifecycle.can_queue() {
				mut pending := hub.pending[conn_id] or { []HubPendingMessage{} }
				pending << HubPendingMessage{
					data:   data
					opcode: if opcode == '' { 'text' } else { opcode }
				}
				hub.pending[conn_id] = pending
				queued = true
				hub.mu.unlock()
				return true
			}
			hub.mu.unlock()
			return false
		}
		client = hub_conn.client
	} else {
		mut pending := hub.pending[conn_id] or { []HubPendingMessage{} }
		pending << HubPendingMessage{
			data:   data
			opcode: if opcode == '' { 'text' } else { opcode }
		}
		hub.pending[conn_id] = pending
		queued = true
	}
	hub.mu.unlock()
	if isnil(client) {
		return queued
	}
	return hub.send_client(conn_id, client, data, opcode)
}

fn (mut app App) ws_hub_broadcast(room string, data string, opcode string, except_id string) int {
	return WebSocketHubRuntime.broadcast(mut app.ws_hub, room, data, opcode, except_id)
}

fn WebSocketHubRuntime.broadcast(mut hub ws.HubState, room string, data string, opcode string, except_id string) int {
	if room == '' {
		return 0
	}
	mut targets := []HubSendTarget{}
	hub.mu.@lock()
	if members := hub.room_members[room] {
		for conn_id, _ in members {
			if except_id != '' && conn_id == except_id {
				continue
			}
			if hub_conn := hub.conns[conn_id] {
				targets << HubSendTarget{
					id:     conn_id
					client: unsafe { hub_conn.client }
				}
			} else {
				mut pending := hub.pending[conn_id] or { []HubPendingMessage{} }
				pending << HubPendingMessage{
					data:   data
					opcode: if opcode == '' { 'text' } else { opcode }
				}
				hub.pending[conn_id] = pending
			}
		}
	}
	hub.mu.unlock()
	mut delivered := 0
	for target in targets {
		if hub.send_client(target.id, target.client, data, opcode) {
			delivered++
		}
	}
	return delivered
}

fn (mut app App) ws_hub_broadcast_dispatch(room string, data string, except_id string) int {
	websocket_runtime := app.build_websocket_runtime_context()
	return WebSocketHubRuntime.broadcast_dispatch(websocket_runtime, room, data, except_id)
}

fn WebSocketHubRuntime.dispatch_targets(mut hub ws.HubState, room string, except_id string) []HubDispatchTarget {
	if room == '' {
		return []HubDispatchTarget{}
	}
	mut targets := []HubDispatchTarget{}
	hub.mu.@lock()
	if members := hub.room_members[room] {
		for conn_id, _ in members {
			if except_id != '' && conn_id == except_id {
				continue
			}
			if hub_conn := hub.conns[conn_id] {
				targets << HubDispatchTarget{
					id:          conn_id
					method:      if hub_conn.method == '' { 'GET' } else { hub_conn.method }
					request_id:  hub_conn.request_id
					trace_id:    hub_conn.trace_id
					path:        hub_conn.path
					query:       hub_conn.query.clone()
					headers:     hub_conn.headers.clone()
					remote_addr: hub_conn.remote_addr
				}
			}
		}
	}
	hub.mu.unlock()
	return targets
}

fn WebSocketHubRuntime.broadcast_dispatch(rt WebSocketRuntimeContext, room string, data string, except_id string) int {
	if room == '' {
		return 0
	}
	targets := rt.dispatch_targets(room, except_id)
	mut delivered := 0
	for target in targets {
		presence := rt.presence(target.id)
		base_frame := rt.build_frame('info', target.method, target.path, target.query,
			target.headers, target.remote_addr, target.request_id, target.trace_id, 'text', data,
			0, '', rt.rooms(target.id), rt.metadata(target.id), presence)
		info_frame := transport.WorkerWebSocketFrame{
			...base_frame
			room: room
		}
		resp := rt.dispatch_event(info_frame) or { continue }
		mut forwarded_commands := []transport.WorkerWebSocketFrame{cap: resp.commands.len}
		for cmd in resp.commands {
			if cmd.event == 'send' || cmd.event == 'send_to' || cmd.event == 'join'
				|| cmd.event == 'leave' || cmd.event == 'set_meta' || cmd.event == 'clear_meta'
				|| cmd.event == 'broadcast' || cmd.event == 'broadcast_dispatch'
				|| cmd.event == 'close' {
				forwarded_commands << transport.WorkerWebSocketFrame{
					...cmd
					id: target.id
				}
			} else {
				forwarded_commands << cmd
			}
		}
		if resp.event == 'error' {
			continue
		}
		result := rt.command_result(forwarded_commands)
		if result.has_close {
			close_frame := result.close_frame
			code := if close_frame.code > 0 { close_frame.code } else { 1000 }
			rt.close_target(target.id, code, close_frame.reason)
			continue
		}
		if result.failures.len > 0 {
			if close_frame := rt.followup_failure(target.id, target.method, target.path,
				target.query, target.headers, target.remote_addr, target.request_id,
				target.trace_id, result.failures)
			{
				code := if close_frame.code > 0 { close_frame.code } else { 1000 }
				rt.close_target(target.id, code, close_frame.reason)
			}
		}
		delivered++
	}
	return delivered
}

fn (mut app App) ws_hub_close_target(conn_id string, code int, reason string) {
	WebSocketHubRuntime.close_target(mut app.ws_hub, conn_id, code, reason)
}

fn WebSocketHubRuntime.close_target(mut hub ws.HubState, conn_id string, code int, reason string) {
	if conn_id == '' {
		return
	}
	mut client := &websocket.Client(unsafe { nil })
	hub.mu.@lock()
	if hub_conn := hub.conns[conn_id] {
		if !hub_conn.lifecycle.mark_closing() {
			hub.mu.unlock()
			return
		}
		client = hub_conn.client
	}
	hub.pending.delete(conn_id)
	hub.mu.unlock()
	if isnil(client) {
		return
	}
	spawn WebSocketHubRuntime.close_client(mut hub, client, code, reason)
}

fn WebSocketHubRuntime.close_client(mut hub ws.HubState, client &websocket.Client, code int, reason string) {
	if isnil(client) {
		return
	}
	hub.send_mu.@lock()
	defer {
		hub.send_mu.unlock()
	}
	mut c := unsafe { client }
	c.close(code, reason) or {}
}

fn (mut app App) process_worker_websocket_hub_frame(frame transport.WorkerWebSocketFrame) ?transport.WorkerWebSocketDispatchCommandFailure {
	websocket_runtime := app.build_websocket_runtime_context()
	return WebSocketHubRuntime.process_worker_frame(websocket_runtime, frame)
}

fn WebSocketHubRuntime.process_worker_frame(rt WebSocketRuntimeContext, frame transport.WorkerWebSocketFrame) ?transport.WorkerWebSocketDispatchCommandFailure {
	match frame.event {
		'send' {
			target := if frame.target_id != '' { frame.target_id } else { frame.id }
			if !rt.send_to(target, frame.data, frame.opcode) {
				return transport.WorkerWebSocketDispatchCommandFailure{
					event:       frame.event
					id:          frame.id
					target_id:   target
					opcode:      frame.opcode
					error:       'websocket_send_failed'
					error_class: 'websocket_send_failed'
				}
			}
			return none
		}
		'send_to' {
			target := if frame.target_id != '' { frame.target_id } else { frame.id }
			if !rt.send_to(target, frame.data, frame.opcode) {
				return transport.WorkerWebSocketDispatchCommandFailure{
					event:       frame.event
					id:          frame.id
					target_id:   target
					opcode:      frame.opcode
					error:       'websocket_send_failed'
					error_class: 'websocket_send_failed'
				}
			}
			return none
		}
		'join' {
			rt.join(frame.id, frame.room)
			return none
		}
		'leave' {
			rt.leave(frame.id, frame.room)
			return none
		}
		'set_meta' {
			rt.set_meta(frame.id, frame.key, frame.value)
			return none
		}
		'clear_meta' {
			rt.clear_meta(frame.id, frame.key)
			return none
		}
		'broadcast' {
			rt.broadcast(frame.room, frame.data, frame.opcode, frame.except_id)
			return none
		}
		'broadcast_dispatch' {
			WebSocketHubRuntime.broadcast_dispatch(rt, frame.room, frame.data, frame.except_id)
			return none
		}
		'close' {
			target := if frame.target_id != '' { frame.target_id } else { frame.id }
			rt.close_target(target, if frame.code > 0 {
				frame.code
			} else {
				1000
			}, frame.reason)
			return none
		}
		else {}
	}

	return none
}

fn (mut app App) admin_websockets_snapshot(details bool, limit int, offset int, room_filter string, conn_filter string) AdminWebSocketRuntimeSnapshot {
	return WebSocketHubRuntime.snapshot(mut app.ws_hub, details, limit, offset, room_filter,
		conn_filter)
}

fn WebSocketHubRuntime.snapshot(mut hub ws.HubState, details bool, limit int, offset int, room_filter string, conn_filter string) AdminWebSocketRuntimeSnapshot {
	hub.mu.@lock()
	defer {
		hub.mu.unlock()
	}
	mut connections := []AdminWebSocketConnSnapshot{}
	for socket_conn_id, conn in hub.conns {
		mut joined_rooms := []string{}
		if joined := hub.conn_rooms[socket_conn_id] {
			for room, present in joined {
				if present {
					joined_rooms << room
				}
			}
		}
		joined_rooms.sort()
		if conn_filter != '' && socket_conn_id != conn_filter {
			continue
		}
		if room_filter != '' && room_filter !in joined_rooms {
			continue
		}
		connections << AdminWebSocketConnSnapshot{
			id:         socket_conn_id
			request_id: conn.request_id
			trace_id:   conn.trace_id
			path:       conn.path
			rooms:      joined_rooms
			metadata:   (hub.conn_meta[socket_conn_id] or {
				map[string]string{}
			}).clone()
		}
	}
	mut ordered_connections := []AdminWebSocketConnSnapshot{}
	mut connection_keys := []string{}
	mut connection_by_key := map[string]AdminWebSocketConnSnapshot{}
	for conn in connections {
		connection_keys << conn.id
		connection_by_key[conn.id] = conn
	}
	connection_keys.sort()
	for key in connection_keys {
		ordered_connections << connection_by_key[key]
	}
	mut filtered_conn_ids := map[string]bool{}
	for conn in ordered_connections {
		filtered_conn_ids[conn.id] = true
	}
	mut rooms := []AdminWebSocketRoomSnapshot{}
	for room_name, members_map in hub.room_members {
		if room_filter != '' && room_name != room_filter {
			continue
		}
		mut members := []string{}
		for member_conn_id, present in members_map {
			if present && (conn_filter == '' || filtered_conn_ids[member_conn_id]) {
				members << member_conn_id
			}
		}
		if conn_filter != '' && conn_filter !in members {
			continue
		}
		members.sort()
		rooms << AdminWebSocketRoomSnapshot{
			name:         room_name
			member_count: members.len
			members:      members
		}
	}
	mut ordered_rooms := []AdminWebSocketRoomSnapshot{}
	mut room_keys := []string{}
	mut room_by_key := map[string]AdminWebSocketRoomSnapshot{}
	for room in rooms {
		room_keys << room.name
		room_by_key[room.name] = room
	}
	room_keys.sort()
	for key in room_keys {
		ordered_rooms << room_by_key[key]
	}
	if !details {
		return AdminWebSocketRuntimeSnapshot{
			active_connections:   hub.conns.len
			active_rooms:         hub.room_members.len
			returned_connections: 0
			returned_rooms:       0
			details:              false
			limit:                limit
			offset:               offset
			room_filter:          room_filter
			conn_id:              conn_filter
			connections:          []AdminWebSocketConnSnapshot{}
			rooms:                []AdminWebSocketRoomSnapshot{}
		}
	}
	mut sliced_connections := []AdminWebSocketConnSnapshot{}
	if offset < ordered_connections.len {
		end := if offset + limit < ordered_connections.len {
			offset + limit
		} else {
			ordered_connections.len
		}
		for i in offset .. end {
			sliced_connections << ordered_connections[i]
		}
	}
	mut sliced_rooms := []AdminWebSocketRoomSnapshot{}
	if offset < ordered_rooms.len {
		end := if offset + limit < ordered_rooms.len { offset + limit } else { ordered_rooms.len }
		for i in offset .. end {
			sliced_rooms << ordered_rooms[i]
		}
	}
	return AdminWebSocketRuntimeSnapshot{
		active_connections:   hub.conns.len
		active_rooms:         hub.room_members.len
		returned_connections: sliced_connections.len
		returned_rooms:       sliced_rooms.len
		details:              true
		limit:                limit
		offset:               offset
		room_filter:          room_filter
		conn_id:              conn_filter
		connections:          sliced_connections
		rooms:                sliced_rooms
	}
}
