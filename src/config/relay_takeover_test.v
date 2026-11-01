module config

import toml

fn takeover_plan_text(kind string, mode string) string {
	return 'version=2\n[engines.app]\nkind="vjsx"\nentry="app.mts"\n[relays.debug]\nmode="${mode}"\ncarrier="websocket"\nurl="ws://127.0.0.1:12345/relay"\ntoken="fixture"\n[adapters.debug]\nkind="${kind}"\nengine="engine:app"\noptions.route="debug/http"\n[[pipelines]]\nid="${if kind == 'debug-http' {
		'debug/http'
	} else {
		'debug/control'
	}}"\ningress="relay:debug"\negress="adapter:debug"\n'
}

fn test_takeover_rejects_public_or_unauthenticated_ingress_and_wrong_role() ! {
	for kind, mode in {
		'debug-http':    'agent'
		'debug-control': 'hub'
	} {
		text := takeover_plan_text(kind, mode)
		compile_v2_runtime_plan(toml.parse_text(text)!.reflect[V2Config](), '/tmp/takeover.toml', false)!
		for invalid in [text.replace('token="fixture"', 'token=""'),
			text.replace('mode="${mode}"', 'mode="${if mode == 'hub' { 'agent' } else { 'hub' }}"'),
			text.replace('ingress="relay:debug"', 'ingress="listener:web"') + '\n[listeners.web]\nprotocol="http"\n',
			text.replace('options.route="debug/http"', 'options.route="arbitrary"').replace('id="debug/http"', 'id="arbitrary"')] {
			mut rejected := false
			compile_v2_runtime_plan(toml.parse_text(invalid)!.reflect[V2Config](), '/tmp/takeover.toml', false) or { rejected = true }
			assert rejected, 'Unsafe takeover route accepted'
		}
	}
}
