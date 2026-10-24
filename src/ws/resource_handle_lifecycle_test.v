module ws

import net.websocket

fn test_pending_batch_borrows_actual_client_and_transfers_messages() {
	mut hub := HubState{}
	client := websocket.new_client('ws://127.0.0.1:1') or { panic(err) }
	hub.conns['conn'] = HubConn{ id: 'conn', client: client, lifecycle: &DispatchConnState{ phase: .open } }
	hub.pending['conn'] = [HubPendingMessage{ data: 'queued', opcode: 'text' }]
	batch := hub.take_pending_batch('conn') or { panic('missing batch') }
	assert batch.client == client
	assert batch.messages[0].data == 'queued'
	assert 'conn' !in hub.pending
	assert hub.take_pending_batch('conn') == none
	// An unconnected real client rejects writing without dereferencing an option wrapper.
	hub.pending['conn'] = [HubPendingMessage{ data: 'queued', opcode: 'text' }]
	hub.flush_pending('conn')
}
