module ws

import encoding.base64
import net.websocket
import connection_runtime

// ── Payload helpers ──

pub fn (msg HubPendingMessage) payload_bytes() ?([]u8, websocket.OPCode) {
	return match msg.opcode {
		'', 'text' {
			msg.data.bytes(), websocket.OPCode.text_frame
		}
		'binary' {
			base64.decode(msg.data), websocket.OPCode.binary_frame
		}
		else {
			none
		}
	}
}

// ── HubState methods ──

pub fn (mut s HubState) cleanup_conn(conn_id string) {
	if conn_id == '' {
		return
	}
	s.mu.@lock()
	s.cleanup_locked(conn_id)
	s.mu.unlock()
}

fn (mut s HubState) cleanup_locked(conn_id string) {
	s.conns.delete(conn_id)
	if rooms := s.conn_rooms[conn_id] {
		for room, _ in rooms.clone() {
			mut members := (s.room_members[room] or {
				map[string]bool{}
			}).clone()
			members.delete(conn_id)
			if members.len == 0 {
				s.room_members.delete(room)
			} else {
				s.room_members[room] = members.clone()
			}
		}
	}
	s.conn_rooms.delete(conn_id)
	s.conn_meta.delete(conn_id)
	s.pending.delete(conn_id)
}

// A finalizer owns a registered lifecycle identity. With no registration, queued
// messages may already belong to a future open under the same routing ID.
pub fn (mut s HubState) cleanup_owned(conn_id string, lifecycle &DispatchConnState) {
	if conn_id == '' { return }
	s.mu.@lock()
	defer { s.mu.unlock() }
	current := s.conns[conn_id] or { return }
	if voidptr(current.lifecycle) != voidptr(lifecycle) { return }
	s.cleanup_locked(conn_id)
}

pub fn (mut s HubState) mark_owned_closing(conn_id string, lifecycle &DispatchConnState) bool {
	if conn_id == '' { return false }
	s.mu.@lock()
	defer { s.mu.unlock() }
	if current := s.conns[conn_id] {
		if voidptr(current.lifecycle) != voidptr(lifecycle) { return false }
		s.pending.delete(conn_id)
		return lifecycle.mark_closing()
	}
	return false
}

pub fn (mut s HubState) unregister_owned(conn_id string, lifecycle &DispatchConnState) {
	lifecycle.mark_closing()
	if lifecycle.begin_cleanup() { s.cleanup_owned(conn_id, lifecycle) }
}

pub fn (mut s HubState) bind_outbound(conn_id string, lifecycle &DispatchConnState, session &connection_runtime.Session) bool {
	s.mu.@lock()
	defer { s.mu.unlock() }
	mut current := s.conns[conn_id] or { return false }
	if voidptr(current.lifecycle) != voidptr(lifecycle) || current.outbound != none { return false }
	// Lock order is hub -> lifecycle -> session. No callback or I/O runs here.
	// Keep lifecycle admission through publication so close cannot overtake it.
	lifecycle.mu.@lock()
	defer { lifecycle.mu.unlock() }
	if lifecycle.phase !in [.opening, .open] || lifecycle.close_notified || lifecycle.worker_initiated_close || lifecycle.socket_close_requested {
		return false
	}
	client := current.client or { return false }
	mut owned := unsafe { session }
	if !owned.claim_attachment(client) { return false }
	current.outbound = session
	current.serving = none
	s.conns[conn_id] = current
	return true
}

// Transport identity belongs to this hub, independently of request/trace IDs.
// Allocate before publishing a connection, under the same mutex as the table.
pub fn (mut s HubState) next_connection_id() string {
	s.mu.@lock()
	defer { s.mu.unlock() }
	s.connection_sequence++
	return 'ws-connection:${s.connection_sequence}'
}

pub fn (mut s HubState) register_conn(conn_id string, worker_socket string, method string, req_id string, trace_id string, path string, query map[string]string, headers map[string]string, remote_addr string, client &websocket.Client, lifecycle &DispatchConnState) {
	s.register_owned_conn(conn_id, worker_socket, method, req_id, trace_id, path, query, headers, remote_addr, client, lifecycle, none)
}

