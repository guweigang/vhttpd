module main

import net.websocket
import net.unix
import sync
import time

@[heap]
struct WebSocketBridgeState {
mut:
	app                    &App = unsafe { nil }
	worker_conn            unix.StreamConn
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
	app         &App = unsafe { nil }
	conn_id     string
	method      string
	path        string
	query       map[string]string
	headers     map[string]string
	remote_addr string
	request_id  string
	trace_id    string
	start_ms    i64
}

struct HubConn {
	id            string
	worker_socket string
	method        string
	request_id    string
	trace_id      string
	path          string
	query         map[string]string
	headers       map[string]string
	remote_addr   string
mut:
	client &websocket.Client = unsafe { nil }
}

struct HubPendingMessage {
	data   string
	opcode string
}

struct HubSendTarget {
	id string
mut:
	client &websocket.Client = unsafe { nil }
}

struct HubDispatchTarget {
	id         string
	method     string
	request_id string
	trace_id   string
	path       string
	query      map[string]string
	headers    map[string]string
	remote_addr string
}

struct AdminWebSocketConnSnapshot {
	id         string
	request_id string
	trace_id   string
	path       string
	rooms      []string
	metadata   map[string]string
}

struct AdminWebSocketRoomSnapshot {
	name         string
	member_count int
	members      []string
}

struct AdminWebSocketRuntimeSnapshot {
	active_connections   int
	active_rooms         int
	returned_connections int
	returned_rooms       int
	details              bool
	limit                int
	offset               int
	room_filter          string
	conn_id              string
	connections          []AdminWebSocketConnSnapshot
	rooms                []AdminWebSocketRoomSnapshot
}

fn (mut app App) ws_hub_register_conn(conn_id string, worker_socket string, method string, req_id string, trace_id string, path string, query map[string]string, headers map[string]string, remote_addr string, client &websocket.Client) {
	if conn_id == '' || isnil(client) {
		return
	}
	app.ws_hub_mu.@lock()
	app.ws_hub_conns[conn_id] = HubConn{
		id: conn_id
		worker_socket: worker_socket
		method: method
		request_id: req_id
		trace_id: trace_id
		path: path
		query: query.clone()
		headers: headers.clone()
		remote_addr: remote_addr
		client: unsafe { client }
	}
	app.ws_hub_mu.unlock()
}

fn (mut app App) ws_hub_flush_pending(conn_id string) {
	if conn_id == '' {
		return
	}
	mut client := &websocket.Client(unsafe { nil })
	mut pending := []HubPendingMessage{}
	app.ws_hub_mu.@lock()
	if hub_conn := app.ws_hub_conns[conn_id] {
		client = hub_conn.client
	}
	if queued := app.ws_hub_pending[conn_id] {
		pending = queued.clone()
		app.ws_hub_pending.delete(conn_id)
	}
	app.ws_hub_mu.unlock()
	if isnil(client) {
		return
	}
	for item in pending {
		app.ws_hub_send_client(conn_id, client, item.data, item.opcode)
	}
}

fn delayed_ws_hub_flush(mut app App, conn_id string) {
	time.sleep(20 * time.millisecond)
	app.ws_hub_flush_pending(conn_id)
}

fn (mut app App) ws_hub_rooms_snapshot(conn_id string) []string {
	if conn_id == '' {
		return []string{}
	}
	app.ws_hub_mu.@lock()
	defer {
		app.ws_hub_mu.unlock()
	}
	mut rooms := []string{}
	if joined := app.ws_hub_conn_rooms[conn_id] {
		for room, present in joined {
			if present {
				rooms << room
			}
		}
	}
	rooms.sort()
	return rooms
}

fn (mut app App) ws_hub_meta_snapshot(conn_id string) map[string]string {
	if conn_id == '' {
		return map[string]string{}
	}
	app.ws_hub_mu.@lock()
	defer {
		app.ws_hub_mu.unlock()
	}
	return (app.ws_hub_conn_meta[conn_id] or { map[string]string{} }).clone()
}

