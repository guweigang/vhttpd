module main

import codex
import feishu
import net
import net.websocket

fn capacity_pair() (&websocket.Client, &net.TcpConn) {
	mut listener := net.listen_tcp(.ip, '127.0.0.1:0') or { panic(err) }
	defer { listener.close() or {} }
	mut peer := net.dial_tcp((listener.addr() or { panic(err) }).str()) or { panic(err) }
	mut client := websocket.new_client('ws://localhost:1') or { panic(err) }
	client.conn = listener.accept() or { panic(err) }
	client.set_state(.open)
	return client, peer
}

fn capacity_seed_binding(mut app App, owner &feishu.BridgeAuthority) string {
	mut remote := feishu.FeishuState{}
	lease := remote.issue_wire_creation('active', 'main') or { panic(err) }
	issue := app.providers.feishu.begin_creation_issue('active', 'main') or { panic(err) }
	app.providers.feishu.complete_bridge_creation_issue(issue, lease, owner) or { panic(err) }
	app.providers.feishu.finish_creation_issue(issue)
	claim := app.providers.feishu.admit_wire_initial_creation('active', 'main', lease.generation, lease.token) or { panic('admit') }
	app.providers.feishu.mu.@lock()
	assert app.providers.feishu.commit_initial_send_generation_unlocked(claim, 'physical', 'main', '', '', 'active', lease.generation)
	app.codex_rebind_stream_target('main', 'active', codex.CodexTarget{ platform: 'feishu', message_id: 'physical', buffer_message_id: 'physical', stream_generation: lease.generation })
	app.providers.feishu.mu.unlock()
	app.providers.feishu.finish_initial_send(claim)
	return lease.generation
}

fn capacity_issue_result(mut app App) string {
	if _ := app.issue_feishu_stream_creation('attempt', 'main', '') {
		return 'unexpected success'
	} else {
		return err.msg()
	}
}

fn test_capacity_ack_preserves_active_binding_and_rotates_only_after_drain() {
	for code in ['bridge_creation_capacity', 'feishu_creation_capacity', 'malformed'] {
		mut app := &App{}
		app.providers.feishu.card_bridge_enabled_flag = true
		app.providers.feishu.card_bridge_ws_url = 'ws://fixture.invalid'
		mut bridge := app.bridge_context()
		mut client, mut peer := capacity_pair()
		defer {
			peer.close() or {}
			client.conn.close() or {}
		}
		bridge.set_client_conn(client)
		owner := app.providers.feishu.card_bridge_client_authority or { panic('owner') }
		generation := capacity_seed_binding(mut app, owner)
		work := spawn capacity_issue_result(mut app)
		id := feishu_test_sent_request(mut bridge, mut peer)
		ch := bridge.take_proxy_pending_from(id, client) or { panic('waiter') }
		ch <- feishu.BridgeProxyResult{
			error:          if code == 'malformed' {
				'bridge_creation_capacity'
			} else {
				code
			}
			creation_token: if code == 'malformed' { 'unexpected-token' } else { '' }
		}
		expected := if code == 'malformed' { 'bridge_creation_capacity' } else { code }
		assert work.wait() == expected
		if code == 'malformed' {
			assert app.providers.feishu.card_bridge_client_conn == none
			assert app.providers.feishu.buffers.len == 0
			continue
		}
		assert bridge.client_conn() != none
		assert app.providers.feishu.buffers['physical'].generation == generation
		assert app.codex_find_stream_targets('active')[0].stream_generation == generation
		app.providers.feishu.mu.@lock()
		released := app.providers.feishu.release_wire_stream_unlocked('physical', 'active', 'main', generation) or { panic('drain') }
		app.codex_release_feishu_targets(released)
		app.providers.feishu.mu.unlock()
		bridge.rotate_creation_capacity_if_idle()
		assert (bridge.client_conn() == none) == (code == 'bridge_creation_capacity')
		bridge.clear_client_conn(client)
	}
}

fn test_capacity_rotation_waits_for_other_issuance_ack_gap_and_valid_ticket() {
	mut app := &App{}
	app.providers.feishu.card_bridge_enabled_flag = true
	app.providers.feishu.card_bridge_ws_url = 'ws://fixture.invalid'
	mut bridge := app.bridge_context()
	mut client, mut peer := capacity_pair()
	defer {
		peer.close() or {}
		client.conn.close() or {}
	}
	bridge.set_client_conn(client)
	owner := app.providers.feishu.card_bridge_client_authority or { panic('owner') }
	other := app.providers.feishu.begin_creation_issue('other', 'main') or { panic(err) }
	work := spawn capacity_issue_result(mut app)
	id := feishu_test_sent_request(mut bridge, mut peer)
	ch := bridge.take_proxy_pending_from(id, client) or { panic('waiter') }
	ch <- feishu.BridgeProxyResult{ error: 'bridge_creation_capacity' }
	assert work.wait() == 'bridge_creation_capacity'
	assert bridge.client_conn() != none
	mut remote := feishu.FeishuState{}
	lease := remote.issue_wire_creation('other', 'main') or { panic(err) }
	app.providers.feishu.complete_bridge_creation_issue(other, lease, owner) or { panic(err) }
	app.providers.feishu.finish_creation_issue(other)
	bridge.rotate_creation_capacity_if_idle()
	assert bridge.client_conn() != none
	app.providers.feishu.revoke_wire_creation('other', 'main', lease)
	bridge.rotate_creation_capacity_if_idle()
	assert bridge.client_conn() == none
	mut current, mut current_peer := capacity_pair()
	defer {
		current_peer.close() or {}
		current.conn.close() or {}
	}
	bridge.set_client_conn(current)
	new_generation := capacity_seed_binding(mut app, app.providers.feishu.card_bridge_client_authority or { panic('current') })
	bridge.clear_client_conn(client)
	assert bridge.take_proxy_pending_from(id, current) == none
	assert app.providers.feishu.buffers['physical'].generation == new_generation
	if _ := app.providers.feishu.complete_bridge_creation_issue(other, lease, owner) {
		assert false
	}
	assert bridge.client_conn() != none
}
