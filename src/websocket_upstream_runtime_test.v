module main

fn test_websocket_upstream_reconnect_and_admin_helpers() {
    mut app := App{
        codex: CodexState{
            runtime: CodexProviderRuntime{}
        }
    }

    // reconnect delay default
    assert websocket_upstream_provider_reconnect_delay_ms(&app, websocket_upstream_provider_codex, 'main') == 3000

    app.codex.runtime.reconnect_delay_ms = 7200
    assert websocket_upstream_provider_reconnect_delay_ms(&app, websocket_upstream_provider_codex, 'main') == 7200

    // admin snapshot includes config mapping
    app.codex.runtime.enabled = true
    app.codex.runtime.url = 'https://example'
    app.codex.runtime.model = 'm'
    snap := app.admin_codex_snapshot()
    assert snap.enabled
    assert snap.config.url == 'https://example'
    assert snap.config.model == 'm'
}