fn (mut app App) ws_hub_set_meta(conn_id string, key string, value string) bool {
	if conn_id == '' || key == '' {
		return false
	}
	app.ws_hub_mu.@lock()
	mut meta := (app.ws_hub_conn_meta[conn_id] or { map[string]string{} }).clone()
	meta[key] = value
	app.ws_hub_conn_meta[conn_id] = meta.clone()
	app.ws_hub_mu.unlock()
	return true
}

fn (mut app App) ws_hub_clear_meta(conn_id string, key string) bool {
	if conn_id == '' || key == '' {
		return false
	}
	app.ws_hub_mu.@lock()
	if mut meta := app.ws_hub_conn_meta[conn_id] {
		meta.delete(key)
		if meta.len == 0 {
			app.ws_hub_conn_meta.delete(conn_id)
		} else {
			app.ws_hub_conn_meta[conn_id] = meta.clone()
		}
	}
	app.ws_hub_mu.unlock()
	return true
}

fn (mut app App) ws_hub_presence_snapshot(conn_id string) (map[string][]string, map[string]map[string]string, map[string]int, map[string][]string) {
	if conn_id == '' {
		return map[string][]string{}, map[string]map[string]string{}, map[string]int{}, map[string][]string{}
	}
	app.ws_hub_mu.@lock()
	defer {
		app.ws_hub_mu.unlock()
	}
	mut room_members := map[string][]string{}
	mut member_metadata := map[string]map[string]string{}
	mut room_counts := map[string]int{}
	mut presence_users := map[string][]string{}
	if rooms := app.ws_hub_conn_rooms[conn_id] {
		for room, present in rooms {
			if !present {
				continue
			}
			mut ids := []string{}
			mut users := []string{}
			if members := app.ws_hub_room_members[room] {
				for member_id, in_room in members {
					if !in_room {
						continue
					}
					ids << member_id
					if meta := app.ws_hub_conn_meta[member_id] {
						member_metadata[member_id] = meta.clone()
						user := meta['user'] or { member_id }
						users << user
					} else {
						member_metadata[member_id] = map[string]string{}
						users << member_id
					}
				}
			}
			ids.sort()
			users.sort()
			room_members[room] = ids
			room_counts[room] = ids.len
			presence_users[room] = users
		}
	}
	return room_members, member_metadata, room_counts, presence_users
}

fn (mut app App) ws_hub_unregister_conn(conn_id string) {
	if conn_id == '' {
		return
	}
	app.ws_hub_mu.@lock()
	app.ws_hub_conns.delete(conn_id)
	if rooms := app.ws_hub_conn_rooms[conn_id] {
		for room, _ in rooms.clone() {
			mut members := (app.ws_hub_room_members[room] or { map[string]bool{} }).clone()
			members.delete(conn_id)
			if members.len == 0 {
				app.ws_hub_room_members.delete(room)
			} else {
				app.ws_hub_room_members[room] = members.clone()
			}
		}
	}
	app.ws_hub_conn_rooms.delete(conn_id)
	app.ws_hub_conn_meta.delete(conn_id)
	app.ws_hub_pending.delete(conn_id)
	app.ws_hub_mu.unlock()
}

fn (mut app App) ws_hub_join(conn_id string, room string) bool {
	if conn_id == '' || room == '' {
		return false
	}
	app.ws_hub_mu.@lock()
	mut members := (app.ws_hub_room_members[room] or { map[string]bool{} }).clone()
	members[conn_id] = true
	app.ws_hub_room_members[room] = members.clone()
	mut rooms := (app.ws_hub_conn_rooms[conn_id] or { map[string]bool{} }).clone()
	rooms[room] = true
	app.ws_hub_conn_rooms[conn_id] = rooms.clone()
	app.ws_hub_mu.unlock()
	return true
}

fn (mut app App) ws_hub_leave(conn_id string, room string) bool {
	if conn_id == '' || room == '' {
		return false
	}
	app.ws_hub_mu.@lock()
	if mut members := app.ws_hub_room_members[room] {
		members.delete(conn_id)
		if members.len == 0 {
			app.ws_hub_room_members.delete(room)
		} else {
			app.ws_hub_room_members[room] = members.clone()
		}
	}
	if mut rooms := app.ws_hub_conn_rooms[conn_id] {
		rooms.delete(room)
		if rooms.len == 0 {
			app.ws_hub_conn_rooms.delete(conn_id)
		} else {
			app.ws_hub_conn_rooms[conn_id] = rooms.clone()
		}
	}
	app.ws_hub_mu.unlock()
	return true
}

