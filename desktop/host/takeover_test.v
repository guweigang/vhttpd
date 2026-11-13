module host

import config
import os

fn test_takeover_receiver_is_reviewable_and_does_not_change_database_binding() ! {
	dir := os.join_path(os.temp_dir(), 'takeover-desktop-' + os.getpid().str())
	os.mkdir_all(dir)!
	defer { os.rmdir_all(dir) or {} }
	root := os.join_path(dir, 'vhttpd.toml')
	original := 'version=2\n[resources.db.app]\nkind="mysql"\noptions.relay="relay:database"\noptions.route="resource/database"\noptions.remote_resource="db/app"\n[relays.database]\nmode="agent"\nurl="ws://127.0.0.1:12345/relay"\ntoken="fixture"\n[engines.app]\nkind="vjsx"\nentry="app.mts"\n'
	os.write_file(root, original)!
	bundle := takeover_receiver_changeset(root, 'database')!
	assert bundle.files.len == 1
	assert os.read_file(root)! == original
	plan := config.load_runtime_plan_with_overrides(root, {
		root: bundle.files[0].value
	})!
	assert plan.adapters['local_debug'].kind == 'debug-http'
	assert plan.resources['db/app'].options.strings['relay'] == 'relay:database'
	assert plan.pipelines.any(it.id == 'debug/http' && it.ingress.str() == 'relay:database')
 configured := bundle.files[0].value + '\n[engines.other]\nkind="vjsx"\nentry="other.mts"\n'
 os.write_file(root,configured)!
 repointed := takeover_receiver_for_engine(root,'database','other')!
 assert os.read_file(root)! == configured
 switched := config.load_runtime_plan_with_overrides(root,{root:repointed.files[0].value})!
 assert switched.adapters['local_debug'].engine?.id == 'other'
 assert switched.resources['db/app'].options.strings['relay'] == 'relay:database'

}
