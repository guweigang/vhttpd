module main

import worker

struct PipelineRuntime {
pub:
	http HttpRoutingRuntime
}

fn PipelineRuntime.new(listener_id string, routes []RuntimeRouteRule, assets_root string, worker_root string, primary_env map[string]string, additional_workers map[string]&worker.WorkerState) PipelineRuntime {
	return PipelineRuntime{
		http: HttpRoutingRuntime.new(listener_id, routes, assets_root, worker_root, primary_env,
			additional_workers)
	}
}
