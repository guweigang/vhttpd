module ws

import upstream.transport
import net.websocket
import sync
import net.unix
import connection_runtime
import net
import os

// PresenceSnapshot captures room/metadata presence data for a single connection.
pub struct PresenceSnapshot {
pub:
	room_members    map[string][]string
	member_metadata map[string]map[string]string
	room_counts     map[string]int
	presence_users  map[string][]string
}

// RuntimePort keeps hub ownership in ordinary GC references. RuntimeContext
// also supports explicit callback overrides for injected adapters and tests.
pub interface RuntimePort {
	dispatch_targets(room string, except_id string) []HubDispatchTarget
	presence(conn_id string) PresenceSnapshot
	rooms(conn_id string) []string
	metadata(conn_id string) map[string]string
	register_conn(conn_id string, worker_socket string, method string, req_id string, trace_id string, path string, query map[string]string, headers map[string]string, remote_addr string, client &websocket.Client, lifecycle &DispatchConnState, serving ?&IngressRun)
	conn_open(conn_id string) bool
	mark_closing(conn_id string, lifecycle &DispatchConnState) bool
	flush_pending(conn_id string)
	can_cleanup(id string, lifecycle &DispatchConnState) bool
	cleanup_conn(conn_id string, lifecycle &DispatchConnState)
	unregister_conn(conn_id string, lifecycle &DispatchConnState)
	send_to(conn_id string, data string, opcode string) bool
	join(conn_id string, room string) bool
	leave(conn_id string, room string) bool
	set_meta(conn_id string, key string, value string) bool
	clear_meta(conn_id string, key string) bool
	broadcast(room string, data string, opcode string, except_id string) int
	command_result(commands []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult
	close_owned_target(id string, lifecycle &DispatchConnState, code int, reason string)
	close_target(conn_id string, code int, reason string)
	emit(kind string, fields map[string]string)
	build_frame(event string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, opcode string, data string, code int, reason string, rooms []string, metadata map[string]string, presence PresenceSnapshot) transport.WorkerWebSocketFrame
	dispatch_event(frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse
	followup_failure(conn_id string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, failures []transport.WorkerWebSocketDispatchCommandFailure) ?transport.WorkerWebSocketFrame
}

pub struct RuntimeContext {
pub:
	owner               ?RuntimePort
	emit_fn             ?fn (string, map[string]string)
	ingress_run         ?&IngressRun
	dispatch_targets_fn ?fn (string, string) []HubDispatchTarget
	presence_fn         ?fn (string) PresenceSnapshot
	rooms_fn            ?fn (string) []string
	metadata_fn         ?fn (string) map[string]string
	register_conn_fn    ?fn (string, string, string, string, string, string, map[string]string, map[string]string, string, &websocket.Client, &DispatchConnState, ?&IngressRun)
	conn_open_fn        ?fn (string) bool
	mark_closing_fn     ?fn (string, &DispatchConnState) bool
	flush_pending_fn    ?fn (string)
	can_cleanup_fn      ?fn (string, &DispatchConnState) bool
	cleanup_conn_fn     ?fn (string, &DispatchConnState)
	unregister_conn_fn  ?fn (string, &DispatchConnState)
	send_to_fn          ?fn (string, string, string) bool
	join_fn             ?fn (string, string) bool
	leave_fn            ?fn (string, string) bool
	set_meta_fn         ?fn (string, string, string) bool
	clear_meta_fn       ?fn (string, string) bool
	broadcast_fn        ?fn (string, string, string, string) int
	build_frame_fn      ?fn (string, string, string, map[string]string, map[string]string, string, string, string, string, string, int, string, []string, map[string]string, PresenceSnapshot) transport.WorkerWebSocketFrame
	dispatch_event_fn   ?fn (transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse
	command_result_fn   ?fn ([]transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult
	followup_failure_fn ?fn (string, string, string, map[string]string, map[string]string, string, string, string, []transport.WorkerWebSocketDispatchCommandFailure) ?transport.WorkerWebSocketFrame
	close_owned_fn      ?fn (string, &DispatchConnState, int, string)
	close_target_fn     ?fn (string, int, string)
}

// Trace metadata shares the event sink; it never owns a second file.
pub fn (rt RuntimeContext) trace(label string, fields map[string]string) {
	mut data := fields.clone()
	data['label'] = label
	data['pid'] = '${os.getpid()}'
	rt.emit('runtime.trace', data)
}

pub fn (rt RuntimeContext) with_ingress(run ?&IngressRun) RuntimeContext {
	return RuntimeContext{ ...rt, ingress_run: run }
}

pub fn (rt RuntimeContext) dispatch_targets(room string, except_id string) []HubDispatchTarget {
	if callback := rt.dispatch_targets_fn {
		return callback(room, except_id)
	}
	if owner := rt.owner {
		return owner.dispatch_targets(room, except_id)
	}
	panic('websocket runtime operation missing: dispatch_targets')
}

pub fn (rt RuntimeContext) presence(conn_id string) PresenceSnapshot {
	if callback := rt.presence_fn {
		return callback(conn_id)
	}
	if owner := rt.owner {
		return owner.presence(conn_id)
	}
	panic('websocket runtime operation missing: presence')
}

pub fn (rt RuntimeContext) rooms(conn_id string) []string {
	if callback := rt.rooms_fn {
		return callback(conn_id)
	}
	if owner := rt.owner {
		return owner.rooms(conn_id)
	}
	panic('websocket runtime operation missing: rooms')
}

pub fn (rt RuntimeContext) metadata(conn_id string) map[string]string {
	if callback := rt.metadata_fn {
		return callback(conn_id)
	}
	if owner := rt.owner {
		return owner.metadata(conn_id)
	}
	panic('websocket runtime operation missing: metadata')
}

pub fn (rt RuntimeContext) register_conn(conn_id string, worker_socket string, method string, req_id string, trace_id string, path string, query map[string]string, headers map[string]string, remote_addr string, client &websocket.Client, lifecycle &DispatchConnState) {
	if callback := rt.register_conn_fn {
		callback(conn_id, worker_socket, method, req_id, trace_id, path, query, headers,
			remote_addr, client, lifecycle, rt.ingress_run)
		return
	}
	if owner := rt.owner {
		owner.register_conn(conn_id, worker_socket, method, req_id, trace_id, path, query, headers,
			remote_addr, client, lifecycle, rt.ingress_run)
		return
	}
	panic('websocket runtime operation missing: register_conn')
}

pub fn (rt RuntimeContext) conn_open(conn_id string) bool {
	if callback := rt.conn_open_fn {
		return callback(conn_id)
	}
	if owner := rt.owner {
		return owner.conn_open(conn_id)
	}
	panic('websocket runtime operation missing: conn_open')
}

pub fn (rt RuntimeContext) mark_closing(conn_id string, lifecycle &DispatchConnState) bool {
	if callback := rt.mark_closing_fn {
		return callback(conn_id, lifecycle)
	}
	if owner := rt.owner {
		return owner.mark_closing(conn_id, lifecycle)
	}
	panic('websocket runtime operation missing: mark_closing')
}

pub fn (rt RuntimeContext) flush_pending(conn_id string) {
	if callback := rt.flush_pending_fn {
		callback(conn_id)
		return
	}
	if owner := rt.owner {
		owner.flush_pending(conn_id)
		return
	}
	panic('websocket runtime operation missing: flush_pending')
}

pub fn (rt RuntimeContext) cleanup_conn(conn_id string, lifecycle &DispatchConnState) {
	if callback := rt.cleanup_conn_fn {
		callback(conn_id, lifecycle)
		return
	}
	if owner := rt.owner {
		owner.cleanup_conn(conn_id, lifecycle)
		return
	}
	panic('websocket runtime operation missing: cleanup_conn')
}

pub fn (rt RuntimeContext) unregister_conn(conn_id string, lifecycle &DispatchConnState) {
	if callback := rt.unregister_conn_fn {
		callback(conn_id, lifecycle)
		return
	}
	if owner := rt.owner {
		owner.unregister_conn(conn_id, lifecycle)
		return
	}
	panic('websocket runtime operation missing: unregister_conn')
}

pub fn (rt RuntimeContext) send_to(conn_id string, data string, opcode string) bool {
	if callback := rt.send_to_fn {
		return callback(conn_id, data, opcode)
	}
	if owner := rt.owner {
		return owner.send_to(conn_id, data, opcode)
	}
	panic('websocket runtime operation missing: send_to')
}

pub fn (rt RuntimeContext) join(conn_id string, room string) bool {
	if callback := rt.join_fn {
		return callback(conn_id, room)
	}
	if owner := rt.owner {
		return owner.join(conn_id, room)
	}
	panic('websocket runtime operation missing: join')
}

pub fn (rt RuntimeContext) leave(conn_id string, room string) bool {
	if callback := rt.leave_fn {
		return callback(conn_id, room)
	}
	if owner := rt.owner {
		return owner.leave(conn_id, room)
	}
	panic('websocket runtime operation missing: leave')
}

pub fn (rt RuntimeContext) set_meta(conn_id string, key string, value string) bool {
	if callback := rt.set_meta_fn {
		return callback(conn_id, key, value)
	}
	if owner := rt.owner {
		return owner.set_meta(conn_id, key, value)
	}
	panic('websocket runtime operation missing: set_meta')
}

pub fn (rt RuntimeContext) clear_meta(conn_id string, key string) bool {
	if callback := rt.clear_meta_fn {
		return callback(conn_id, key)
	}
	if owner := rt.owner {
		return owner.clear_meta(conn_id, key)
	}
	panic('websocket runtime operation missing: clear_meta')
}

pub fn (rt RuntimeContext) broadcast(room string, data string, opcode string, except_id string) int {
	if callback := rt.broadcast_fn {
		return callback(room, data, opcode, except_id)
	}
	if owner := rt.owner {
		return owner.broadcast(room, data, opcode, except_id)
	}
	panic('websocket runtime operation missing: broadcast')
}

pub fn (rt RuntimeContext) build_frame(event string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, opcode string, data string, code int, reason string, rooms []string, metadata map[string]string, presence PresenceSnapshot) transport.WorkerWebSocketFrame {
	if callback := rt.build_frame_fn {
		return callback(event, method, path, query, headers, remote_addr, req_id, trace_id,
			opcode, data, code, reason, rooms, metadata, presence)
	}
	if owner := rt.owner {
		return owner.build_frame(event, method, path, query, headers, remote_addr, req_id, trace_id,
			opcode, data, code, reason, rooms, metadata, presence)
	}
	panic('websocket runtime operation missing: build_frame')
}

pub fn (rt RuntimeContext) dispatch_event(frame transport.WorkerWebSocketFrame) !transport.WorkerWebSocketDispatchResponse {
	if callback := rt.dispatch_event_fn {
		return callback(frame)
	}
	if owner := rt.owner {
		return owner.dispatch_event(frame)
	}
	panic('websocket runtime operation missing: dispatch_event')
}

pub fn (rt RuntimeContext) command_result(commands []transport.WorkerWebSocketFrame) transport.WorkerWebSocketDispatchCommandsResult {
	if callback := rt.command_result_fn {
		return callback(commands)
	}
	if owner := rt.owner {
		return owner.command_result(commands)
	}
	panic('websocket runtime operation missing: command_result')
}

pub fn (rt RuntimeContext) followup_failure(conn_id string, method string, path string, query map[string]string, headers map[string]string, remote_addr string, req_id string, trace_id string, failures []transport.WorkerWebSocketDispatchCommandFailure) ?transport.WorkerWebSocketFrame {
	if callback := rt.followup_failure_fn {
		return callback(conn_id, method, path, query, headers, remote_addr, req_id,
			trace_id, failures)
	}
	if owner := rt.owner {
		return owner.followup_failure(conn_id, method, path, query, headers, remote_addr, req_id,
			trace_id, failures)
	}
	panic('websocket runtime operation missing: followup_failure')
}

pub fn (rt RuntimeContext) close_target(conn_id string, code int, reason string) {
	if callback := rt.close_target_fn {
		callback(conn_id, code, reason)
		return
	}
	if owner := rt.owner {
		owner.close_target(conn_id, code, reason)
		return
	}
	panic('websocket runtime operation missing: close_target')
}

pub fn (rt RuntimeContext) close_owned_target(conn_id string, lifecycle &DispatchConnState, code int, reason string) {
	if callback := rt.close_owned_fn {
		callback(conn_id, lifecycle, code, reason)
		return
	}
	if owner := rt.owner {
		owner.close_owned_target(conn_id, lifecycle, code, reason)
		return
	}
	panic('websocket runtime operation missing: close_owned_target')
}

pub fn (rt RuntimeContext) process_worker_frame(frame transport.WorkerWebSocketFrame) ?transport.WorkerWebSocketDispatchCommandFailure {
	return hub_process_worker_frame(rt, frame)
}

// ── Bridge state types ──

// BridgeState holds the worker-side WebSocket session state for proxied connections.
@[heap]
pub struct BridgeState {
pub mut:
	worker_conn            unix.StreamConn
	lifecycle              &DispatchConnState @[required]
	rt                     RuntimeContext     @[required]
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

// DispatchBridgeState holds the dispatch-side WebSocket session state.
@[heap]
pub struct DispatchBridgeState {
pub mut:
	finalize_mu   sync.Mutex
	lifecycle     &DispatchConnState @[required]
	rt            RuntimeContext     @[required]
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

// ── HubRuntime static operations ──
// These operate on ws.HubState directly, with zero App coupling.

pub fn hub_send_to(mut hub HubState, conn_id string, data string, opcode string) bool {
	return hub_send_expected(mut hub, conn_id, none, data, opcode)
}

pub fn hub_send_owned_to(mut hub HubState, conn_id string, lifecycle &DispatchConnState, data string, opcode string) bool {
	return hub_send_expected(mut hub, conn_id, lifecycle, data, opcode)
}

fn hub_send_expected(mut hub HubState, conn_id string, expected ?&DispatchConnState, data string, opcode string) bool {
	if conn_id == '' {
		return false
	}
	mut client_handle := ?&websocket.Client(none)
	mut queued := false
	hub.mu.@lock()
	if hub_conn := hub.conns[conn_id] {
		if lifecycle := expected {
			if voidptr(hub_conn.lifecycle) != voidptr(lifecycle) {
				hub.mu.unlock()
				return false
			}
		}
		if !hub_conn.lifecycle.can_send() {
			if hub_conn.lifecycle.can_queue() {
				mut pending := hub.pending[conn_id] or { []HubPendingMessage{} }
				pending << HubPendingMessage{
					registration: hub_conn.lifecycle
					data:         data
					opcode:       if opcode == '' { 'text' } else { opcode }
				}
				hub.pending[conn_id] = pending
				queued = true
				hub.mu.unlock()
				return true
			}
			hub.mu.unlock()
			return false
		}
		client_handle = hub_conn.client
	} else {
		if expected != none {
			hub.mu.unlock()
			return false
		}
		mut pending := hub.pending[conn_id] or { []HubPendingMessage{} }
		pending << HubPendingMessage{
			data:   data
			opcode: if opcode == '' { 'text' } else { opcode }
		}
		hub.pending[conn_id] = pending
		queued = true
	}
	hub.mu.unlock()
	client := client_handle or { return queued }
	// The owned send has already admitted against this registration and captured
	// its native handle. Do not resolve the ID again in send_client: a later
	// opening registration must never receive this accepted task's queued data.
	return hub.send_client(if expected != none { '' } else { conn_id }, client, data, opcode)
}

pub fn hub_broadcast(mut hub HubState, room string, data string, opcode string, except_id string) int {
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
				if client := hub_conn.client {
					targets << HubSendTarget{ id: conn_id, client: client }
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

pub fn hub_dispatch_targets(mut hub HubState, room string, except_id string) []HubDispatchTarget {
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
					dispatch:    hub_conn.dispatch
					lifecycle:   hub_conn.lifecycle
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

pub fn hub_broadcast_dispatch(rt RuntimeContext, room string, data string, except_id string) int {
	if room == '' {
		return 0
	}
	targets := rt.dispatch_targets(room, except_id)
	mut delivered := 0
	for target in targets {
		if !rt.conn_open(target.id) || !rt.can_cleanup(target.id, target.lifecycle) { continue }
		presence := rt.presence(target.id)
		base_frame := rt.build_frame('info', target.method, target.path, target.query,
			target.headers, target.remote_addr, target.request_id, target.trace_id, 'text', data,
			0, '', rt.rooms(target.id), rt.metadata(target.id), presence)
		info_frame := transport.WorkerWebSocketFrame{
			...base_frame
			room: room
		}
		resp := if owner := target.dispatch {
			owner.dispatch_event(info_frame) or { continue }
		} else {
			rt.dispatch_event(info_frame) or { continue }
		}
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
			rt.close_owned_target(target.id, target.lifecycle, code, close_frame.reason)
			continue
		}
		if result.failures.len > 0 {
			if close_frame := rt.followup_failure(target.id, target.method, target.path,
				target.query, target.headers, target.remote_addr, target.request_id,
				target.trace_id, result.failures)
			{
				code := if close_frame.code > 0 { close_frame.code } else { 1000 }
				rt.close_owned_target(target.id, target.lifecycle, code, close_frame.reason)
			}
		}
		delivered++
	}
	return delivered
}

pub fn hub_close_target(mut hub HubState, conn_id string, code int, reason string) {
	hub_close_expected(mut hub, conn_id, none, code, reason)
}

pub fn hub_close_owned_target(mut hub HubState, conn_id string, lifecycle &DispatchConnState, code int, reason string) {
	hub_close_expected(mut hub, conn_id, lifecycle, code, reason)
}

fn hub_close_expected(mut hub HubState, conn_id string, expected ?&DispatchConnState, code int, reason string) {
	if conn_id == '' { return }
	mut serving := ?&IngressRun(none)
	mut outbound := ?&connection_runtime.Session(none)
	mut client_handle := ?&websocket.Client(none)
	hub.mu.@lock()
	if hub_conn := hub.conns[conn_id] {
		if lifecycle := expected {
			if voidptr(lifecycle) != voidptr(hub_conn.lifecycle) {
				hub.mu.unlock()
				return
			}
		}
		if !hub_conn.lifecycle.claim_socket_close(code, reason) {
			hub.mu.unlock()
			return
		}
		serving = hub_conn.serving
		outbound = hub_conn.outbound
		client_handle = hub_conn.close_writer
	} else if expected != none {
		// No matching registration remains to own the pending queue.
		hub.mu.unlock()
		return
	}
	hub.pending.delete(conn_id)
	hub.mu.unlock()
	client := client_handle or { return }
	if mut source := serving {
		mut task := source.child() or { return }
		spawn hub_close_client_owned(mut hub, mut task, client, code, reason)
		return
	}
	if mut session := outbound {
		mut task := hub.ingress.reserve() or { return }
		fd := session.duplicate_interrupt() or {
			task.finish()
			return
		}
		attached := task.attach(fd)
		net.close(fd) or {}
		if !attached {
			task.finish()
			return
		}
		spawn hub_close_client_owned(mut hub, mut task, client, code, reason)
	}
}

fn hub_close_client_owned(mut hub HubState, mut task IngressRun, client &websocket.Client, code int, reason string) {
	defer {
		task.request_stop()
		task.finish()
	}
	hub.send_mu.@lock()
	defer { hub.send_mu.unlock() }
	task.write_client_close(client, code, reason)
}

pub fn hub_process_worker_frame(rt RuntimeContext, frame transport.WorkerWebSocketFrame) ?transport.WorkerWebSocketDispatchCommandFailure {
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
			hub_broadcast_dispatch(rt, frame.room, frame.data, frame.except_id)
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

pub fn hub_snapshot(mut hub HubState, details bool, limit int, offset int, room_filter string, conn_filter string) RuntimeSnapshot {
	hub.mu.@lock()
	defer {
		hub.mu.unlock()
	}
	mut connections := []ConnSnapshot{}
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
		connections << ConnSnapshot{
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
	mut ordered_connections := []ConnSnapshot{}
	mut connection_keys := []string{}
	mut connection_by_key := map[string]ConnSnapshot{}
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
	mut rooms := []RoomSnapshot{}
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
		rooms << RoomSnapshot{
			name:         room_name
			member_count: members.len
			members:      members
		}
	}
	mut ordered_rooms := []RoomSnapshot{}
	mut room_keys := []string{}
	mut room_by_key := map[string]RoomSnapshot{}
	for room in rooms {
		room_keys << room.name
		room_by_key[room.name] = room
	}
	room_keys.sort()
	for key in room_keys {
		ordered_rooms << room_by_key[key]
	}
	if !details {
		return RuntimeSnapshot{
			active_connections:   hub.conns.len
			active_rooms:         hub.room_members.len
			returned_connections: 0
			returned_rooms:       0
			details:              false
			limit:                limit
			offset:               offset
			room_filter:          room_filter
			conn_id:              conn_filter
			connections:          []ConnSnapshot{}
			rooms:                []RoomSnapshot{}
		}
	}
	mut sliced_connections := []ConnSnapshot{}
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
	mut sliced_rooms := []RoomSnapshot{}
	if offset < ordered_rooms.len {
		end := if offset + limit < ordered_rooms.len { offset + limit } else { ordered_rooms.len }
		for i in offset .. end {
			sliced_rooms << ordered_rooms[i]
		}
	}
	return RuntimeSnapshot{
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

pub fn (rt RuntimeContext) emit(kind string, fields map[string]string) {
	if callback := rt.emit_fn {
		callback(kind, fields)
		return
	}
	if owner := rt.owner {
		owner.emit(kind, fields)
		return
	}
	panic('websocket runtime operation missing: emit')
}

pub fn (rt RuntimeContext) can_cleanup(id string, lifecycle &ws.DispatchConnState) bool {
	if callback := rt.can_cleanup_fn { return callback(id, lifecycle) }
	if owner := rt.owner { return owner.can_cleanup(id, lifecycle) }
	panic('websocket runtime operation missing: can_cleanup')
}