fn (mut app App) ws_hub_send_client(conn_id string, client &websocket.Client, data string, opcode string) bool {
	if isnil(client) {
		return false
	}
	app.ws_hub_send_mu.@lock()
	defer {
		app.ws_hub_send_mu.unlock()
	}
	mut c := unsafe { client }
	if opcode != '' && opcode != 'text' {
		return false
	}
	c.write_string(data) or {
		app.ws_hub_unregister_conn(conn_id)
		return false
	}
	return true
}

fn (mut app App) ws_hub_send_to(conn_id string, data string, opcode string) bool {
	if conn_id == '' {
		return false
	}
	mut client := &websocket.Client(unsafe { nil })
	app.ws_hub_mu.@lock()
	if hub_conn := app.ws_hub_conns[conn_id] {
		client = hub_conn.client
	} else {
		mut pending := app.ws_hub_pending[conn_id] or { []HubPendingMessage{} }
		pending << HubPendingMessage{
			data: data
			opcode: if opcode == '' { 'text' } else { opcode }
		}
		app.ws_hub_pending[conn_id] = pending
	}
	app.ws_hub_mu.unlock()
	if isnil(client) {
		return false
	}
	return app.ws_hub_send_client(conn_id, client, data, opcode)
}

fn (mut app App) ws_hub_broadcast(room string, data string, opcode string, except_id string) int {
	if room == '' {
		return 0
	}
	mut targets := []HubSendTarget{}
	app.ws_hub_mu.@lock()
	if members := app.ws_hub_room_members[room] {
		for conn_id, _ in members {
			if except_id != '' && conn_id == except_id {
				continue
			}
			if hub_conn := app.ws_hub_conns[conn_id] {
				targets << HubSendTarget{
					id: conn_id
					client: unsafe { hub_conn.client }
				}
			} else {
				mut pending := app.ws_hub_pending[conn_id] or { []HubPendingMessage{} }
				pending << HubPendingMessage{
					data: data
					opcode: if opcode == '' { 'text' } else { opcode }
				}
				app.ws_hub_pending[conn_id] = pending
			}
		}
	}
	app.ws_hub_mu.unlock()
	mut delivered := 0
	for target in targets {
		if app.ws_hub_send_client(target.id, target.client, data, opcode) {
			delivered++
		}
	}
	return delivered
}

