module main

import net.websocket

fn bridge_authority_test_server(mut host FeishuBridgeProxyHost, client &websocket.Client) &FeishuCardBridgeServerState {
	mut bridge := host.bridge_context()
	bridge.register_client('fixture', client) or { panic('missing connection') }
	return &FeishuCardBridgeServerState{ host: host, bridge: bridge, client_id: 'fixture' }
}
