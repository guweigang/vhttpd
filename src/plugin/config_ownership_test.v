module plugin

import config
import os

fn test_plugin_publication_owns_signature_arrays_and_preserves_unchanged_executor() {
	mut includes := ['*.mts']
	mut excludes := ['cache/**']
	entry := os.join_path(@VMODROOT, 'examples/vjsx/hello-handler.mts')
	original := {
		'test': config.PluginConfig{ app_entry: entry, signature_include: includes, signature_exclude: excludes }
	}
	mut owner := PluginState{}
	defer { owner.close() }
	assert owner.publish(original) == 0
	first := owner.lookup('test') or { panic(err) }
	includes[0] = '*.changed'
	excludes[0] = 'changed/**'
	assert owner.configs['test'].signature_include == ['*.mts']
	assert owner.configs['test'].signature_exclude == ['cache/**']
	assert owner.publish({
		'test': config.PluginConfig{ app_entry: entry, signature_include: ['*.mts'], signature_exclude: ['cache/**'] }
	}) == 0
	current := owner.lookup('test') or { panic(err) }
	assert voidptr(first.state) == voidptr(current.state)
}
