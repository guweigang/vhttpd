module devmcp

fn protocol_probe_properties() string {
	return '{"auth_ref":{"type":"string","maxLength":256,"description":"Business adapter ID whose options.probe_bearer_token is used privately; omit for no authentication."},"tls_trust":{"type":"string","enum":["system","listener_certificate"],"description":"Mandatory chain/name verification; explicit listener_certificate trusts its configured public certificate only."},"tls_server_name":{"type":"string","maxLength":253,"description":"Certificate identity/SNI only; connection remains configured loopback."},"listener":{"type":"string"},"path":{"type":"string","maxLength":2048},"protocol":{"type":"string","enum":["stream","websocket","mcp"]},"message":{"type":"string","maxLength":4096},"timeout_ms":{"type":"integer","minimum":100,"maximum":5000},"max_items":{"type":"integer","minimum":1,"maximum":8}}'
}
