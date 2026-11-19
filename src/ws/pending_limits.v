module ws

const pending_message_limit = 128
const pending_byte_limit = 1024 * 1024
const pending_target_limit = 1024

fn (s &HubState) can_enqueue_unlocked(conn_id string, data string) bool {
	if conn_id !in s.pending && s.pending.len >= pending_target_limit { return false }
	items := s.pending[conn_id] or { []HubPendingMessage{} }
	if items.len >= pending_message_limit || data.len > pending_byte_limit { return false }
	mut bytes := data.len
	for item in items {
		bytes += item.data.len
		if bytes > pending_byte_limit { return false }
	}
	return true
}