pub fn (mut s HubState) register_owned_conn(conn_id string, worker_socket string, method string, req_id string, trace_id string, path string, query map[string]string, headers map[string]string, remote_addr string, client &websocket.Client, lifecycle &DispatchConnState, serving ?&IngressRun) {
	s.register_owned_dispatch_conn(conn_id, worker_socket, method, req_id, trace_id, path, query, headers, remote_addr, client, lifecycle, serving, none)
}

pub fn (mut s HubState) register_owned_dispatch_conn(conn_id string, worker_socket string, method string, req_id string, trace_id string, path string, query map[string]string, headers map[string]string, remote_addr string, client &websocket.Client, lifecycle &DispatchConnState, serving ?&IngressRun, dispatch ?EventDispatch) {
	if conn_id == '' || isnil(client) {
		return
	}
	// Registration runs before listen starts. Snapshot only once here, so close
	// tasks never copy the live reader's mutable buffers/fragments concurrently.
	writer := &websocket.Client{ ...client }

	s.mu.@lock()
	s.conns[conn_id] = HubConn{
		id:            conn_id
		worker_socket: worker_socket
		method:        method
		request_id:    req_id
		trace_id:      trace_id
		path:          path
		query:         query.clone()
		headers:       headers.clone()
		remote_addr:   remote_addr
		client:        unsafe { client }
		close_writer:  writer
		dispatch:      dispatch
		serving:       serving
		lifecycle:     unsafe { lifecycle }
	}
	s.mu.unlock()
}

pub fn (mut s HubState) conn_open(conn_id string) bool {
	if conn_id == '' {
		return false
	}
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	if hub_conn := s.conns[conn_id] {
		return hub_conn.lifecycle.can_queue()
	}
	return false
}

pub fn (mut s HubState) mark_closing(conn_id string) bool {
	if conn_id == '' {
		return false
	}
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	if hub_conn := s.conns[conn_id] {
		s.pending.delete(conn_id)
		return hub_conn.lifecycle.mark_closing()
	}
	s.pending.delete(conn_id)
	return false
}

struct PendingSendBatch {
	client   &websocket.Client @[required]
	messages []HubPendingMessage
}

fn (mut s HubState) take_pending_batch(conn_id string) ?PendingSendBatch {
	s.mu.@lock()
	defer { s.mu.unlock() }
	hub_conn := s.conns[conn_id] or { return none }
	if hub_conn.lifecycle.phase() != .open { return none }
	client := hub_conn.client or { return none }
	pending := s.pending[conn_id] or { return none }
	s.pending.delete(conn_id)
	// An absent-registration queue is explicitly for the first future open.
	// Messages accepted by a known registration stay with that lifecycle.
	mut messages := []HubPendingMessage{cap: pending.len}
	for item in pending {
		if owner := item.registration {
			if voidptr(owner) != voidptr(hub_conn.lifecycle) { continue }
		}
		messages << item
	}
	return PendingSendBatch{ client: client, messages: messages }
}

pub fn (mut s HubState) flush_pending(conn_id string) {
	batch := s.take_pending_batch(conn_id) or { return }
	for item in batch.messages {
		// Claiming the batch captured its native writer. A replacement must not
		// redirect these accepted messages into a different opening queue.
		s.send_client('', batch.client, item.data, item.opcode)
	}
}

pub fn (mut s HubState) rooms_snapshot(conn_id string) []string {
	if conn_id == '' {
		return []string{}
	}
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	mut rooms := []string{}
	if joined := s.conn_rooms[conn_id] {
		for room, present in joined {
			if present {
				rooms << room
			}
		}
	}
	rooms.sort()
	return rooms
}

pub fn (mut s HubState) meta_snapshot(conn_id string) map[string]string {
	if conn_id == '' {
		return map[string]string{}
	}
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	return (s.conn_meta[conn_id] or {
		map[string]string{}
	}).clone()
}

pub fn (mut s HubState) set_meta(conn_id string, key string, value string) bool {
	if conn_id == '' || key == '' {
		return false
	}
	s.mu.@lock()
	mut meta := (s.conn_meta[conn_id] or {
		map[string]string{}
	}).clone()
	meta[key] = value
	s.conn_meta[conn_id] = meta.clone()
	s.mu.unlock()
	return true
}

