module dispatch

fn test_capabilities_satisfy_when_required_subset_is_available() {
	available := Capabilities{
		request_response: true
		events:           true
		stream_output:    true
	}
	required := Capabilities{
		request_response: true
		events:           true
	}
	assert capabilities_satisfy(available, required)
	assert missing_capabilities(available, required).len == 0
}

fn test_capabilities_report_missing_fields_in_stable_order() {
	available := Capabilities{
		request_response: true
	}
	required := Capabilities{
		request_response: true
		events:           true
		sessions:         true
		full_duplex:      true
	}
	missing := missing_capabilities(available, required)
	assert missing == ['events', 'full_duplex', 'sessions']
	assert !capabilities_satisfy(available, required)
}

fn test_pipeline_capability_errors_include_pipeline_and_ingress() {
	pipeline := PipelineDescriptor{
		id:       'chat/ws'
		ingress:  'listener:http'
		egress:   'adapter:websocket'
		required: Capabilities{
			sessions:    true
			full_duplex: true
		}
	}
	ingress := IngressDescriptor{
		id:           'listener:http'
		capabilities: Capabilities{
			request_response: true
		}
	}
	assert !pipeline_capabilities_valid(pipeline, ingress)
	assert pipeline_capability_errors(pipeline, ingress) == [
		'pipeline_capability_mismatch:chat/ws:listener:http:full_duplex',
		'pipeline_capability_mismatch:chat/ws:listener:http:sessions',
	]
	issues := pipeline_capability_issues(pipeline, ingress)
	assert issues.len == 2
	assert issues[0].code == 'pipeline_capability_mismatch'
	assert issues[0].pipeline == 'chat/ws'
	assert issues[0].ingress == 'listener:http'
	assert issues[0].capability == 'full_duplex'
	assert issues[0].message() == 'pipeline_capability_mismatch:chat/ws:listener:http:full_duplex'
}
