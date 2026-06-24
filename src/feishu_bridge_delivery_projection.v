module main

import dispatch
import feishu

fn feishu_card_bridge_dispatch_delivery_outcome(client_id string, frame feishu.BridgeDispatchRequest) dispatch.DeliveryOutcome {
	mut metadata := frame.metadata.clone()
	metadata['relay_protocol'] = 'feishu_card_bridge'
	metadata['relay_carrier'] = 'websocket'
	metadata['relay_direction'] = 'dispatch'
	metadata['relay_client_id'] = client_id
	metadata['request_id'] = frame.request_id
	metadata['trace_id'] = frame.trace_id
	if frame.app != '' {
		metadata['app'] = frame.app
	}
	if frame.event_type != '' {
		metadata['event_type'] = frame.event_type
	}
	if frame.message_id != '' {
		metadata['message_id'] = frame.message_id
	}
	if frame.target != '' {
		metadata['target'] = frame.target
	}
	if frame.target_type != '' {
		metadata['target_type'] = frame.target_type
	}
	return dispatch.relay_delivery_outcome(feishu_card_bridge_client_target(client_id), metadata)
}

fn feishu_card_bridge_proxy_delivery_outcome(frame feishu.BridgeProxyRequest, trace_id string) dispatch.DeliveryOutcome {
	req := frame.request
	mut metadata := req.metadata.clone()
	metadata['relay_protocol'] = 'feishu_card_bridge'
	metadata['relay_carrier'] = 'websocket'
	metadata['relay_direction'] = 'proxy'
	metadata['request_id'] = frame.request_id
	metadata['action'] = frame.action
	if trace_id != '' {
		metadata['trace_id'] = trace_id
	}
	if req.provider != '' {
		metadata['provider'] = req.provider
	}
	if req.instance != '' {
		metadata['instance'] = req.instance
	}
	if req.target != '' {
		metadata['target'] = req.target
	}
	if req.target_type != '' {
		metadata['target_type'] = req.target_type
	}
	if req.message_type != '' {
		metadata['message_type'] = req.message_type
	}
	return dispatch.relay_delivery_outcome('relay:feishu-card:server', metadata)
}

fn feishu_card_bridge_client_target(client_id string) string {
	if client_id != '' {
		return 'relay:feishu-card:${client_id}'
	}
	return 'relay:feishu-card:client'
}
