module config

import os
import rand

fn test_relay_fragments_merge_disjoint_fields_and_reject_duplicates_even_defaults() ! {
	root := os.join_path(os.temp_dir(), 'vhttpd-relay-fragments-' + rand.hex(8))
	os.mkdir_all(root)!
	defer { os.rmdir_all(root) or {} }
	main := os.join_path(root, 'vhttpd.toml')
	fragment := os.join_path(root, 'fragment.toml')
	text := 'version=2\ninclude=["fragment.toml"]\n[relays.edge]\nmode="agent"\ncarrier="websocket"\nurl="ws://localhost:19921/relay"\nautostart=false\n'
	os.write_file(main, text)!
	os.write_file(fragment, '[relays.edge]\nnode_id="split"\nmax_channels=16\n')!
	plan := load_runtime_plan_file(main)!
	assert plan.relays['edge'].mode == 'agent'
	assert !plan.relays['edge'].options.bools['autostart']
	assert plan.relays['edge'].options.strings['node_id'] == 'split'
	assert plan.relays['edge'].options.ints['max_channels'] == 16
	assert runtime_config_sources(main)!.len == 2
	for duplicate in ['autostart=false', 'mode="agent"', 'url="different"'] {
		if _ := load_runtime_plan_with_overrides(main, {fragment: '[relays.edge]\n' + duplicate + '\n'}) { assert false, 'duplicate field accepted' }
	}
	// Defaults in a partial fragment must not overwrite explicit values.
	assert load_runtime_plan_text(text, main)!.relays['edge'].options.strings['node_id'] == 'split'
	assert os.read_file(main)! == text
}
