module main

import worker

// Each caller chooses its established alias/fallback policy explicitly.
enum EngineLookupMode {
	worker_config
	executor_kind
	dispatch_pool
	drain_pool
}

struct EngineLookup {
	pool       string
	state      &worker.WorkerState
	is_primary bool
}

fn (runtime &EngineRuntime) lookup_engine(key string, mode EngineLookupMode) ?EngineLookup {
	if mode == .dispatch_pool {
		if key != '' {
			if state := runtime.additional[key] {
				return EngineLookup{ pool: key, state: state }
			}
		}
		return EngineLookup{ pool: 'main', state: runtime.primary, is_primary: true }
	}
	is_primary := key == runtime.primary_kind() || (mode != .executor_kind && key == '')
		|| (mode == .drain_pool && key in ['main', 'primary'])
	if is_primary {
		return EngineLookup{ pool: 'main', state: runtime.primary, is_primary: true }
	}
	if state := runtime.additional[key] {
		return EngineLookup{ pool: key, state: state }
	}
	return none
}