fn (mut app App) ws_hub_broadcast_dispatch(room string, data string, except_id string) int {
	if room == '' {
		return 0
	}
	mut targets := []HubDispatchTarget{}
	app.ws_hub_mu.@lock()
	if members := app.ws_hub_room_members[room] {
		for conn_id, _ in members {
			if except_id != '' && conn_id == except_id {
				continue
			}
			if hub_conn := app.ws_hub_conns[conn_id] {
				targets << HubDispatchTarget{
					id: conn_id
					method: if hub_conn.method == '' { 'GET' } else { hub_conn.method }
					request_id: hub_conn.request_id
					trace_id: hub_conn.trace_id
					path: hub_conn.path
					query: hub_conn.query.clone()
					headers: hub_conn.headers.clone()
					remote_addr: hub_conn.remote_addr
				}
			}
		}
	}
	app.ws_hub_mu.unlock()
	mut delivered := 0
	for target in targets {
		room_members, member_metadata, room_counts, presence_users := app.ws_hub_presence_snapshot(target.id)
		base_frame := app.kernel_websocket_dispatch_frame(
			'info',
			target.method,
			target.path,
			target.query,
			target.headers,
			target.remote_addr,
			target.request_id,
			target.trace_id,
			'text',
			data,
			0,
			'',
			app.ws_hub_rooms_snapshot(target.id),
			app.ws_hub_meta_snapshot(target.id),
			room_members,
			member_metadata,
			room_counts,
			presence_users,
		)
		info_frame := WorkerWebSocketFrame{
			...base_frame
			room: room
		}
		resp := app.kernel_dispatch_websocket_event(info_frame) or {
			continue
		}
		mut forwarded_commands := []WorkerWebSocketFrame{cap: resp.commands.len}
		for cmd in resp.commands {
			if cmd.event == 'send' || cmd.event == 'send_to' || cmd.event == 'join' || cmd.event == 'leave'
				|| cmd.event == 'set_meta' || cmd.event == 'clear_meta' || cmd.event == 'broadcast'
				|| cmd.event == 'broadcast_dispatch' || cmd.event == 'close' {
				forwarded_commands << WorkerWebSocketFrame{
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
		if close_frame := app.execute_websocket_dispatch_commands(forwarded_commands) {
			code := if close_frame.code > 0 { close_frame.code } else { 1000 }
			app.ws_hub_close_target(target.id, code, close_frame.reason)
		}
		delivered++
	}
	return delivered
}

fn (mut app App) ws_hub_close_target(conn_id string, code int, reason string) {
	if conn_id == '' {
		return
	}
	mut client := &websocket.Client(unsafe { nil })
	app.ws_hub_mu.@lock()
	if hub_conn := app.ws_hub_conns[conn_id] {
		client = hub_conn.client
	}
	app.ws_hub_mu.unlock()
	if isnil(client) {
		return
	}
	mut c := unsafe { client }
	c.close(code, reason) or {}
}

fn (mut app App) process_worker_websocket_hub_frame(frame WorkerWebSocketFrame) bool {
	match frame.event {
		'send' {
			target := if frame.target_id != '' { frame.target_id } else { frame.id }
			app.ws_hub_send_to(target, frame.data, frame.opcode)
			return true
		}
		'send_to' {
			target := if frame.target_id != '' { frame.target_id } else { frame.id }
			app.ws_hub_send_to(target, frame.data, frame.opcode)
			return true
		}
		'join' {
			app.ws_hub_join(frame.id, frame.room)
			return true
		}
		'leave' {
			app.ws_hub_leave(frame.id, frame.room)
			return true
		}
		'set_meta' {
			app.ws_hub_set_meta(frame.id, frame.key, frame.value)
			return true
		}
		'clear_meta' {
			app.ws_hub_clear_meta(frame.id, frame.key)
			return true
		}
		'broadcast' {
			app.ws_hub_broadcast(frame.room, frame.data, frame.opcode, frame.except_id)
			return true
		}
		'broadcast_dispatch' {
			app.ws_hub_broadcast_dispatch(frame.room, frame.data, frame.except_id)
			return true
		}
		else {}
	}
	return false
}

fn (mut app App) admin_websockets_snapshot(details bool, limit int, offset int, room_filter string, conn_filter string) AdminWebSocketRuntimeSnapshot {
	app.ws_hub_mu.@lock()
	defer {
		app.ws_hub_mu.unlock()
	}
	mut connections := []AdminWebSocketConnSnapshot{}
	for socket_conn_id, conn in app.ws_hub_conns {
		mut joined_rooms := []string{}
		if joined := app.ws_hub_conn_rooms[socket_conn_id] {
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
			id: socket_conn_id
			request_id: conn.request_id
			trace_id: conn.trace_id
			path: conn.path
			rooms: joined_rooms
			metadata: (app.ws_hub_conn_meta[socket_conn_id] or { map[string]string{} }).clone()
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
	for room_name, members_map in app.ws_hub_room_members {
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
			name: room_name
			member_count: members.len
			members: members
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
			active_connections: app.ws_hub_conns.len
			active_rooms: app.ws_hub_room_members.len
			returned_connections: 0
			returned_rooms: 0
			details: false
			limit: limit
			offset: offset
			room_filter: room_filter
			conn_id: conn_filter
			connections: []AdminWebSocketConnSnapshot{}
			rooms: []AdminWebSocketRoomSnapshot{}
		}
	}
	mut sliced_connections := []AdminWebSocketConnSnapshot{}
	if offset < ordered_connections.len {
		end := if offset + limit < ordered_connections.len { offset + limit } else { ordered_connections.len }
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
		active_connections: app.ws_hub_conns.len
		active_rooms: app.ws_hub_room_members.len
		returned_connections: sliced_connections.len
		returned_rooms: sliced_rooms.len
		details: true
		limit: limit
		offset: offset
		room_filter: room_filter
		conn_id: conn_filter
		connections: sliced_connections
		rooms: sliced_rooms
	}
}
