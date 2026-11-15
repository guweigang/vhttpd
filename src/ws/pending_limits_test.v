module ws

fn test_absent_target_pending_is_bounded() {
	mut hub := HubState{}
	for index in 0 .. pending_message_limit {
		assert hub_send_to(mut hub, 'missing', index.str(), 'text')
	}
	assert !hub_send_to(mut hub, 'missing', 'overflow', 'text')
	assert hub.pending['missing'].len == pending_message_limit
	hub_close_target(mut hub, 'missing', 1000, '')
	assert 'missing' !in hub.pending
}

fn test_pending_rejects_oversized_payload() {
	mut hub := HubState{}
	assert !hub_send_to(mut hub, 'missing', 'x'.repeat(pending_byte_limit + 1), 'text')
	assert hub.pending.len == 0
}

fn test_room_limit_preserves_existing_membership() {
	mut hub := HubState{}
	for index in 0 .. 128 { assert hub.join('connection', index.str()) }
	assert !hub.join('connection', 'overflow')
	assert hub.join('connection', '0')
	hub.cleanup_conn('connection')
	assert hub.room_members.len == 0
}
