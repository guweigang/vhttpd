module main

import api.mcp.protocol as mcp_protocol
import upstream.transport

// HTTP and relay responses publish only to the session owned by this request's
// captured route. An executor-supplied ID cannot redirect an existing session.
fn McpRuntime.complete_dispatch_session(mut owner mcp_protocol.McpState, req transport.WorkerMcpDispatchRequest, resp transport.WorkerMcpDispatchResponse, route &mcp_protocol.SessionDispatch) !string {
	mut id := if req.session_id != '' { req.session_id } else { resp.session_id }
	initializing := req.body.contains('"method":"initialize"') || req.body.contains('"method": "initialize"')
	if id == '' && initializing { id = mcp_protocol.Session.generate_id() }
	if id == '' { return '' }
	session := owner.complete_dispatch_session(id, if resp.protocol_version != '' {
		resp.protocol_version
	} else {
		req.protocol_version
	}, req.request_id, req.trace_id, '/mcp', route, req.session_id != '')!
	if initializing {
		capabilities := mcp_protocol.Session.extract_client_capabilities_json(req.body)
		if capabilities != '' { owner.set_dispatch_capabilities(session.id, route, capabilities) }
	}
	return session.id
}
