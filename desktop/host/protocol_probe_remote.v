module host

import compress.zlib
import crypto.sha256
import toml
import encoding.base64
import json2 as json

// Retain the SSH stdin bound. Neither scripts nor credentials become arguments
// or remote files; only this embedded implementation is executed.
fn remote_protocol_probe_script(path string, sources map[string]string, args ProtocolProbeArgs, options_only bool) !string {
	payload := json.encode({'config_path': json.Any(path), 'sources': json.decode[json.Any](json.encode(sources))!, 'args': json.decode[json.Any](json.encode(args))!, 'options_only': json.Any(options_only)})
	code := "import base64,json\nq=json.loads(base64.b64decode('" + base64.encode(payload.bytes()) + "'))\n" + $embed_file('remote_scripts/protocol_probe_config.py').to_string() + "\n" + $embed_file('remote_scripts/protocol_probe.py').to_string()
	packed := base64.encode(zlib.compress(code.bytes())!)
	script := "python3 - <<'VHTTPD_PROTOCOL_PROBE'\nimport base64,zlib\nexec(zlib.decompress(base64.b64decode('" + packed + "')))\nVHTTPD_PROTOCOL_PROBE\n"
	if script.len > 16000 { return error('remote_probe_configuration_too_large') }
	return script
}


// Preserve the existing known-configuration credential mask without compiling
// remote sources against the Desktop environment. Resolved probe credentials
// have already been masked on the owning host.
fn remote_protocol_probe_safe_result(value json.Any, sources map[string]string, target_token string) !string {
    mut secrets := [target_token]
    for _, text in sources {
        doc := toml.parse_text(text) or { return error('remote_probe_redaction_context_unavailable') }
        raw := json.decode[json.Any](json.encode(doc.to_any())) or { return error('remote_probe_redaction_context_unavailable') }
        development_collect_secrets(raw, false, mut secrets)
    }
    mut safe := DevelopmentState{}
    for secret in secrets {
        if secret != '' { safe.secrets['<vhttpd-secret-' + sha256.hexhash(secret)[..16] + '>'] = secret }
    }
    return json.encode(safe.safe_json(value))
}
