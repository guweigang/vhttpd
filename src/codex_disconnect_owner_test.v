module main

import codex
import command
import net
import net.websocket
import time

fn codex_disconnect_owner_pair() (&websocket.Client, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	addr := listener.addr() or { panic(err) }
	mut peer := net.dial_tcp(addr.str()) or { panic(err) }
	peer.set_read_timeout(30 * time.millisecond)
	mut client := websocket.new_client('ws://localhost:1') or { panic(err) }
	client.conn = listener.accept() or { panic(err) }
	client.set_state(.open)
	return client, peer
}

fn test_codex_disconnect_drains_connection_rpcs_but_preserves_logical_routes_and_snapshots() {
	mut app := &App{}
	for instance in ['main', 'secondary'] {
		app.providers.codex.update(instance, codex.ProviderRuntime{
			connected:         true
			initialized:       true
			thread_id:         'thread'
			active_stream_id:  'stream'
			thread_stream_map: {
				'thread': 'stream'
			}
			stream_map:        {
				'stream': [codex.CodexTarget{ platform: 'feishu', message_id: 'message' }]
			}
			read_fallbacks:    {
				'thread': codex.ReadFallback{ stream_id: 'stream' }
			}
		})
		owned := app.providers.codex_register_rpc(instance, codex.PendingRpc{ stream_id: 'stream' })
		held := app.providers.codex.snapshot(instance)
		app.codex_provider_on_disconnected(instance, 'closed')
		live := app.providers.codex.snapshot(instance)
		assert live.pending_rpcs.len == 0
		assert live.read_fallbacks.len == 0
		assert !live.connected && !live.initialized
		assert live.connection() == none
		assert live.thread_id == ''
		assert live.active_stream_id == 'stream'
		assert live.thread_stream_map['thread'] == 'stream'
		assert live.stream_map['stream'][0].message_id == 'message'
		assert held.pending_rpcs.len == 1
		assert held.read_fallbacks.len == 1
		assert !owned.is_pending()
		assert !owned.cancel()
		next := app.providers.codex_register_rpc(instance, codex.PendingRpc{ stream_id: 'next' })
		assert next.id > owned.id
		_, found := app.codex_take_pending_rpc(instance, owned.id)
		assert !found
		assert next.is_pending()
	}
	// Disconnecting a named instance cannot drain the main instance.
	assert app.providers.codex.snapshot('main').pending_rpcs.len == 1
}

fn test_codex_prepared_turn_sends_to_its_captured_connection() {
	mut old_client, mut old_peer := codex_disconnect_owner_pair()
	mut new_client, mut new_peer := codex_disconnect_owner_pair()
	defer {
		old_client.conn.close() or {}
		new_client.conn.close() or {}
		old_peer.close() or {}
		new_peer.close() or {}
	}
	mut app := &App{}
	app.providers.codex.update('main', codex.ProviderRuntime{ connected: true, initialized: true, thread_id: 'thread', conn: old_client })
	prepared := app.codex_prepare_turn(command.NormalizedCommand{ correlation: command.CommandCorrelation{ stream_id: 'stream' } })
	assert prepared.failure == ''
	app.providers.codex_runtime_mutate[bool]('main', fn [new_client] (mut rt codex.ProviderRuntime) bool {
		rt.conn = new_client
		return true
	})
	prepared.send('captured-turn') or { panic(err) }
	mut wire := []u8{len: 2048}
	assert (old_peer.read(mut wire) or { panic(err) }) > 0
	mut unexpected := false
	new_peer.read(mut wire) or { unexpected = true }
	assert unexpected
	assert app.providers.codex.snapshot('main').pending_rpcs.len == 1
	_, found := app.codex_take_pending_rpc('main', prepared.id)
	assert found
}

fn test_codex_prepared_turn_cannot_send_after_disconnect_and_reconnect() {
	mut old_client, mut old_peer := codex_disconnect_owner_pair()
	mut new_client, mut new_peer := codex_disconnect_owner_pair()
	defer {
		old_client.conn.close() or {}
		new_client.conn.close() or {}
		old_peer.close() or {}
		new_peer.close() or {}
	}
	mut app := &App{}
	app.providers.codex.update('main', codex.ProviderRuntime{ connected: true, initialized: true, thread_id: 'thread', conn: old_client })
	prepared := app.codex_prepare_turn(command.NormalizedCommand{ correlation: command.CommandCorrelation{ stream_id: 'old' } })
	app.codex_provider_on_disconnected('main', 'closed')
	app.providers.codex_runtime_mutate[bool]('main', fn [new_client] (mut rt codex.ProviderRuntime) bool {
		rt.conn = new_client
		rt.connected = true
		rt.initialized = true
		return true
	})
	fresh := app.providers.codex_register_rpc('main', codex.PendingRpc{ stream_id: 'new' })
	mut failed := false
	prepared.send('retired-turn') or {
		failed = true
		assert err.msg() == 'codex pending registration retired'
	}
	assert failed
	assert fresh.is_pending()
	assert app.providers.codex.snapshot('main').pending_rpcs.len == 1
	mut wire := []u8{len: 2048}
	mut peers := [old_peer, new_peer]
	for mut peer in peers {
		mut no_write := false
		peer.read(mut wire) or { no_write = true }
		assert no_write
	}
}

fn test_codex_prepared_turn_rejects_response_consumed_registration() {
	mut client, mut peer := codex_disconnect_owner_pair()
	defer {
		client.conn.close() or {}
		peer.close() or {}
	}
	mut app := &App{}
	app.providers.codex.update('main', codex.ProviderRuntime{ connected: true, initialized: true, thread_id: 'thread', conn: client })
	prepared := app.codex_prepare_turn(command.NormalizedCommand{ correlation: command.CommandCorrelation{ stream_id: 'stream' } })
	_, found := app.codex_take_pending_rpc('main', prepared.id)
	assert found
	mut failed := false
	prepared.send('consumed') or { failed = true }
	assert failed
	mut wire := []u8{len: 2048}
	mut no_write := false
	peer.read(mut wire) or { no_write = true }
	assert no_write
}

fn test_codex_concurrent_disconnect_and_registration_cleanup_do_not_remove_new_records() {
	mut app := &App{}
	mut tasks := []thread{}
	for index in 0 .. 16 {
		tasks << spawn fn [mut app, index] () {
			instance := 'instance-${index}'
			for _ in 0 .. 32 {
				old := app.providers.codex_register_rpc(instance, codex.PendingRpc{ stream_id: 'old' })
				app.providers.codex_provider_on_disconnected(instance, 'closed')
				fresh := app.providers.codex_register_rpc(instance, codex.PendingRpc{ stream_id: 'new' })
				assert !old.is_pending()
				assert !old.cancel()
				assert fresh.is_pending()
				assert fresh.cancel()
			}
		}()
	}
	tasks.wait()
	for index in 0 .. 16 {
		live := app.providers.codex.snapshot('instance-${index}')
		assert live.pending_rpcs.len == 0
		assert live.rpc_id_counter == 64
	}
}
