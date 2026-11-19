module app_meta

import os
import rand
import json2 as json

fn test_manifest_identity_survives_rename_move_and_reinitialize() ! {
	root := os.join_path(os.real_path(os.temp_dir()), 'app-meta-' + rand.uuid_v4())
	os.mkdir(root)!
	defer { os.rmdir_all(root) or {} }
	first := initialize(root, 'bodytest', 'component.toml')!
	assert valid_id(first.id)
	assert initialize(root, 'other-name', 'other.toml')!.id == first.id
	renamed := Manifest{ ...first, name: 'renamed', display_name: '体测智能助手', version: '1.2.0-beta.1' }
	os.write_file(root + '/app.json', json.encode(renamed))!
	assert read(root)!.id == first.id
	os.write_file(root + '/app.json', '{}')!
	mut rejected := false
	initialize(root, 'replacement', 'component.toml') or { rejected = true }
	assert rejected
	assert os.read_file(root + '/app.json')! == '{}'
}

fn test_manifest_rejects_secrets_unknown_schema_and_escaping_paths() {
	m := Manifest{ id: rand.uuid_v4(), name: 'bodytest', version: '1.0.0' }
	for text in [json.encode(m).replace('"schema_version":1', '"schema_version":2'),
        json.encode(m).replace('"schema_version":1', '"schema_version":1.2'),
        json.encode(m).replace('"schema_version":1', '"schema_version":"1"'),
		json.encode(Manifest{ ...m, entry: '../component.toml' }),
		json.encode(Manifest{ ...m, homepage: 'https://secret@example.com' }),
		json.encode(Manifest{ ...m, id: 'bodytest' }),
		json.encode(Manifest{ ...m, version: 'not-a-version' }),
		json.encode(m).trim_right('}') + ',"password":"forbidden"}'] {
		mut rejected := false
		parse(text) or { rejected = true }
		assert rejected, text
	}
}
