module main

import codex
import net
import net.websocket
import time

fn codex_rpc_admission_pair() (&websocket.Client, &net.TcpConn) {
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

fn test_codex_rpc_prepare_rejects_disconnected_or_missing_connection_without_publication() {
	mut client, mut peer := codex_rpc_admission_pair()
	defer {
		client.conn.close() or {}
		peer.close() or {}
	}
	for instance in ['main', 'secondary'] {
		for connected in [false, true] {
			mut app := &App{}
			mut runtime := codex.ProviderRuntime{ connected: connected, thread_id: 'old' }
			if !connected { runtime.conn = client }
			app.providers.codex.update(instance, runtime)
			prepared := app.providers.codex_prepare_rpc(instance, codex.PendingRpc{ method: 'turn/start', stream_id: 'rejected' }, 'new')
			assert prepared.failure == 'codex provider not connected'
			live := app.providers.codex.snapshot(instance)
			assert live.pending_rpcs.len == 0
			assert live.rpc_id_counter == 0
			assert live.thread_id == 'old'
			assert live.active_stream_id == ''
			assert live.thread_stream_map.len == 0
		}
	}
}

fn test_codex_rpc_prepare_captures_resume_and_route_as_one_publication() {
	mut client, mut peer := codex_rpc_admission_pair()
	defer {
		client.conn.close() or {}
		peer.close() or {}
	}
	mut app := &App{}
	app.providers.codex.update('main', codex.ProviderRuntime{ connected: true, thread_id: 'old', conn: client })
	prepared := app.providers.codex_prepare_rpc('default', codex.PendingRpc{ instance: 'main', method: 'turn/start', stream_id: 'stream', message_id: 'message' }, 'new')
	assert prepared.failure == ''
	primary := prepared.registration or { panic('missing main') }
	resume := prepared.resume_registration or { panic('missing resume') }
	assert resume.id < primary.id
	assert prepared.instance == 'main'
	assert prepared.bound_thread_id == 'new'
	held := app.providers.codex.snapshot('main')
	assert held.pending_rpcs.len == 2
	assert held.pending_rpcs[resume.id].method == ''
	assert held.pending_rpcs[primary.id].message_id == 'message'
	assert held.active_stream_id == 'stream'
	assert held.thread_stream_map['new'] == 'stream'
	// Runtime observation changes cannot redirect a prepared batch.
	app.providers.codex_runtime_mutate[bool]('main', fn (mut rt codex.ProviderRuntime) bool {
		rt.conn = none
		return true
	})
	id := prepared.send('turn/start', '{"threadId":"new"}') or { panic(err) }
	assert id == primary.id
	mut wire := []u8{len: 4096}
	assert (peer.read(mut wire) or { panic(err) }) > 0
	assert primary.is_pending()
	assert resume.is_pending()
	app.codex_provider_on_disconnected('main', 'done')
	assert !primary.is_pending() && !resume.is_pending()
	assert held.pending_rpcs.len == 2
}

fn test_codex_rpc_prepared_batch_rejects_disconnect_without_touching_replacement() {
	mut client, mut peer := codex_rpc_admission_pair()
	defer {
		client.conn.close() or {}
		peer.close() or {}
	}
	mut app := &App{}
	app.providers.codex.update('secondary', codex.ProviderRuntime{ connected: true, thread_id: 'old', conn: client })
	prepared := app.providers.codex_prepare_rpc('secondary', codex.PendingRpc{ method: 'turn/start', stream_id: 'old' }, 'new')
	app.codex_provider_on_disconnected('secondary', 'closed')
	// Explicit replacement may reuse the same numeric IDs; identities still differ.
	app.providers.codex.update('secondary', codex.ProviderRuntime{ connected: true, thread_id: 'replacement', active_stream_id: 'keep', conn: client })
	fresh := app.providers.codex_register_rpc('secondary', codex.PendingRpc{ stream_id: 'keep' })
	mut failed := false
	prepared.send('turn/start', '{}') or { failed = true }
	assert failed
	live := app.providers.codex.snapshot('secondary')
	assert live.pending_rpcs.len == 1
	assert fresh.is_pending()
	assert live.thread_id == 'replacement'
	assert live.active_stream_id == 'keep'
	assert live.thread_stream_map.len == 0
	mut wire := []u8{len: 4096}
	mut no_write := false
	peer.read(mut wire) or { no_write = true }
	assert no_write
}

fn test_codex_rpc_batch_failed_prelude_releases_both_unsent_registrations() {
	mut client, mut peer := codex_rpc_admission_pair()
	defer { peer.close() or {} }
	mut app := &App{}
	app.providers.codex.update('main', codex.ProviderRuntime{ connected: true, thread_id: 'old', conn: client })
	keep := app.providers.codex_register_rpc('main', codex.PendingRpc{ stream_id: 'keep' })
	prepared := app.providers.codex_prepare_rpc('main', codex.PendingRpc{ method: 'turn/start', stream_id: 'failed' }, 'new')
	client.conn.close() or { panic(err) }
	mut failed := false
	prepared.send('turn/start', '{}') or { failed = true }
	assert failed
	assert app.providers.codex.snapshot('main').pending_rpcs.len == 1
	assert keep.is_pending()
	// Logical routes remain separately owned after partial/failed network I/O.
	assert app.providers.codex.snapshot('main').thread_stream_map['new'] == 'failed'
}

fn test_codex_rpc_consumed_main_does_not_send_or_leave_unsent_resume() {
	mut client, mut peer := codex_rpc_admission_pair()
	defer {
		client.conn.close() or {}
		peer.close() or {}
	}
	mut app := &App{}
	app.providers.codex.update('main', codex.ProviderRuntime{ connected: true, thread_id: 'old', conn: client })
	prepared := app.providers.codex_prepare_rpc('main', codex.PendingRpc{ method: 'turn/start', stream_id: 'stream' }, 'new')
	primary := prepared.registration or { panic('missing main') }
	_, found := app.codex_take_pending_rpc('main', primary.id)
	assert found
	mut failed := false
	prepared.send('turn/start', '{}') or { failed = true }
	assert failed
	assert app.providers.codex.snapshot('main').pending_rpcs.len == 0
	mut wire := []u8{len: 4096}
	mut no_write := false
	peer.read(mut wire) or { no_write = true }
	assert no_write
}

fn test_codex_rpc_concurrent_snapshots_observe_complete_registration_and_route() {
	mut client, mut peer := codex_rpc_admission_pair()
	defer {
		client.conn.close() or {}
		peer.close() or {}
	}
	mut app := &App{}
	app.providers.codex.update('main', codex.ProviderRuntime{ connected: true, conn: client })
	mut tasks := []thread{}
	for worker in 0 .. 16 {
		tasks << spawn fn [mut app, worker] () {
			for index in 0 .. 32 {
				stream := '${worker}-${index}'
				prepared := app.providers.codex_prepare_rpc('main', codex.PendingRpc{ method: 'read', stream_id: stream }, 'thread-${stream}')
				assert prepared.failure == ''
			}
		}()
	}
	for _ in 0 .. 64 {
		held := app.providers.codex.snapshot('main')
		assert held.pending_rpcs.len == held.rpc_id_counter
		for _, pending in held.pending_rpcs {
			assert held.thread_stream_map['thread-${pending.stream_id}'] == pending.stream_id
		}
	}
	tasks.wait()
	held := app.providers.codex.snapshot('main')
	assert held.pending_rpcs.len == 512
	assert held.thread_stream_map.len == 512
	app.codex_provider_on_disconnected('main', 'done')
	assert app.providers.codex.snapshot('main').pending_rpcs.len == 0
}
