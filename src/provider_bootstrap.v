module main

// Provider bootstrap is intentionally isolated from transport/runtime startup
// to keep HTTP/WebSocket/stream + workerpool orchestration independent from
// application-level adapters.

fn bootstrap_providers(mut app App) {
	// Feishu
	$if !no_feishu_routes ? {
		if app.provider_bootstrap_enabled('feishu') {
			p := FeishuProvider{}
			h := FeishuCommandHandler.new(mut app)
			provider_register_and_start(mut app, 'feishu', p)
			app.register_provider_spec(ProviderSpec{
				name:        'feishu'
				enabled:     true
				has_handler: true
				has_runtime: true
				command_matchers: [
					CommandMatcher{kind: .prefix, value: 'feishu.message.'},
				]
				route_kind: .feishu
				provider:    p
				handler:     h
				runtime:     ProviderRuntimeAdapter{
					provider: p
				}
			})
		}
	}

	// Codex
	$if !no_codex_routes ? {
		if app.provider_bootstrap_enabled('codex') {
			p := CodexProvider{}
			h := CodexCommandHandler.new(mut app)
			provider_register_and_start(mut app, 'codex', p)
			app.register_provider_spec(ProviderSpec{
				name:        'codex'
				enabled:     true
				has_handler: true
				has_runtime: true
				command_matchers: [
					CommandMatcher{kind: .prefix, value: 'codex.'},
				]
				route_kind: .codex
				provider:    p
				handler:     h
				runtime:     ProviderRuntimeAdapter{
					provider: p
				}
			})
		}
	}

	// Ollama (currently skeleton adapter)
	$if !no_ollama_routes ? {
		if app.provider_bootstrap_enabled('ollama') {
			p := OllamaProvider{}
			h := GenericUpstreamCommandHandler.new(mut app)
			provider_register_and_start(mut app, 'ollama', p)
			app.register_provider_spec(ProviderSpec{
				name:        'ollama'
				enabled:     true
				has_handler: true
				has_runtime: true
				command_matchers: [
					CommandMatcher{kind: .prefix, value: 'ollama.message.'},
				]
				route_kind: .ollama
				provider:    p
				handler:     h
				runtime:     ProviderRuntimeAdapter{
					provider: p
				}
			})
		}
	}
}

fn provider_register_and_start(mut app App, name string, p Provider) {
	app.register_provider(name, p)
	p.init(mut app) or {
		app.emit('provider.init_failed', {
			'name':  name
			'error': err.msg()
		})
		return
	}
	p.start(mut app) or {
		app.emit('provider.start_failed', {
			'name':  name
			'error': err.msg()
		})
	}
}
