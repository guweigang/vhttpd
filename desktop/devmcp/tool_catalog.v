module devmcp

import json2 as json
import net.http

// Some native clients discover only the initial tools/list page. Return this
// endpoint's complete, bounded authorized catalog in that response. Each page
// still comes from the official MCP handler, preserving registration and scopes.
// Explicit cursors retain the library's ordinary pagination semantics.
fn (mut h Gateway) complete_tool_catalog(request http.Request, first http.Response) http.Response {
	if request.method != .post || first.status_code != 200 { return first }
	mut rpc := json.decode[map[string]json.Any](request.data) or { return first }
	if (rpc['method'] or { json.Any('') }).str() != 'tools/list' { return first }
	mut params := (rpc['params'] or { json.Any(map[string]json.Any{}) }).as_map()
	if (params['cursor'] or { json.Any('') }).str() != '' { return first }
	mut envelope := json.decode[map[string]json.Any](first.body) or { return first }
	mut result := (envelope['result'] or { return first }).as_map()
	mut cursor := (result['nextCursor'] or { json.Any('') }).str()
	if cursor == '' { return first }
	mut tools := (result['tools'] or { return first }).as_array().clone()
	mut seen := map[string]bool{}
	for _ in 0 .. 8 {
		if !isnil(h.grant) && h.grant.is_revoked() { return http.Response{status_code: 410, body: 'MCP grant expired or revoked'} }
		if seen[cursor] || tools.len > 512 { return incomplete_tool_catalog(envelope) }
		seen[cursor] = true
		params['cursor'] = json.Any(cursor)
		rpc['params'] = json.Any(params)
		page := h.protocol.handle_http_request(http.Request{...request, data: json.encode(rpc)})
		if page.status_code != 200 { return incomplete_tool_catalog(envelope) }
		value := json.decode[map[string]json.Any](page.body) or { return incomplete_tool_catalog(envelope) }
		listed := (value['result'] or { return incomplete_tool_catalog(envelope) }).as_map()
		items := listed['tools'] or { return incomplete_tool_catalog(envelope) }
		if items !is []json.Any { return incomplete_tool_catalog(envelope) }
		tools << items
		cursor = (listed['nextCursor'] or { json.Any('') }).str()
		if cursor == '' {
			if tools.len > 512 { return incomplete_tool_catalog(envelope) }
			result['tools'] = json.Any(tools)
			result.delete('nextCursor')
			envelope['result'] = json.Any(result)
			mut response := first
			response.body = json.encode(envelope)
			response.header.set(.content_length, response.body.len.str())
			return response
		}
	}
	return incomplete_tool_catalog(envelope)
}

fn incomplete_tool_catalog(envelope map[string]json.Any) http.Response {
	return http.Response{status_code: 503, header: http.new_header(key: .content_type, value: 'application/json'), body: json.encode({
		'jsonrpc': json.Any('2.0')
		'id': envelope['id'] or { json.Any('') }
		'error': json.Any({'code': json.Any(-32603), 'message': json.Any('authorized_tool_catalog_incomplete')})
	})}
}
