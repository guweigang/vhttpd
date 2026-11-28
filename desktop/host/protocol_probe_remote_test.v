module host

import crypto.rand
import encoding.base64
import json2 as json
import os
import time

fn test_remote_probe_full_configuration_script_fits_stdin_and_executes() ! {
	root := os.join_path(os.temp_dir(), 'probe-script-${os.getpid()}-${time.ticks()}')
	os.mkdir_all(root)!
	defer { os.rmdir_all(root) or {} }
	path := root + '/vhttpd.toml'
	text := 'version=2\n[listeners.web]\nprotocol="http"\nhost="::1"\nport=12345\n[adapters.auth]\noptions.probe_bearer_token="private-script-fixture"\n[[pipelines]]\ningress="listener:web"\negress="adapter:auth"\n'
	os.write_file(path, text)!
	script := remote_protocol_probe_script(path, {path: text}, ProtocolProbeArgs{}, true)!
	assert script.len <= 16000
	assert !script.contains('private-script-fixture')
	result := os.execute(script)
	assert result.exit_code == 0
	value := json.decode[map[string]json.Any](result.output)!
	assert value['source']!.str() == 'remote_configuration'
	assert value['listeners']!.as_array().len == 1
	assert result.output.contains('"auth_refs": ["auth"]')
	assert !result.output.contains('private-script-fixture')
	// Large, incompressible source data must fail before invoking SSH.
	noise := base64.encode(rand.bytes(30000)!)
	if _ := remote_protocol_probe_script(path, {path: text + '\n#' + noise}, ProtocolProbeArgs{}, true) {
		return error('oversized SSH script accepted')
	}
}

fn test_remote_result_masks_known_config_and_profile_secrets_without_local_expansion() ! {
    sources := {'/remote/app.toml': '[control]\ntoken="private-control-value"\n[adapters.auth]\noptions.probe_bearer_token="' + '$' + '{env.HOME}"\n'}
    result := json.Any({'protocol': json.Any('stream'), 'result': json.Any({'sample': json.Any('private-control-value profile-private-value valid-business-body')})})
    value := remote_protocol_probe_safe_result(result, sources, 'profile-private-value')!
    assert !value.contains('private-control-value')
    assert !value.contains('profile-private-value')
    assert value.contains('valid-business-body')
    assert value.contains('"protocol":"stream"')
}
