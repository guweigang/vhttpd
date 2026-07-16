module codex

// ── ProviderRuntime Instance Helpers ──

// normalize_instance normalizes an instance string to its canonical name.
// Empty or "default" become "main"; all others pass through trimmed.
pub fn ProviderRuntime.normalize_instance(instance string) string {
	name := instance.trim_space()
	if name == '' || name == 'default' {
		return 'main'
	}
	return name
}

// for_instance creates a ProviderRuntime for the given instance name, inheriting
// config from the base runtime.
pub fn (base ProviderRuntime) for_instance(instance string) ProviderRuntime {
	resolved := ProviderRuntime.normalize_instance(instance)
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
	resolved := ProviderRuntime.normalize_instance(instance)
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
		return s.instances[resolved] or { s.runtime.for_instance(resolved) }
	}
	return s.runtime.for_instance(resolved)
}

pub fn (mut s CodexState) update(instance string, rt ProviderRuntime) {
	resolved := ProviderRuntime.normalize_instance(instance)
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
