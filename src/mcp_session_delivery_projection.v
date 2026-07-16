module main

import api.mcp.protocol as mcp_protocol
import dispatch

fn mcp_session_delivery_outcome(session_id string, protocol_version string) dispatch.DeliveryOutcome {
	resolved_protocol_version := if protocol_version != '' {
		protocol_version
	} else {
		mcp_protocol.Session.default_protocol_version()
	}
	return dispatch.session_plan_outcome_with_status(200, 'mcp:${session_id}', {
		'content-type':          'text/event-stream'
		'x-accel-buffering':     'no'
		'mcp-session-id':        session_id
		'mcp-protocol-version':  resolved_protocol_version
	}, {
		'response_mode':         'mcp'
		'session_protocol':      'mcp'
		'session_transport':     'sse'
		'mcp_session_id':        session_id
		'mcp_protocol_version':  resolved_protocol_version
	})
}
