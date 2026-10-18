module executor

enum InProcVjsxHostFallback {
	request_only
	lane
	executor
}

// The host and request metadata are captured together under the state lock.
// Callers invoke host services only after this lookup releases the lock.
struct InProcVjsxRequestHost {
	host    EmbeddedHost @[required]
	context InProcVjsxRequestContext
	lane_id string
}

fn (mut state VjsxExecutorState) request_host(idx int, fallback InProcVjsxHostFallback) ?InProcVjsxRequestHost {
	state.mu.@lock()
	defer { state.mu.unlock() }
	mut lane_id := ''
	if idx >= 0 && idx < state.lanes.len {
		lane_id = state.lanes[idx].id
	}
	if idx >= 0 && idx < state.hosts.len {
		context := state.hosts[idx].request_ctx
		if context.active {
			if host := context.app {
				return InProcVjsxRequestHost{
					host:    host
					context: context
					lane_id: if context.lane_id != '' { context.lane_id } else { lane_id }
				}
			}
		}
		if fallback == .lane {
			if host := state.hosts[idx].app_ref {
				return InProcVjsxRequestHost{ host: host, lane_id: lane_id }
			}
		}
	}
	if fallback == .executor {
		if host := state.app_ref {
			return InProcVjsxRequestHost{ host: host, lane_id: lane_id }
		}
	}
	return none
}

fn (mut state VjsxExecutorState) remembered_host() ?EmbeddedHost {
	state.mu.@lock()
	defer { state.mu.unlock() }
	return state.app_ref
}
