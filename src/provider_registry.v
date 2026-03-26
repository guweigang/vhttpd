module main

import json

// Minimal provider registry to enable pluggable upstream providers.
// Non-breaking: adapters delegate to existing provider code (eg feishu_runtime.*).

pub interface Provider {
	init(mut app App) ?
	start(mut app App) ?
	stop(mut app App) ?
	// Return a JSON string snapshot for admin visibility.
	snapshot(mut app App) string
}

// Global registry (kept minimal and simple).
// The registry is now owned by App to avoid top-level mutable globals which
// can be problematic across V versions. Helper functions below remain for
// convenience but are thin wrappers around App methods when called with an
// App reference.

// NOTE: App now exposes methods to register and query providers via
// ProviderHost on App, instead of top-level mutable globals.

pub fn register_provider(name string, p Provider) {
    // Backwards-compatible global registration is not supported anymore.
    // Callers should use app.register_provider(name, p). Keep this function
    // as a panic to surface incorrect usage during compile-time tests.
    panic('register_provider(name, p) is deprecated; use app.register_provider(name, p)')
}

pub fn get_provider(name string) ?Provider {
    panic('get_provider(name) is deprecated; use app.get_provider(name)')
}

pub fn provider_names() []string {
    panic('provider_names() is deprecated; use app.provider_names()')
}

// Simple Feishu adapter implementing Provider by delegating to existing functions.
pub struct FeishuProvider {}

// Note: Provider interface expects immutable receiver for `init/start/stop` so
// adapters implement methods with immutable receiver to match the interface.
pub fn (p FeishuProvider) init(mut app App) ? {
    // No-op for now; existing Feishu runtime remains owned by App.
    return none
}

pub fn (p FeishuProvider) start(mut app App) ? {
    // No-op: server startup already launches websocket provider goroutines.
    return none
}

pub fn (p FeishuProvider) stop(mut app App) ? {
    // No-op placeholder for graceful shutdown in future.
    return none
}

pub fn (p FeishuProvider) snapshot(mut app App) string {
    return app.provider_runtime_snapshot('feishu') or { '{}' }
}

// Codex adapter: thin delegator to existing codex runtime snapshot and hooks.
pub struct CodexProvider {}

pub fn (p CodexProvider) init(mut app App) ? {
    // No-op: codex runtime initialization is managed by codex_runtime.v logic.
    return none
}

pub fn (p CodexProvider) start(mut app App) ? {
    // No-op: codex connection loops are started elsewhere when enabled.
    return none
}

pub fn (p CodexProvider) stop(mut app App) ? {
    // No-op placeholder for graceful shutdown in future.
    return none
}

pub fn (p CodexProvider) snapshot(mut app App) string {
    // Reuse existing admin snapshot function for Codex runtime.
    return json.encode(app.admin_codex_snapshot())
}

// Ollama adapter skeleton — thin delegator for Ollama upstreams (NDJSON style).
pub struct OllamaProvider {}

pub fn (p OllamaProvider) init(mut app App) ? {
    // No-op: Ollama runtime initialization will be implemented when added.
    return none
}

pub fn (p OllamaProvider) start(mut app App) ? {
    // No-op: Ollama connection loops are started elsewhere when enabled.
    return none
}

pub fn (p OllamaProvider) stop(mut app App) ? {
    // No-op placeholder for graceful shutdown in future.
    return none
}

pub fn (p OllamaProvider) snapshot(mut app App) string {
    // If Ollama runtime snapshot helper is added, delegate here. For now
    // return an empty object representation so admin tooling can display it.
    return json.encode(map[string]string{})
}
