module main

import provider

// Provider bootstrap is intentionally isolated from transport/runtime startup
// to keep HTTP/WebSocket/stream + workerpool orchestration independent from
// application-level adapters.

fn (mut app App) bootstrap_providers() {
	// Feishu
	$if !no_feishu_routes ? {
		if app.provider_bootstrap_enabled('feishu') {
			mut p := FeishuProvider{}
			h := FeishuCommandHandler.new(mut app)
			mut spec := ProviderSpec{
				name:             'feishu'
				enabled:          true
				has_handler:      true
				has_runtime:      true
				runtime_driver:   app.providers.provider_runtime_driver('feishu')
				command_matchers: [
					provider.CommandMatcher{
						kind:  provider.CommandMatcherKind.prefix
						value: 'feishu.message.'
					},
				]
				route_kind:       provider.ProviderRouteKind.feishu
				provider:         p
				handler:          h
				runtime:          ProviderRuntimeAdapter{
					provider: p
				}
				lifecycle_ctx:    app.build_provider_context('feishu')
			}
			app.register_and_start_provider(mut spec)
		}
	}

	// Codex
	$if !no_codex_routes ? {
		if app.provider_bootstrap_enabled('codex') {
			mut p := CodexProvider{}
			h := CodexCommandHandler.new(mut app)
			mut spec := ProviderSpec{
				name:             'codex'
				enabled:          true
				has_handler:      true
				has_runtime:      true
				runtime_driver:   app.providers.provider_runtime_driver('codex')
				command_matchers: [
					provider.CommandMatcher{
						kind:  provider.CommandMatcherKind.prefix
						value: 'codex.'
					},
				]
				route_kind:       provider.ProviderRouteKind.codex
				provider:         p
				handler:          h
				runtime:          ProviderRuntimeAdapter{
					provider: p
				}
				lifecycle_ctx:    app.build_provider_context('codex')
			}
			app.register_and_start_provider(mut spec)
		}
	}

	// Database upstream (runtime skeleton)
	if app.provider_bootstrap_enabled('db') {
		mut p := DbProvider{}
		mut spec := ProviderSpec{
			name:             'db'
			enabled:          true
			has_handler:      false
			has_runtime:      true
			runtime_driver:   app.providers.provider_runtime_driver('db')
			command_matchers: []provider.CommandMatcher{}
			route_kind:       provider.ProviderRouteKind.generic
			provider:         p
			handler:          provider.NoopProviderCommandHandler{}
			runtime:          ProviderRuntimeAdapter{
				provider: p
			}
			lifecycle_ctx:    app.build_provider_context('db')
		}
		app.register_and_start_provider(mut spec)
	}

	// Ollama (currently skeleton adapter)
	$if !no_ollama_routes ? {
		if app.provider_bootstrap_enabled('ollama') {
			mut p := OllamaProvider{}
			h := GenericUpstreamCommandHandler.new(mut app)
			mut spec := ProviderSpec{
				name:             'ollama'
				enabled:          true
				has_handler:      true
				has_runtime:      true
				runtime_driver:   app.providers.provider_runtime_driver('ollama')
				command_matchers: [
					provider.CommandMatcher{
						kind:  provider.CommandMatcherKind.prefix
						value: 'ollama.message.'
					},
				]
				route_kind:       provider.ProviderRouteKind.ollama
				provider:         p
				handler:          h
				runtime:          ProviderRuntimeAdapter{
					provider: p
				}
				lifecycle_ctx:    app.build_provider_context('ollama')
			}
			app.register_and_start_provider(mut spec)
		}
	}
}

// Register before init so callbacks can find the complete spec. Publish any
// context/provider mutations after init and on every exit, including failures.
fn (mut app App) register_and_start_provider(mut spec ProviderSpec) {
	app.register_provider_spec(spec)
	defer { app.register_provider_spec(spec) }
	spec.provider.init(mut spec.lifecycle_ctx) or {
		app.emit('provider.init_failed', {
			'name':  spec.name
			'error': err.msg()
		})
		return
	}
	app.register_provider_spec(spec)
	spec.start_runtime() or {
		app.emit('provider.start_failed', {
			'name':  spec.name
			'error': err.msg()
		})
	}
}
