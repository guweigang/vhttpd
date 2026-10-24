module executor

import config

fn ownership_config(includes []string, excludes []string, sources []config.WebSocketActorSourceConfig, events []string) VjsxRuntimeFacadeConfig {
	return VjsxRuntimeFacadeConfig{
		signature_include: includes
		signature_exclude: excludes
		websocket_actor:   config.WebSocketActorConfig{ sources: sources, events: events }
	}
}

fn test_executor_owns_constructor_configuration_arrays() {
	mut includes := ['*.mts']
	mut excludes := ['cache/**']
	mut sources := [config.WebSocketActorSourceConfig{ typ: 'header', key: 'x-actor' }]
	mut events := ['message']
	e := new_inproc_vjsx_executor(ownership_config(includes, excludes, sources, events))
	defer { e.close() }
	includes[0] = '*.changed'
	excludes[0] = 'changed/**'
	sources[0].key = 'changed'
	events[0] = 'changed'
	snapshot := e.facade_snapshot()
	assert snapshot.config.signature_include == ['*.mts']
	assert snapshot.config.signature_exclude == ['cache/**']
	assert snapshot.config.websocket_actor.sources[0].key == 'x-actor'
	assert snapshot.config.websocket_actor.events == ['message']
}

fn test_executor_configuration_snapshot_cannot_mutate_owner_or_another_snapshot() {
	e := new_inproc_vjsx_executor(ownership_config(['*.mts'], ['cache/**'], [config.WebSocketActorSourceConfig{ key: 'x-actor' }], ['message']))
	defer { e.close() }
	snapshot := e.facade_snapshot()
	previous := e.facade_snapshot()
	mut includes := config_ownership_strings(snapshot.config.signature_include)
	mut excludes := config_ownership_strings(snapshot.config.signature_exclude)
	mut sources := config_ownership_sources(snapshot.config.websocket_actor.sources)
	mut events := config_ownership_strings(snapshot.config.websocket_actor.events)
	includes[0] = 'changed'
	excludes[0] = 'changed'
	sources[0].key = 'changed'
	events[0] = 'changed'
	current := e.facade_snapshot()
	assert current.config.signature_include == ['*.mts']
	assert current.config.signature_exclude == ['cache/**']
	assert current.config.websocket_actor.sources[0].key == 'x-actor'
	assert current.config.websocket_actor.events == ['message']
	assert previous.config.signature_include == ['*.mts']
	assert previous.config.websocket_actor.sources[0].key == 'x-actor'
}

// Passing arrays through a value-returning consumer does not clone storage.
fn config_ownership_strings(values []string) []string { return values }

fn config_ownership_sources(values []config.WebSocketActorSourceConfig) []config.WebSocketActorSourceConfig {
	return values
}
