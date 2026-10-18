module main

import codex
import command
import net
import net.websocket
import time

fn codex_rpc_owner_pair() (&websocket.Client, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(addr.str()) or { panic(err) }
	peer.set_read_timeout(time.second)
	mut client := websocket.new_client('ws://localhost:1') or { panic(err) }
	client.conn = listener.accept() or { panic(err) }
	client.set_state(.open)
	return client, peer
}

fn test_codex_disconnected_rpc_admission_does_not_publish_pending_or_routes() {
	for connected in [false, true] {
		mut app := &App{}
		app.providers.codex.update('main', codex.ProviderRuntime{ connected: connected, thread_id: 'old-thread' })
		if _ := app.codex_send_rpc('main', 'turn/start', '{"threadId":"new-thread"}', 'failed', 'message') {
			assert false
		}
		mut resume_failed := false
		app.codex_send_internal_thread_resume('main', 'new-thread') or { resume_failed = true }
		assert resume_failed
		live := app.providers.codex.snapshot('main')
		assert live.pending_rpcs.len == 0
		assert live.rpc_id_counter == 0
		assert live.current_stream_id() == ''
		assert live.thread_stream_map.len == 0
	}
}

fn test_codex_write_failures_release_only_their_pending_registrations() {
	mut client, mut peer := codex_rpc_owner_pair()
	defer { peer.close() or {} }
	client.conn.close() or { panic(err) }
	mut app := &App{}
	app.providers.codex.update('main', codex.ProviderRuntime{ connected: true, initialized: true, thread_id: 'thread', conn: client })
	app.codex_remember_pending_rpc('main', 700, codex.PendingRpc{ stream_id: 'keep' })
	if _ := app.codex_send_rpc('main', 'read', '{}', 'failed', '') {
		assert false
	}
	assert app.providers.codex.snapshot('main').pending_rpcs.len == 1
	if _ := app.codex_send_rpc('main', 'turn/start', '{"threadId":"other-thread"}', 'failed-turn', '') {
		assert false
	}
	assert app.providers.codex.snapshot('main').pending_rpcs.len == 1
	mut resume_failed := false
	app.codex_send_internal_thread_resume('main', 'other-thread') or { resume_failed = true }
	assert resume_failed
	live := app.providers.codex.snapshot('main')
	assert live.pending_rpcs.len == 1
	assert live.pending_rpcs[700].stream_id == 'keep'
}

fn test_codex_failed_turn_send_releases_its_pending_registration() {
	mut app := &App{}
	app.providers.codex.update('main', codex.ProviderRuntime{ connected: true, initialized: true, thread_id: 'thread' })
	app.codex_remember_pending_rpc('main', 700, codex.PendingRpc{ stream_id: 'keep' })
	mut failed := false
	app.codex_start_turn_normalized(command.NormalizedCommand{
		correlation:         command.CommandCorrelation{ stream_id: 'failed-turn' }
		response_message_id: 'message'
	}) or { failed = true }
	assert failed
	live := app.providers.codex.snapshot('main')
	assert live.pending_rpcs.len == 1
	assert live.pending_rpcs[700].stream_id == 'keep'
	// Routing is independently owned: a failed/partial write does not erase
	// bindings needed by late notifications or another in-flight request.
	assert live.thread_stream_map['thread'] == 'failed-turn'
}

fn test_codex_successful_rpc_and_resume_remain_pending_until_response() {
	mut client, mut peer := codex_rpc_owner_pair()
	defer {
		client.conn.close() or {}
		peer.close() or {}
	}
	mut app := &App{}
	app.providers.codex.update('main', codex.ProviderRuntime{ connected: true, initialized: true, thread_id: 'thread', conn: client })
	id := app.codex_send_rpc('main', 'read', '{}', 'stream', 'message') or { panic(err) }
	mut wire := []u8{len: 2048}
	assert (peer.read(mut wire) or { panic(err) }) > 0
	live := app.providers.codex.snapshot('main')
	assert live.pending_rpcs[id].method == 'read'
	assert live.pending_rpcs[id].stream_id == 'stream'
	app.codex_send_internal_thread_resume('main', 'thread') or { panic(err) }
	assert (peer.read(mut wire) or { panic(err) }) > 0
	assert app.providers.codex.snapshot('main').pending_rpcs.len == 2
	pending, found := app.codex_take_pending_rpc('main', id)
	assert found && pending.message_id == 'message'
	assert app.providers.codex.snapshot('main').pending_rpcs.len == 1
}

fn test_codex_old_registration_cannot_cancel_reused_wire_id_after_runtime_replacement() {
	mut app := &App{}
	for instance in ['main', 'secondary'] {
		old := app.providers.codex_register_rpc(instance, codex.PendingRpc{ stream_id: 'old' })
		app.providers.codex.update(instance, codex.ProviderRuntime{ instance: 'display-only' })
		new := app.providers.codex_register_rpc(instance, codex.PendingRpc{ stream_id: 'new' })
		assert old.id == new.id
		assert !old.cancel()
		assert app.providers.codex.snapshot(instance).pending_rpcs[new.id].stream_id == 'new'
		assert new.cancel()
		assert !new.cancel()
		assert app.providers.codex.snapshot(instance).pending_rpcs.len == 0
	}
}

fn test_codex_response_consumption_and_snapshot_publication_preserve_registration_identity() {
	mut app := &App{}
	first := app.providers.codex_register_rpc('main', codex.PendingRpc{ stream_id: 'first' })
	second := app.providers.codex_register_rpc('main', codex.PendingRpc{ stream_id: 'second' })
	other := app.providers.codex_register_rpc('secondary', codex.PendingRpc{ stream_id: 'other' })
	app.providers.codex.update('main', app.providers.codex.snapshot('main'))
	_, found := app.codex_take_pending_rpc('main', first.id)
	assert found
	assert !first.cancel()
	assert second.cancel()
	assert app.providers.codex.snapshot('secondary').pending_rpcs.len == 1
	assert other.cancel()
}

fn test_codex_concurrent_registration_cancellation_and_response_cleanup_are_isolated() {
	mut app := &App{}
	mut tasks := []thread{}
	for _ in 0 .. 16 {
		tasks << spawn fn [mut app] () {
			for index in 0 .. 32 {
				registration := app.providers.codex_register_rpc('main', codex.PendingRpc{ stream_id: 'owned' })
				if index % 2 == 0 {
					assert registration.cancel()
				} else {
					_, found := app.codex_take_pending_rpc('main', registration.id)
					assert found
					assert !registration.cancel()
				}
			}
		}()
	}
	tasks.wait()
	live := app.providers.codex.snapshot('main')
	assert live.rpc_id_counter == 512
	assert live.pending_rpcs.len == 0
}
