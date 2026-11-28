module config

import toml

fn relay_database_plan_text() string {
	return 'version=2\n[resources.db.app]\nkind="mysql"\noptions.relay="relay:database"\noptions.route="resource/database"\noptions.remote_resource="db/app"\n[relays.database]\nmode="agent"\ncarrier="websocket"\nurl="ws://127.0.0.1:8080/relay"\ntoken="test"\n'
}

fn test_relay_database_binding_requires_authenticated_agent_and_no_local_credentials() ! {
	text := relay_database_plan_text()
	compile_v2_runtime_plan(toml.parse_text(text)!.reflect[V2Config](), '/tmp/relay-db.toml', false)!
	for invalid in [text.replace('mode="agent"', 'mode="hub"'), text.replace('token="test"', 'token=""'), text.replace('kind="mysql"', 'kind="mysql"\npassword="local-secret"'), text.replace('relay:database', 'relay:missing')] {
		compile_v2_runtime_plan(toml.parse_text(invalid)!.reflect[V2Config](), '/tmp/relay-db.toml', false) or { continue }
		assert false, 'Unsafe remote database binding accepted'
	}
}

fn test_database_export_rejects_public_listener_ingress() ! {
	text := 'version=2\n[listeners.web]\nprotocol="http"\n[resources.db.app]\nkind="mysql"\n[adapters.db]\nkind="db-resource"\noptions.resource="db/app"\n[[pipelines]]\nid="export"\ningress="listener:web"\negress="adapter:db"\n'
	compile_v2_runtime_plan(toml.parse_text(text)!.reflect[V2Config](), '/tmp/relay-db.toml', false) or {
		assert err.msg().contains('relay_db_requires_relay_ingress')
		return
	}
	assert false
}
