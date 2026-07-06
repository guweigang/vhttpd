module main

fn test_admin_schema_catalog_exposes_core_domains() {
	catalog := admin_schema_catalog()
	domains := catalog.domains.map(it.id)
	assert domains.contains('listeners')
	assert domains.contains('resources')
	assert domains.contains('engines')
	assert domains.contains('adapters')
	assert domains.contains('transforms')
	assert domains.contains('pipelines')
	assert domains.contains('relays')
}

fn test_admin_schema_kind_lookup_exposes_adapter_fields() {
	relay := admin_schema_kind('adapters', 'relay-delivery') or { panic('missing relay adapter schema') }
	fields := relay.fields.map(it.name)
	assert fields.contains('kind')
	assert fields.contains('options.target')
	assert fields.contains('options.route')
	assert fields.contains('options.completion_mode')

	target := relay.fields.filter(it.name == 'options.target')[0]
	assert target.required
	assert target.ref_domain == 'relay'
}

fn test_admin_schema_provider_runtime_hooks_are_editable() {
	provider := admin_schema_kind('providers', 'runtime') or { panic('missing provider schema') }
	fields := provider.fields.map(it.name)
	assert fields.contains('runtime.protocol')
	assert fields.contains('runtime.plugin')
	assert fields.contains('runtime.engine')
	assert fields.contains('hooks')
}
