module main

import api.mcp.protocol
import cachex
import codex
import dbx
import executor
import listener_runtime
import net.unix
import net.websocket
import os
import time

fn test_provider_connection_attach_disconnect_and_reconnect() {
	mut rt := codex.ProviderRuntime{}
	assert rt.connection() == none
	first := websocket.new_client('ws://127.0.0.1:1') or { panic(err) }
	second := websocket.new_client('ws://127.0.0.1:2') or { panic(err) }
	rt.attach_connection(first)
	assert rt.connection() or { panic('missing connection') } == first
	rt.note_disconnected('closed')
	rt.note_disconnected('closed again')
	assert rt.connection() == none
	rt.attach_connection(second)
	assert rt.connection() or { panic('missing reconnect') } == second
}

fn test_feishu_bridge_absent_and_attached_connection() {
	mut providers := ProviderRuntimeHub{}
	mut bridge := providers.feishu_card_bridge_context()
	assert bridge.client_conn() == none
	assert bridge.client('missing') == none
	assert !bridge.send_to_server('data')
	assert !bridge.send('missing', 'data')
	client := websocket.new_client('ws://127.0.0.1:1') or { panic(err) }
	bridge.set_client_conn(client)
	bridge.register_client('local', client)
	assert bridge.client_conn() or { panic('missing connection') } == client
	assert bridge.client('local') or { panic('missing client') } == client
	replacement := websocket.new_client('ws://127.0.0.1:2') or { panic(err) }
	bridge.set_client_conn(replacement)
	bridge.clear_client_conn(client)
	assert bridge.client_conn() or { panic('replacement cleared') } == replacement
	bridge.clear_client_conn(replacement)
	bridge.clear_client_conn(replacement)
	bridge.unregister_client('local', client)
	assert bridge.client_conn() == none
	assert bridge.client('local') == none
}

fn test_listener_stop_defers_close_to_serving_owner() {
	path := '/tmp/vhttpd-handle-${os.getpid()}-${time.now().unix_micro()}.sock'
	defer { os.rm(path) or {} }
	mut listener := listener_runtime.listen(path) or { panic(err) }
	mut cache := cachex.Runtime{}
	generation := cache.listener_owner.reserve() or { panic('missing reservation') }
	assert cache.listener_owner.publish(generation, listener)
	cache.request_stop()
	cache.request_stop()
	assert !cache.started
	assert cache.listener_owner.should_stop(generation)
	assert os.exists(path)
	assert cache.listener_owner.finish(generation)
	assert !os.exists(path)
	mut db := dbx.Runtime{}
	db_generation := db.listener_owner.reserve() or { panic('missing db reservation') }
	db.request_stop()
	db.request_stop()
	assert db.listener_owner.should_stop(db_generation)
	assert !db.started
	assert db.listener_owner.finish(db_generation)
}

fn test_executor_outcome_transfers_closing_responsibility_once() {
	mut outcome := executor.HttpLogicDispatchOutcome{}
	assert outcome.take_live_conn() == none
	outcome.close_live_conn()
	conn := &unix.StreamConn{}
	outcome.conn = conn
	assert outcome.take_live_conn() or { panic('missing stream') } == conn
	assert outcome.take_live_conn() == none
	outcome.close_live_conn()
}

fn test_mcp_flush_without_bound_sse_retains_pending_messages() {
	mut state := protocol.McpState{}
	state.ensure_session('session', '', '', '', '')
	assert state.do_queue('session', '{"message":"queued"}').queued
	assert !state.flush_session('session')
	assert state.sessions['session'].pending == ['{"message":"queued"}']
	assert state.sessions['session'].stream == none
	assert state.delete_session('session')
}

$if enable_db ? {
	fn test_pgsql_missing_handles_fail_explicitly_and_close_is_repeatable() {
		mut pool := dbx.PoolHandle{ driver: 'pgsql' }
		mut failed := false
		_ := pool.acquire() or {
			assert err.msg() == 'pgsql_pool_unavailable'
			failed = true
			dbx.SessionHandle{}
		}
		assert failed
		pool.close()
		pool.close()
		mut session := dbx.SessionHandle{ driver: 'pgsql' }
		failed = false
		_ := session.ping() or {
			assert err.msg() == 'pgsql_session_unavailable'
			failed = true
			false
		}
		assert failed
		session.begin() or { assert err.msg() == 'pgsql_session_unavailable' }
		session.close() or { panic(err) }
		session.close() or { panic(err) }
	}
}
