module main

import dispatch
import executor
import upstream.transport

fn worker_websocket_session_delivery_outcome(open executor.WebSocketSessionOpenOutcome, req_id string, path string) dispatch.DeliveryOutcome {
	mut metadata := {
		'response_mode':      'websocket'
		'session_protocol':   'websocket'
		'session_transport':  'websocket'
		'websocket_backend':  'worker'
		'websocket_conn_id':  req_id
		'websocket_path':     path
	}
	if open.socket_path != '' {
		metadata['worker_socket'] = open.socket_path
	}
	status := if open.status > 0 { open.status } else { 101 }
	return dispatch.session_plan_outcome_with_status(status, 'websocket:${req_id}', {
		'upgrade': 'websocket'
	}, metadata)
}

fn dispatch_websocket_session_delivery_outcome(resp transport.WorkerWebSocketDispatchResponse, req_id string, path string) dispatch.DeliveryOutcome {
	mut metadata := {
		'response_mode':      'websocket'
		'session_protocol':   'websocket'
		'session_transport':  'websocket'
		'websocket_backend':  'dispatch'
		'websocket_conn_id':  req_id
		'websocket_path':     path
		'command_count':      '${resp.commands.len}'
	}
	if resp.affinity_key != '' {
		metadata['affinity_key'] = resp.affinity_key
	}
	return dispatch.session_plan_outcome_with_status(101, 'websocket:${req_id}', {
		'upgrade': 'websocket'
	}, metadata)
}
