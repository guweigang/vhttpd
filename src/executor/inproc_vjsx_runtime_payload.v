module executor

import json
import upstream.transport

struct InProcVjsxRequestPayload {}

fn InProcVjsxRequestPayload.build(req HttpLogicDispatchRequest) string {
	return transport.WorkerHttpRequestCodec.encode_request(req.method, req.path, req.req,
		req.remote_addr, req.trace_id, req.request_id)
}

fn (e InProcVjsxExecutor) build_runtime_payload(lane VjsxExecutionLane, req HttpLogicDispatchRequest) string {
	normalized_path, _ := transport.WorkerHttpRequestCodec.normalize_request_target(req.path)
	config := e.facade_snapshot().config
	server := transport.WorkerHttpRequestCodec.server_map_from_request(req.req, req.remote_addr)
	host := server['host'] or { req.req.host }
	port := server['port'] or { '' }
	scheme := req.req.header.get(.x_forwarded_proto) or { 'http' }
	target := server['url'] or { req.path }
	return json.encode(InProcVjsxRuntimeMeta{
		provider:                 e.provider()
		executor:                 e.kind()
		dispatch_kind:            'http'
		lane_id:                  lane.id
		request_id:               req.request_id
		trace_id:                 req.trace_id
		app_entry:                config.app_entry
		module_root:              config.module_root
		build_root:               config.build_root
		runtime_profile:          config.runtime_profile
		thread_count:             config.thread_count
		enable_fs:                config.enable_fs
		enable_process:           config.enable_process
		enable_network:           config.enable_network
		request_scheme:           scheme
		request_host:             host
		request_port:             port
		request_target:           target
		request_protocol_version: req.req.version.str().trim_left('HTTP/')
		request_remote_addr:      req.remote_addr
		request_server:           server
		method:                   req.method.to_upper()
		path:                     normalized_path
	})
}
