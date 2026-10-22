module plugin

import config
import executor
import json2 as json

// A caller retaining its original arrays cannot mutate the published
// generation or change the equality check that decides executor retirement.
fn owned_plugin_configs(input map[string]config.PluginConfig) map[string]config.PluginConfig {
 mut owned := map[string]config.PluginConfig{}
 for name, cfg in input {
  owned[name] = config.PluginConfig{
   ...cfg
   signature_include: cfg.signature_include.clone()
   signature_exclude: cfg.signature_exclude.clone()
  }
 }
 return owned
}

// Lookup captures configuration and executor from the same published generation.
// Executor lane admission handles a snapshot racing retirement.
pub fn (mut state PluginState) lookup(name string) !executor.InProcVjsxExecutor {
	state.mu.@lock()
	defer { state.mu.unlock() }
	if state.closed { return error('plugin_runtime_unavailable:${name}') }
	cfg := state.configs[name] or { return error('plugin_not_configured:${name}') }
	if cfg.kind.trim_space().to_lower() !in ['', 'vjsx'] {
		return error('plugin_unsupported_kind:${name}:${cfg.kind}')
	}
	return state.vjsx[name] or { return error('plugin_runtime_unavailable:${name}') }
}

// Retired executors remain owned until draining completes, including when final
// shutdown overlaps a reload. No executor.close is called under the owner lock.
pub fn (mut state PluginState) publish(input map[string]config.PluginConfig) int {
	state.mu.@lock()
	defer { state.mu.unlock() }
	if state.closed { return 0 }
	configs := owned_plugin_configs(input)
	mut next := map[string]executor.InProcVjsxExecutor{}
	mut retired := []executor.InProcVjsxExecutor{}
	mut retained := map[string]bool{}
	for name, cfg in configs {
		if old := state.configs[name] {
			if json.encode(old, escape_unicode: true, time_as_unix: true) == json.encode(cfg,
				escape_unicode: true
				time_as_unix:   true
			) {
				if runtime := state.vjsx[name] {
					next[name] = runtime
					retained[name] = true
				}
				continue
			}
		}
		built := build_vjsx_plugin_runtimes({
			name: cfg
		})
		if runtime := built[name] { next[name] = runtime }
	}
	for name, runtime in state.vjsx {
		if retained[name] { continue }
		retired << runtime
	}
	state.configs = configs
	state.vjsx = next
	if retired.len == 0 { return 0 }
	state.next_retirement++
	id := state.next_retirement
	state.retiring[id] = retired
	return id
}

pub fn (mut state PluginState) finish_retirement(id int) {
	if id == 0 { return }
	state.mu.@lock()
	batch := state.retiring[id].clone()
	state.mu.unlock()
	for runtime in batch { runtime.close() }
	state.mu.@lock()
	state.retiring.delete(id)
	state.mu.unlock()
}

pub fn (mut state PluginState) close() {
	state.mu.@lock()
	if state.closed {
		id := state.shutdown_retirement
		state.mu.unlock()
		state.finish_retirement(id)
		return
	}
	state.closed = true
	mut runtimes := state.vjsx.values()
	for _, batch in state.retiring { runtimes << batch }
	// Keep draining batches visible to concurrent closers until close completes.
	state.vjsx.clear()
	state.next_retirement++
	id := state.next_retirement
	state.retiring[id] = runtimes
	state.shutdown_retirement = id
	state.mu.unlock()
	state.finish_retirement(id)
}
