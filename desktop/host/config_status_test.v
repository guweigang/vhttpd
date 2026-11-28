module host

fn test_status_requires_matching_project_and_complete_preview() ! {
	path := '/tmp/project/vhttpd.toml'
	good := '{"config_path":"${path}","allowed":true,"strategy":"lightweight","actions":[]}'
	assert decode_config_status(good, path)!.state == .effective
	for invalid in ['{}', 'null', '{"allowed":true}', good.replace(path, '/tmp/other.toml'), good.replace('true', '"true"'), good.replace('[]', '{}')] {
		decode_config_status(invalid, path) or { continue }
		assert false, 'Incomplete or foreign results must not report effective'
	}
}

fn test_status_marks_both_reload_and_lightweight_changes_pending() ! {
	path := '/tmp/project/vhttpd.toml'
	for allowed in ['true', 'false'] {
		status := decode_config_status('{"config_path":"${path}","allowed":${allowed},"strategy":"relay_reload_required","actions":[{}],"reload_relays":["edge"],"changed_pipelines":["relay/in"]}', path)!
		assert status.state == .pending
		assert status.message.contains('edge')
		assert status.message.contains('relay/in')
	}
	assert decode_config_status('{"config_path":"${path}","allowed":false,"strategy":"unsupported","actions":[]}', path)!.state == .pending
}

fn test_failed_check_keeps_last_known_diff() {
	previous := ConfigStatus{fields: [ConfigFieldDiff{kind: 'Relay', component: 'edge', field: 'options.token', before: '[已脱敏]', after: '[已脱敏]'}], state: .pending, pending: true, relays: ['edge'], pipelines: ['receive'], files: [ConfigFileDiff{path: '/project/relay.toml', change: '已修改', editable: true}]}
	failed := failed_config_status(previous)
	assert failed.state == .unavailable
	assert failed.pending
	assert failed.fields == previous.fields
	assert failed.files == previous.files
	assert failed.relays == ['edge']
	assert failed.pipelines == ['receive']
}
