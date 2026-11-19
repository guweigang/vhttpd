module devmcp

import host
import json2 as json
import mcp
import net.http

fn test_initial_catalog_covers_all_authorized_tools_without_client_pagination() ! {
	mut protocol := mcp.new_server(name: 'catalog-test', version: '1')
	for i in 0 .. 121 {
		protocol.add_tool(mcp.Tool{name: 'tool_${i:03}', description: 'test', input_schema: '{"type":"object"}'}, fn (_ mcp.Context, _ string) !mcp.ToolResult { return mcp.ToolResult{content: '[]'} })!
	}
	mut grant := host.new_development_grant(0)
	mut gateway := Gateway{token: 'private-test-token', protocol: &protocol, grant: grant}
	mut headers := http.new_header_from_map({.authorization: 'Bearer private-test-token', .content_type: 'application/json', .accept: 'application/json, text/event-stream'})
	init := gateway.handle(http.Request{method: .post, url: '/mcp', header: headers, data: '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"first-page-only","version":"1"}}}'})
	assert init.status_code == 200, init.body
	session := init.header.get_custom('Mcp-Session-Id') or { panic('missing MCP session header') }
	headers.add_custom('Mcp-Session-Id', session) or { panic(err) }
	ack := gateway.handle(http.Request{method: .post, url: '/mcp', header: headers, data: '{"jsonrpc":"2.0","method":"notifications/initialized"}'})
	assert ack.status_code in [200, 202, 204]
	request := http.Request{method: .post, url: '/mcp', header: headers, data: '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'}
	response := gateway.handle(request)
	assert response.status_code == 200, response.body
	value := json.decode[map[string]json.Any](response.body)!
	result := value['result']!.as_map()
	assert result['tools']!.as_array().len == 121
	assert 'nextCursor' !in result
	length := response.header.get(.content_length) or { panic('missing content length') }
	assert length == response.body.len.str()
	page := gateway.handle(http.Request{...request, data: '{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{"cursor":"50"}}'})
	paged := json.decode[map[string]json.Any](page.body)!
	assert paged['result']!.as_map()['tools']!.as_array().len == 50
	mut denied := headers
	denied.set(.authorization, 'Bearer wrong')
	assert gateway.handle(http.Request{...request, header: denied}).status_code == 401
	grant.revoke()
	assert gateway.handle(request).status_code == 410
}
