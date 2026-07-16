module executor

struct InProcVjsxRuntimeMeta {
	provider                 string
	executor                 string
	dispatch_kind            string            @[json: 'dispatchKind']
	lane_id                  string            @[json: 'laneId']
	request_id               string            @[json: 'requestId']
	trace_id                 string            @[json: 'traceId']
	app_entry                string            @[json: 'appEntry']
	module_root              string            @[json: 'moduleRoot']
	build_root               string            @[json: 'buildRoot']
	runtime_profile          string            @[json: 'runtimeProfile']
	thread_count             int               @[json: 'threadCount']
	enable_fs                bool              @[json: 'enableFs']
	enable_process           bool              @[json: 'enableProcess']
	enable_network           bool              @[json: 'enableNetwork']
	request_scheme           string            @[json: 'requestScheme']
	request_host             string            @[json: 'requestHost']
	request_port             string            @[json: 'requestPort']
	request_target           string            @[json: 'requestTarget']
	request_protocol_version string            @[json: 'requestProtocolVersion']
	request_remote_addr      string            @[json: 'requestRemoteAddr']
	request_server           map[string]string @[json: 'requestServer']
	upstream_provider        string            @[json: 'upstreamProvider']
	upstream_instance        string            @[json: 'upstreamInstance']
	upstream_event           string            @[json: 'upstreamEvent']
	upstream_event_type      string            @[json: 'upstreamEventType']
	upstream_message_id      string            @[json: 'upstreamMessageId']
	upstream_target          string            @[json: 'upstreamTarget']
	upstream_target_type     string            @[json: 'upstreamTargetType']
	upstream_received_at     i64               @[json: 'upstreamReceivedAt']
	upstream_metadata        map[string]string @[json: 'upstreamMetadata']
	method                   string
	path                     string
}
