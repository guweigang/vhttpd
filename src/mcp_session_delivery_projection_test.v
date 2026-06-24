module main

import api.mcp.protocol as mcp_protocol

fn test_mcp_session_delivery_outcome_projects_session_headers() {
	outcome := mcp_session_delivery_outcome('sess-1', '2025-06-18')

	assert outcome.kind == .session_plan
	assert outcome.status == 200
	assert outcome.target == 'mcp:sess-1'
	assert outcome.headers['content-type'] == 'text/event-stream'
	assert outcome.headers['x-accel-buffering'] == 'no'
	assert outcome.headers['mcp-session-id'] == 'sess-1'
	assert outcome.headers['mcp-protocol-version'] == '2025-06-18'
	assert outcome.metadata['response_mode'] == 'mcp'
	assert outcome.metadata['session_protocol'] == 'mcp'
	assert outcome.metadata['session_transport'] == 'sse'
	assert outcome.metadata['mcp_session_id'] == 'sess-1'
	assert outcome.metadata['mcp_protocol_version'] == '2025-06-18'
}

fn test_mcp_session_delivery_outcome_uses_default_protocol_version() {
	outcome := mcp_session_delivery_outcome('sess-2', '')

	assert outcome.headers['mcp-protocol-version'] == mcp_protocol.Session.default_protocol_version()
	assert outcome.metadata['mcp_protocol_version'] == mcp_protocol.Session.default_protocol_version()
}
