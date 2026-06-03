module codex

// ── Pure Helpers ──

// instance_name normalizes an instance string to its canonical name.
// Empty or "default" become "main"; all others pass through trimmed.
pub fn instance_name(instance string) string {
	name := instance.trim_space()
	if name == '' || name == 'default' {
		return 'main'
	}
	return name
}

// build_provider_runtime_from_base creates a ProviderRuntime for the given
// instance name, inheriting config from the base runtime.
pub fn build_provider_runtime_from_base(base ProviderRuntime, instance string) ProviderRuntime {
	resolved := instance_name(instance)
	return ProviderRuntime{
		instance:            resolved
		enabled:             base.enabled
		url:                 base.url
		model:               base.model
		effort:              base.effort
		cwd:                 base.cwd
		approval_policy:     base.approval_policy
		sandbox:             base.sandbox
		reconnect_delay_ms:  base.reconnect_delay_ms
		flush_interval_ms:   base.flush_interval_ms
		stream_map:          map[string][]CodexTarget{}
		pending_rpcs:        map[int]PendingRpc{}
		err_bursts:          map[string][]string{}
		err_pending_flushes: map[string]bool{}
		thread_stream_map:   map[string]string{}
		read_fallbacks:      map[string]ReadFallback{}
	}
}

// ── CodexState Instance Management ──

pub fn (mut s CodexState) snapshot(instance string) ProviderRuntime {
	resolved := instance_name(instance)
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	if resolved == 'main' {
		if s.runtime.instance == '' {
			s.runtime.instance = 'main'
		}
		return s.runtime
	}
	if resolved in s.instances {
		return s.instances[resolved] or {
			build_provider_runtime_from_base(s.runtime, resolved)
		}
	}
	return build_provider_runtime_from_base(s.runtime, resolved)
}

pub fn (mut s CodexState) update(instance string, rt ProviderRuntime) {
	resolved := instance_name(instance)
	s.mu.@lock()
	defer {
		s.mu.unlock()
	}
	if resolved == 'main' {
		s.runtime = rt
		if s.runtime.instance == '' {
			s.runtime.instance = 'main'
		}
		return
	}
	s.instances[resolved] = rt
}
