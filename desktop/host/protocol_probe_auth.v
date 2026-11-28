module host

import encoding.base64
import os

// Credentials are selected from a routed adapter, never supplied by MCP callers.
fn protocol_probe_auth_kind(options map[string]string) string {
	return options['probe_auth_kind'] or { 'bearer' }
}

fn protocol_probe_auth_header(options map[string]string) !string {
	kind := protocol_probe_auth_kind(options)
	if kind == 'mtls' {
        for key in ['probe_client_cert', 'probe_client_key'] {
            value := options[key]
            if value == '' || value.len > 4096 || !os.is_abs_path(value) || value.bytes().any(it < 32 || it == 127) { return error('probe_client_certificate_unavailable') }
        }
        return ''
    }
    if kind in ['basic', 'digest'] {
		user := options[if kind == 'digest' { 'probe_digest_username' } else { 'probe_basic_username' }]
		password := options[if kind == 'digest' { 'probe_digest_password' } else { 'probe_basic_password' }]
		if user == '' || password == '' || user.contains(':') || user.len + password.len > 4096
			|| (user + password).bytes().any(it < 32 || it == 127) {
			return error('probe_basic_credential_unavailable')
		}
		if kind == 'digest' {
            if (user + password).bytes().any(it > 126) { return error('probe_digest_ascii_credentials_required') }
            return ''
        }
        return 'Authorization: Basic ' + base64.encode((user + ':' + password).bytes()) + '\r\n'
	}
	key := if kind == 'bearer' { 'probe_bearer_token' } else if kind == 'api_key' { 'probe_api_key' } else { return error('unsupported_probe_auth_kind') }
	value := options[key]
	if value == '' || value.len > 4096 || value.bytes().any(it <= 32 || it >= 127) {
		return error('probe_credential_unavailable')
	}
	return if kind == 'bearer' { 'Authorization: Bearer ' + value + '\r\n' } else { 'X-API-Key: ' + value + '\r\n' }
}

fn protocol_probe_auth_available(options map[string]string) bool {
	protocol_probe_auth_header(options) or { return false }
	return true
}

fn protocol_probe_header_secrets(header string) []string {
	if header == '' { return []string{} }
	value := header.all_after(': ').trim_space()
	mut secrets := [value]
	if value.starts_with('Bearer ') { secrets << value.all_after('Bearer ') }
	if value.starts_with('Basic ') {
		encoded := value.all_after('Basic ')
		decoded := base64.decode_str(encoded)
		secrets << encoded
		secrets << decoded
		secrets << decoded.all_before(':')
		secrets << decoded.all_after(':')
	}
    if value.starts_with('Digest ') {
        fields := probe_digest_fields(value) or { return secrets }
        for key in ['username', 'response', 'nonce', 'cnonce'] { if fields[key] != '' { secrets << fields[key] } }
    }
	return secrets
}
