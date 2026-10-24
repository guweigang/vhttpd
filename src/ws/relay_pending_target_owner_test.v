module ws

import net.websocket

fn pending_target_client() &websocket.Client {
	return websocket.new_client('ws://127.0.0.1:1') or { panic(err) }
}

fn pending_target_register(mut hub HubState, client &websocket.Client, lifecycle &DispatchConnState) {
	hub.register_conn('same', '', 'GET', 'same-request', 'same-trace', '/', {}, {}, '', client, lifecycle)
}

fn test_pending_from_retired_registration_is_not_claimed_by_replacement() {
	mut hub := &HubState{}
	old := &DispatchConnState{}
	pending_target_register(mut hub, pending_target_client(), old)
	assert hub_send_to(mut hub, 'same', 'old', 'text')
	next := &DispatchConnState{ phase: .open }
	pending_target_register(mut hub, pending_target_client(), next)
	batch := hub.take_pending_batch('same') or { panic('expected queue claim') }
	assert batch.messages.len == 0
	assert hub.pending.len == 0
}

fn test_mixed_future_and_registration_queues_keep_only_current_authority() {
	mut hub := &HubState{}
	assert hub_send_to(mut hub, 'same', 'future', 'text')
	pending_target_register(mut hub, pending_target_client(), &DispatchConnState{})
	assert hub_send_to(mut hub, 'same', 'old', 'text')
	mut next := &DispatchConnState{}
	pending_target_register(mut hub, pending_target_client(), next)
	assert hub_send_to(mut hub, 'same', 'new', 'text')
	next.mark_open()
	batch := hub.take_pending_batch('same') or { panic('expected queue claim') }
	assert batch.messages.map(it.data) == ['future', 'new']
}

fn test_borrowed_old_client_cannot_append_to_replacement_opening_queue() {
	mut hub := &HubState{}
	old_client := pending_target_client()
	pending_target_register(mut hub, old_client, &DispatchConnState{ phase: .open })
	pending_target_register(mut hub, pending_target_client(), &DispatchConnState{})
	assert !hub.send_client('same', old_client, 'old', 'text')
	assert 'same' !in hub.pending
}

fn test_broadcast_opening_queue_does_not_transfer_to_replacement() {
	mut hub := &HubState{}
	pending_target_register(mut hub, pending_target_client(), &DispatchConnState{})
	hub.room_members['room'] = {
		'same': true
	}
	assert hub_broadcast(mut hub, 'room', 'old-broadcast', 'text', '') == 1
	pending_target_register(mut hub, pending_target_client(), &DispatchConnState{ phase: .open })
	batch := hub.take_pending_batch('same') or { panic('expected queue claim') }
	assert batch.messages.len == 0
}

fn test_same_registration_keeps_its_opening_messages() {
	mut hub := &HubState{}
	mut lifecycle := &DispatchConnState{}
	client := pending_target_client()
	pending_target_register(mut hub, client, lifecycle)
	assert hub_send_to(mut hub, 'same', 'current', 'text')
	assert hub.send_client('same', client, 'borrowed-current', 'text')
	lifecycle.mark_open()
	batch := hub.take_pending_batch('same') or { panic('expected queue claim') }
	assert batch.messages.map(it.data) == ['current', 'borrowed-current']
}

fn test_unregistered_future_queue_remains_available_to_first_registration() {
	mut hub := &HubState{}
	assert hub_send_to(mut hub, 'same', 'future', 'text')
	pending_target_register(mut hub, pending_target_client(), &DispatchConnState{ phase: .open })
	batch := hub.take_pending_batch('same') or { panic('expected queue claim') }
	assert batch.messages.map(it.data) == ['future']
}
