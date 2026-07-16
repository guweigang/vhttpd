module executor

import json
import upstream.transport

fn (e InProcVjsxExecutor) build_websocket_upstream_runtime_payload(lane VjsxExecutionLane, req transport.WorkerWebSocketUpstreamDispatchRequest) string {
	config := e.facade_snapshot().config
	return json.encode(InProcVjsxRuntimeMeta{
		provider:                 e.provider()
		executor:                 e.kind()
		dispatch_kind:            'websocket_upstream'
		lane_id:                  lane.id
		request_id:               req.id
		trace_id:                 req.trace_id
		app_entry:                config.app_entry
		module_root:              config.module_root
		build_root:               config.build_root
		runtime_profile:          config.runtime_profile
		thread_count:             config.thread_count
		enable_fs:                config.enable_fs
		enable_process:           config.enable_process
		enable_network:           config.enable_network
		request_scheme:           ''
		request_host:             ''
		request_port:             ''
		request_target:           req.target
		request_protocol_version: ''
		request_remote_addr:      ''
		request_server:           map[string]string{}
		upstream_provider:        req.provider
		upstream_instance:        req.instance
		upstream_event:           req.event
		upstream_event_type:      req.event_type
		upstream_message_id:      req.message_id
		upstream_target:          req.target
		upstream_target_type:     req.target_type
		upstream_received_at:     req.received_at
		upstream_metadata:        req.metadata.clone()
		method:                   ''
		path:                     req.target
	})
}

fn (e InProcVjsxExecutor) websocket_runtime_meta(lane VjsxExecutionLane, frame transport.WorkerWebSocketFrame) InProcVjsxRuntimeMeta {
	config := e.facade_snapshot().config
	server := InProcVjsxWebSocketRequest.server_map(frame)
	host := server['host'] or { '' }
	port := server['port'] or { '' }
	target := server['url'] or { frame.path }
	return InProcVjsxRuntimeMeta{
		provider:                 e.provider()
		executor:                 e.kind()
		dispatch_kind:            'websocket'
		lane_id:                  lane.id
		request_id:               frame.request_id
		trace_id:                 frame.trace_id
		app_entry:                config.app_entry
		module_root:              config.module_root
		build_root:               config.build_root
		runtime_profile:          config.runtime_profile
		thread_count:             config.thread_count
		enable_fs:                config.enable_fs
		enable_process:           config.enable_process
		enable_network:           config.enable_network
		request_scheme:           InProcVjsxWebSocketRequest.scheme_from_frame(frame)
		request_host:             host
		request_port:             port
		request_target:           target
		request_protocol_version: ''
		request_remote_addr:      frame.remote_addr
		request_server:           server
		method:                   frame.event.to_upper()
		path:                     frame.path
	}
}

fn (e InProcVjsxExecutor) build_websocket_runtime_payload(lane VjsxExecutionLane, frame transport.WorkerWebSocketFrame) string {
	return json.encode(e.websocket_runtime_meta(lane, frame))
}

fn (e InProcVjsxExecutor) build_websocket_frame_bundle_payload(lane VjsxExecutionLane, frame transport.WorkerWebSocketFrame) string {
	return json.encode(InProcVjsxWebSocketFrameBundle{
		raw:     frame
		runtime: e.websocket_runtime_meta(lane, frame)
	})
}
