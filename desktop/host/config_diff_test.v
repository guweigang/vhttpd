module host

import os
import time

fn test_diff_tracks_nested_sources_added_removed_and_reverted_without_secret_values() ! {
	dir := os.join_path(os.temp_dir(), 'config-diff-${os.getpid()}-${time.now().unix_micro()}')
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	root := os.join_path(dir, 'vhttpd.toml')
	relay := os.join_path(dir, 'relay.toml')
	routes := os.join_path(dir, 'routes.toml')
	os.write_file(root, 'version=2\ninclude=["relay.toml"]\n')!
	before_text := 'include=["routes.toml"]\n[relays.edge]\nmode="agent"\nnode_id="before"\ntoken="a-private-value"\n'
	os.write_file(relay, before_text)!
	os.write_file(routes, '[[pipelines]]\nid="relay/in"\ningress="relay:edge"\negress="adapter:reply"\n')!
	before := config_revisions(root)!
	os.write_file(relay, before_text.replace('before', 'after'))!
	changed := config_file_diffs(before, config_revisions(root)!)
	assert changed.len == 1
	assert changed[0].path == relay
	assert changed[0].relays == ['edge']
	assert changed[0].editable
	assert !changed.str().contains('a-private-value')
	os.write_file(relay, before_text)!
	assert config_file_diffs(before, config_revisions(root)!).len == 0
	os.write_file(root, 'version=2\ninclude=["new.toml"]\n')!
	os.write_file(os.join_path(dir, 'new.toml'), '[relays.new]\nmode="agent"\n')!
	changed_tree := config_file_diffs(before, config_revisions(root)!)
	assert changed_tree.len == 4
	removed := changed_tree.filter(it.path == routes)
	assert removed[0].change == '移出项目'
	assert removed[0].pipelines == ['relay/in']
	assert !removed[0].editable
	added := changed_tree.filter(it.path.ends_with('new.toml'))
	assert added[0].change == '新加入'
	assert added[0].relays == ['new']
}
