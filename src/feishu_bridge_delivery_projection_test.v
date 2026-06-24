module main

import feishu
import upstream

fn test_feishu_card_bridge_dispatch_delivery_outcome_projects_relay_delivery() {
	outcome := feishu_card_bridge_dispatch_delivery_outcome('local-main', feishu.BridgeDispatchRequest{
		request_id:  'bridge-1'
		trace_id:    'trace-1'
		app:         'main'
		event_type:  'card.action'
		message_id:  'om_1'
		target:      'chat_1'
		target_type: 'chat_id'
		metadata:    {
			'event_kind': 'action'
		}
	})

	assert outcome.kind == .relay_delivery
	assert outcome.target == 'relay:feishu-card:local-main'
	assert outcome.metadata['relay_protocol'] == 'feishu_card_bridge'
	assert outcome.metadata['relay_carrier'] == 'websocket'
	assert outcome.metadata['relay_direction'] == 'dispatch'
	assert outcome.metadata['relay_client_id'] == 'local-main'
	assert outcome.metadata['request_id'] == 'bridge-1'
	assert outcome.metadata['trace_id'] == 'trace-1'
	assert outcome.metadata['event_kind'] == 'action'
	assert outcome.metadata['event_type'] == 'card.action'
	assert outcome.metadata['message_id'] == 'om_1'
	assert outcome.metadata['target'] == 'chat_1'
	assert outcome.metadata['target_type'] == 'chat_id'
}

fn test_feishu_card_bridge_proxy_delivery_outcome_projects_relay_delivery() {
	outcome := feishu_card_bridge_proxy_delivery_outcome(feishu.BridgeProxyRequest{
		request_id: 'bridge-proxy-1'
		action:     'send'
		request:    upstream.UpstreamSendRequest{
			provider:     'feishu'
			instance:     'main'
			target:       'chat_2'
			target_type:  'chat_id'
			message_type: 'text'
			metadata:     {
				'stream_id': 'stream-1'
			}
		}
	}, 'trace-2')

	assert outcome.kind == .relay_delivery
	assert outcome.target == 'relay:feishu-card:server'
	assert outcome.metadata['relay_protocol'] == 'feishu_card_bridge'
	assert outcome.metadata['relay_carrier'] == 'websocket'
	assert outcome.metadata['relay_direction'] == 'proxy'
	assert outcome.metadata['request_id'] == 'bridge-proxy-1'
	assert outcome.metadata['action'] == 'send'
	assert outcome.metadata['trace_id'] == 'trace-2'
	assert outcome.metadata['provider'] == 'feishu'
	assert outcome.metadata['instance'] == 'main'
	assert outcome.metadata['target'] == 'chat_2'
	assert outcome.metadata['target_type'] == 'chat_id'
	assert outcome.metadata['message_type'] == 'text'
	assert outcome.metadata['stream_id'] == 'stream-1'
}

fn test_feishu_card_bridge_server_session_delivery_outcome_projects_session() {
	outcome := feishu_card_bridge_server_session_delivery_outcome('local-main', 'req-1',
		'trace-1')

	assert outcome.kind == .session_plan
	assert outcome.status == 101
	assert outcome.target == 'relay:feishu-card:local-main'
	assert outcome.headers['upgrade'] == 'websocket'
	assert outcome.metadata['response_mode'] == 'relay'
	assert outcome.metadata['relay_protocol'] == 'feishu_card_bridge'
	assert outcome.metadata['relay_carrier'] == 'websocket'
	assert outcome.metadata['relay_direction'] == 'server_session'
	assert outcome.metadata['relay_client_id'] == 'local-main'
	assert outcome.metadata['request_id'] == 'req-1'
	assert outcome.metadata['trace_id'] == 'trace-1'
	assert outcome.metadata['session_protocol'] == 'websocket'
	assert outcome.metadata['session_transport'] == 'websocket'
}
