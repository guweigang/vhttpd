module app_bundle

import config
import os

fn test_codexbot_component_installs_into_a_desktop_environment() ! {
	source := os.real_path(os.join_path(os.dir(@FILE), '..', '..', 'examples', 'codexbot-app-ts'))
	payload := collect_component(source, source + '/component.toml', 'c'.repeat(24), 'codexbot')!
	assert payload.files.any(it.path == 'apps/codexbot/config/bot.example.json')
	assert !payload.files.any(it.path.ends_with('/bot.local.json') || it.path.ends_with('.sqlite'))
	assert payload.configs == ['apps/codexbot/component.toml']
	root := os.join_path(os.temp_dir(), 'codexbot_component_${os.getpid()}')
	os.mkdir_all(root)!
	defer { os.rmdir_all(root) or {} }
	os.write_file(root + '/vhttpd.toml', 'version = 2\ninclude = []\n[listeners.admin]\nprotocol="http"\ntransport="tcp"\nhost="127.0.0.1"\nport=29983\n[control]\nlistener="listener:admin"\ntoken="test"\n')!
	composed := compose_component(payload, root + '/vhttpd.toml')!
	materialize(composed, root)!
	plan := config.load_runtime_plan_file(root + '/vhttpd.toml')!
	assert plan.engines['codexbot'].options.strings['entry'] == root + '/apps/codexbot/app.mts'
	assert plan.listener_fallback_engine('codexbot')?.id == 'codexbot'
	assert plan.providers.len == 0
	assert plan.pipelines.any(it.group == 'codexbot')
	assert plan.listeners['admin'].port == 29983
}

fn test_codexbot_private_configuration_is_never_a_bundle_path() {
	assert excluded('bot.local.json')
	assert !safe_path('apps/codexbot/config/bot.local.json')
	assert safe_path('apps/codexbot/config/bot.example.json')
}
