module ws

import encoding.base64
import net.websocket

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
	s.mu.unlock()
}

pub fn (mut s HubState) register_conn(conn_id string, worker_socket string, method string, req_id string, trace_id string, path string, query map[string]string, headers map[string]string, remote_addr string, client &websocket.Client, lifecycle &DispatchConnState) {
	if conn_id == '' || isnil(client) {
		return
	}
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
		lifecycle:     unsafe { lifecycle }
	}
	s.mu.unlock()
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

pub fn (mut s HubState) flush_pending(conn_id string) {
	if conn_id == '' {
		return
	}
	mut client := &websocket.Client(unsafe { nil })
	mut pending := []HubPendingMessage{}
	s.mu.@lock()
	if hub_conn := s.conns[conn_id] {
		phase := hub_conn.lifecycle.phase()
		if phase == .closing || phase == .closed {
			s.mu.unlock()
			return
		}
		if phase != .open {
			s.mu.unlock()
			return
		}
		client = hub_conn.client
	}
	if queued := s.pending[conn_id] {
		pending = queued.clone()
		s.pending.delete(conn_id)
	}
	s.mu.unlock()
	if isnil(client) {
		return
	}
	for item in pending {
		s.send_client(conn_id, client, item.data, item.opcode)
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
			if !hub_conn.lifecycle.can_send() {
				if hub_conn.lifecycle.can_queue() {
					mut pending := s.pending[conn_id] or { []HubPendingMessage{} }
					pending << HubPendingMessage{
						data:   data
						opcode: if opcode == '' { 'text' } else { opcode }
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
	payload, code := HubPendingMessage{data: data, opcode: opcode}.payload_bytes() or { return false }
	if code == .text_frame {
		c.write_string(data) or { return false }
		return true
	}
	c.write(payload, code) or { return false }
	return true
}
