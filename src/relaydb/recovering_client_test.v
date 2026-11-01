module relaydb

import builtin.closure
import dbx
import json2 as json
import sync

@[heap]
struct RecoveryPeer {
mut:
	mu sync.Mutex
	epoch int = 1
	connections int
	calls []Envelope
	entered chan bool = chan bool{cap: 1}
	release chan bool = chan bool{cap: 1}
}

@[heap]
struct RecoveryConnection {
    peer &RecoveryPeer @[required]
    epoch int
}

fn (mut peer RecoveryPeer) connection() Connection {
    peer.mu.@lock()
    epoch := peer.epoch
    peer.connections++
    peer.mu.unlock()
    return &RecoveryConnection{peer: peer, epoch: epoch}
}

fn (connection RecoveryConnection) is_current() bool {
    mut peer := connection.peer
    peer.mu.@lock()
    defer { peer.mu.unlock() }
    return peer.epoch == connection.epoch
}

fn (connection RecoveryConnection) send(raw string, _ int, _ fn () bool) !string {
    mut peer := connection.peer
    e := json.decode[Envelope](raw)!
    peer.mu.@lock()
    peer.calls << e
    current := peer.epoch == connection.epoch
    peer.mu.unlock()
    if e.request.sql_text in ['held', 'held_success'] {
        peer.entered <- true
        _ := <-peer.release
        if e.request.sql_text == 'held' { return error('late_transport_failure') }
        return json.encode(dbx.Response{ok: true, driver: 'mysql'})
    }
    if !current { return error('transport_closed') }
    if e.request.sql_text == 'uncertain' { return error('response_lost') }
    return json.encode(dbx.Response{ok: e.request.sql_text != 'db_error', driver: 'mysql', session_id: if e.request.op == 'begin' { '1' } else { e.request.session_id }})
}

fn (mut peer RecoveryPeer) reconnect() {
	peer.mu.@lock()
	peer.epoch++
	peer.mu.unlock()
}

fn recovering_fixture(mut peer RecoveryPeer) &RecoveringClient {
	return RecoveringClient.new('db/test', fn [mut peer] () !Connection { return peer.connection() })
}

fn recovering_call(mut client RecoveringClient, op string, statement string, session string) !dbx.Response {
	return json.decode[dbx.Response](client.run_json(json.encode(dbx.Request{op: op, sql_text: statement, session_id: session, timeout_ms: 1000}), fn () bool { return false })!)!
}

fn test_reconnect_rejects_old_handles_even_when_remote_reuses_transaction_id() ! {
	mut peer := &RecoveryPeer{}
	mut client := recovering_fixture(mut peer)
	defer { client.close() }
	old := recovering_call(mut client, 'begin', '', '')!
	peer.reconnect()
	recovering_call(mut client, 'query', 'old_transaction', old.session_id) or {
		assert err.msg() == 'relay_db_transaction_connection_lost'
	}
	assert recovering_call(mut client, 'query', 'new_request', '')!.ok
	new_tx := recovering_call(mut client, 'begin', '', '')!
	assert old.session_id != new_tx.session_id
	assert old.session_id.all_after(':') == '1' && new_tx.session_id.all_after(':') == '1'
	for op in ['query', 'execute', 'commit', 'rollback'] {
		recovering_call(mut client, op, 'stale', old.session_id) or {
			assert err.msg() == 'relay_db_transaction_connection_lost'
			continue
		}
		assert false, 'Old transaction reached the new generation'
	}
	assert recovering_call(mut client, 'execute', 'new_transaction', new_tx.session_id)!.ok
	assert recovering_call(mut client, 'commit', '', new_tx.session_id)!.ok
	assert peer.calls.filter(it.request.sql_text in ['old_transaction', 'stale']).len == 0
	assert peer.connections == 2
}

fn test_unknown_write_result_is_not_replayed_and_later_operations_recover() ! {
	mut peer := &RecoveryPeer{}
	mut client := recovering_fixture(mut peer)
	recovering_call(mut client, 'execute', 'uncertain', '') or { assert err.msg() == 'response_lost' }
	assert recovering_call(mut client, 'query', 'new_request', '')!.ok
	assert peer.calls.filter(it.request.op == 'execute').len == 1
	assert peer.calls[0].client_id != peer.calls.last().client_id
	assert peer.connections == 2
	assert !recovering_call(mut client, 'query', 'db_error', '')!.ok
	assert recovering_call(mut client, 'query', 'after_database_error', '')!.ok
	assert peer.connections == 2 // SQL errors do not retire a healthy transport.
	mut rejected := false
	recovering_call(mut client, 'begin', 'db_error', '') or {
		rejected = true
		assert err.msg() == 'relay_db_transaction_failed'
	}
	assert rejected, 'Failed BEGIN was returned as a successful admission'
	assert recovering_call(mut client, 'begin', '', '')!.ok
	assert peer.connections == 2
	client.close()
	recovering_call(mut client, 'query', 'after_close', '') or {
		assert err.msg() == 'relay_db_client_closed'
		assert peer.connections == 2
		return
	}
	assert false, 'Explicit host shutdown reconnected'
}

fn recovering_held(mut client RecoveringClient, statement string) string {
	recovering_call(mut client, 'query', statement, '') or { return err.msg() }
	return 'unexpected_success'
}

fn test_late_failure_from_retired_generation_cannot_close_new_generation() ! {
	for statement, expected in {'held': 'late_transport_failure', 'held_success': 'relay_db_connection_changed'} {
		mut peer := &RecoveryPeer{}
		mut client := recovering_fixture(mut peer)
		old := spawn recovering_held(mut client, statement)
		_ := <-peer.entered
		peer.reconnect()
		assert recovering_call(mut client, 'query', 'new_request', '')!.ok
		peer.release <- true
		assert old.wait() == expected
		assert recovering_call(mut client, 'query', 'still_healthy', '')!.ok
		assert peer.connections == 2
		client.close()
	}
}

fn test_generation_survives_the_worker_callback_scope_that_created_it() ! {
    mut peer := &RecoveryPeer{}
    mut client := recovering_fixture(mut peer)
    defer { client.close() }
    mut lifetime := closure.new_lifetime()
    lifetime.frame(fn [mut client] () {
        response := recovering_call(mut client, 'query', 'first_request', '') or { panic(err) }
        assert response.ok
    })!
    lifetime.dispose()!
    assert recovering_call(mut client, 'query', 'later_request', '')!.ok
    assert peer.connections == 1
}
