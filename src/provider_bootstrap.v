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
			mut feishu_ctx := app.build_provider_context('feishu')
			provider_register_and_start(mut app, 'feishu', mut p, mut feishu_ctx)
			app.register_provider_spec(ProviderSpec{
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
					ctx:      feishu_ctx
				}
				lifecycle_ctx:    feishu_ctx
			})
		}
	}

	// Codex
	$if !no_codex_routes ? {
		if app.provider_bootstrap_enabled('codex') {
			mut p := CodexProvider{}
			h := CodexCommandHandler.new(mut app)
			mut codex_ctx := app.build_provider_context('codex')
			provider_register_and_start(mut app, 'codex', mut p, mut codex_ctx)
			app.register_provider_spec(ProviderSpec{
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
					ctx:      codex_ctx
				}
				lifecycle_ctx:    codex_ctx
			})
		}
	}

	// Database upstream (runtime skeleton)
	if app.provider_bootstrap_enabled('db') {
		mut p := DbProvider{}
		mut db_ctx := app.build_provider_context('db')
		provider_register_and_start(mut app, 'db', mut p, mut db_ctx)
		app.register_provider_spec(ProviderSpec{
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
				ctx:      db_ctx
			}
			lifecycle_ctx:    db_ctx
		})
	}

	// Ollama (currently skeleton adapter)
	$if !no_ollama_routes ? {
		if app.provider_bootstrap_enabled('ollama') {
			mut p := OllamaProvider{}
			h := GenericUpstreamCommandHandler.new(mut app)
			mut ollama_ctx := app.build_provider_context('ollama')
			provider_register_and_start(mut app, 'ollama', mut p, mut ollama_ctx)
			app.register_provider_spec(ProviderSpec{
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
					ctx:      ollama_ctx
				}
				lifecycle_ctx:    ollama_ctx
			})
		}
	}
}

fn provider_register_and_start(mut app App, name string, mut p Provider, mut ctx provider.RuntimeContext) {
	app.register_provider(name, p)
	p.init(mut ctx) or {
		app.emit('provider.init_failed', {
			'name':  name
			'error': err.msg()
		})
		return
	}
	p.start(mut ctx) or {
		app.emit('provider.start_failed', {
			'name':  name
			'error': err.msg()
		})
	}
}