pub fn (mut s HubState) clear_meta(conn_id string, key string) bool {
	if conn_id == '' || key == '' {
		return false
	}
	s.mu.@lock()
	if mut meta := s.conn_meta[conn_id] {
		meta.delete(key)
		if meta.len == 0 {
			s.conn_meta.delete(conn_id)
		} else {
			s.conn_meta[conn_id] = meta.clone()
		}
	}
	s.mu.unlock()
	return true
}

pub fn (mut s HubState) presence_snapshot(conn_id string) (map[string][]string, map[string]map[string]string, map[string]int, map[string][]string) {
	if conn_id == '' {
		return map[string][]string{}, map[string]map[string]string{}, map[string]int{}, map[string][]string{}
	}
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	mut room_members := map[string][]string{}
	mut member_metadata := map[string]map[string]string{}
	mut room_counts := map[string]int{}
	mut presence_users := map[string][]string{}
	if rooms := s.conn_rooms[conn_id] {
		for room, present in rooms {
			if !present {
				continue
			}
			mut ids := []string{}
			mut users := []string{}
			if members := s.room_members[room] {
				for member_id, in_room in members {
					if !in_room {
						continue
					}
					ids << member_id
					if meta := s.conn_meta[member_id] {
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

pub fn (mut s HubState) unregister_conn(conn_id string) {
	if conn_id == '' {
		return
	}
	s.mu.@lock()
	if hub_conn := s.conns[conn_id] {
		if !hub_conn.lifecycle.begin_cleanup() {
			s.mu.unlock()
			return
		}
	}
	s.mu.unlock()
	s.cleanup_conn(conn_id)
}

pub fn (mut s HubState) join(conn_id string, room string) bool {
	if conn_id == '' || room == '' {
		return false
	}
	s.mu.@lock()
	mut members := (s.room_members[room] or {
		map[string]bool{}
	}).clone()
	members[conn_id] = true
	s.room_members[room] = members.clone()
	mut rooms := (s.conn_rooms[conn_id] or {
		map[string]bool{}
	}).clone()
	rooms[room] = true
	s.conn_rooms[conn_id] = rooms.clone()
	s.mu.unlock()
	return true
}

pub fn (mut s HubState) leave(conn_id string, room string) bool {
	if conn_id == '' || room == '' {
		return false
	}
	s.mu.@lock()
	if mut members := s.room_members[room] {
		members.delete(conn_id)
		if members.len == 0 {
			s.room_members.delete(room)
		} else {
			s.room_members[room] = members.clone()
		}
	}
	if mut rooms := s.conn_rooms[conn_id] {
		rooms.delete(room)
		if rooms.len == 0 {
			s.conn_rooms.delete(conn_id)
		} else {
			s.conn_rooms[conn_id] = rooms.clone()
		}
	}
	s.mu.unlock()
	return true
}

pub fn (mut s HubState) send_client(conn_id string, client &websocket.Client, data string, opcode string) bool {
	if isnil(client) {
		return false
	}
	if conn_id != '' {
		s.mu.@lock()
		if hub_conn := s.conns[conn_id] {
			current := hub_conn.client or {
				s.mu.unlock()
				return false
			}
			if voidptr(current) != voidptr(client) {
				s.mu.unlock()
				return false
			}
			if !hub_conn.lifecycle.can_send() {
				if hub_conn.lifecycle.can_queue() {
					mut pending := s.pending[conn_id] or { []HubPendingMessage{} }
					pending << HubPendingMessage{
						registration: hub_conn.lifecycle
						data:         data
						opcode:       if opcode == '' { 'text' } else { opcode }
					}
					s.pending[conn_id] = pending
					s.mu.unlock()
					return true
				}
				s.mu.unlock()
				return false
			}
		}
		s.mu.unlock()
	}
	s.send_mu.@lock()
	defer {
		s.send_mu.unlock()
	}
	mut c := unsafe { client }
	payload, code := HubPendingMessage{
		data:   data
		opcode: opcode
	}.payload_bytes() or { return false }
	if code == .text_frame {
		c.write_string(data) or { return false }
		return true
	}
	c.write(payload, code) or { return false }
	return true
}

// An unregistered accepted open still needs cleanup; a replacement does not.
pub fn (mut s HubState) can_cleanup_owned(id string, lifecycle &DispatchConnState) bool {
	s.mu.@lock()
	defer { s.mu.unlock() }
	if current := s.conns[id] { return voidptr(current.lifecycle) == voidptr(lifecycle) }
	return true
}
