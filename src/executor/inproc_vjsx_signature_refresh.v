module executor

import time

struct InProcVjsxSignatureRefresh {}

fn InProcVjsxSignatureRefresh.loop(mut state VjsxExecutorState) {
	state.mu.@lock()
	config := state.facade.config
	state.mu.unlock()
	mut scanner := VjsxSourceScanner.new(config)
	mut last_probe := ''
	mut pending_since := i64(0)
	for {
		mut stop := false
		mut last_checked_at := i64(0)
		state.mu.@lock()
		stop = state.signature_refresh_stop
		last_probe = if last_probe != '' { last_probe } else { state.cached_source_probe }
		pending_since = if pending_since > 0 { pending_since } else { state.signature_pending_since }
		last_checked_at = state.signature_last_checked_at
		state.mu.unlock()
		if stop {
			return
		}
		now := time.now().unix_milli()
		mut next_probe := if config.app_entry.trim_space() != '' {
			scanner.probe()
		} else {
			''
		}
		probe_changed := next_probe != last_probe
		if probe_changed {
			last_probe = next_probe
			pending_since = now
		}
		needs_full_refresh := probe_changed || (pending_since > 0
			&& now - pending_since >= inproc_vjsx_signature_refresh_debounce_ms)
			|| (last_checked_at <= 0
			|| now - last_checked_at >= inproc_vjsx_signature_full_refresh_ms)
		mut next_signature := ''
		if needs_full_refresh {
			// Full refresh also discovers topology changes. This preserves the
			// one-second content check, including same-size/same-mtime edits.
			scanner.refresh_files()
			next_signature = if config.app_entry.trim_space() != '' {
				scanner.signature()
			} else {
				''
			}
			next_probe = scanner.probe()
			last_probe = next_probe
		}
		state.mu.@lock()
		if state.signature_refresh_stop {
			state.mu.unlock()
			return
		}
		state.cached_source_probe = next_probe
		state.signature_last_probe_at = now
		state.signature_pending_since = pending_since
		if needs_full_refresh {
			state.cached_source_signature = next_signature
			state.signature_last_checked_at = now
			state.signature_pending_since = 0
			pending_since = 0
		}
		state.signature_last_error = ''
		mut allocator_busy := false
		if needs_full_refresh {
			allocator_busy = state.host_builders > 0 || state.warmup_running
				|| state.app_startup_running || state.tasks.len > 0
			for lane in state.lanes {
				allocator_busy = allocator_busy || lane.inflight > 0
			}
		}
		state.mu.unlock()
		// Allocator maintenance can take libc locks. Keep it outside state.mu
		// and off dispatch threads; the native helper rate-limits all engines.
		if needs_full_refresh { maintain_inproc_vjsx_allocator(allocator_busy) }
		time.sleep(time.millisecond * inproc_vjsx_signature_probe_poll_ms)
	}
}

fn (e InProcVjsxExecutor) current_source_signature() string {
	mut state := e.state
	state.mu.@lock()
	mut cached := state.cached_source_signature
	config := state.facade.config
	state.mu.unlock()
	if cached != '' {
		return cached
	}
	if config.app_entry.trim_space() == '' {
		return ''
	}
	cached = config.source_signature()
	state.mu.@lock()
	if state.cached_source_signature == '' {
		state.cached_source_signature = cached
		state.signature_last_checked_at = time.now().unix_milli()
		state.signature_last_error = ''
	}
	result := state.cached_source_signature
	state.mu.unlock()
	return result
}
