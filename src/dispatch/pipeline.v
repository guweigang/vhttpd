module dispatch

pub struct PipelineDescriptor {
pub:
	id         string
	group      string
	ingress    string
	transforms []string
	policies   []string
	egress     string
	required   Capabilities
}

pub struct TransformDescriptor {
pub:
	id           string
	kind         string
	handler      string
	capabilities Capabilities
}

pub struct TerminalDescriptor {
pub:
	id           string
	capabilities Capabilities
}

pub struct PipelineCapabilityIssue {
pub:
	code       string
	pipeline   string
	ingress    string
	transform  string
	capability string
}

pub fn (issue PipelineCapabilityIssue) message() string {
	if issue.transform != '' {
		return '${issue.code}:${issue.pipeline}:${issue.ingress}:transform:${issue.transform}:${issue.capability}'
	}
	return '${issue.code}:${issue.pipeline}:${issue.ingress}:${issue.capability}'
}

pub fn capabilities_satisfy(available Capabilities, required Capabilities) bool {
	return (!required.request_response || available.request_response)
		&& (!required.events || available.events)
		&& (!required.stream_input || available.stream_input)
		&& (!required.stream_output || available.stream_output)
		&& (!required.full_duplex || available.full_duplex)
		&& (!required.sessions || available.sessions)
		&& (!required.multiplexing || available.multiplexing)
		&& (!required.cancellation || available.cancellation)
		&& (!required.backpressure || available.backpressure)
		&& (!required.replay || available.replay)
}

pub fn missing_capabilities(available Capabilities, required Capabilities) []string {
	mut missing := []string{}
	if required.request_response && !available.request_response {
		missing << 'request_response'
	}
	if required.events && !available.events {
		missing << 'events'
	}
	if required.stream_input && !available.stream_input {
		missing << 'stream_input'
	}
	if required.stream_output && !available.stream_output {
		missing << 'stream_output'
	}
	if required.full_duplex && !available.full_duplex {
		missing << 'full_duplex'
	}
	if required.sessions && !available.sessions {
		missing << 'sessions'
	}
	if required.multiplexing && !available.multiplexing {
		missing << 'multiplexing'
	}
	if required.cancellation && !available.cancellation {
		missing << 'cancellation'
	}
	if required.backpressure && !available.backpressure {
		missing << 'backpressure'
	}
	if required.replay && !available.replay {
		missing << 'replay'
	}
	return missing
}

pub fn pipeline_capabilities_valid(pipeline PipelineDescriptor, ingress IngressDescriptor) bool {
	_ = pipeline
	return capabilities_satisfy(ingress.capabilities, pipeline.required)
}

pub fn pipeline_capability_errors(pipeline PipelineDescriptor, ingress IngressDescriptor) []string {
	return pipeline_capability_issues(pipeline, ingress).map(it.message())
}

pub fn pipeline_capability_issues(pipeline PipelineDescriptor, ingress IngressDescriptor) []PipelineCapabilityIssue {
	mut issues := []PipelineCapabilityIssue{}
	for capability in missing_capabilities(ingress.capabilities, pipeline.required) {
		issues << PipelineCapabilityIssue{
			code:       'pipeline_capability_mismatch'
			pipeline:   pipeline.id
			ingress:    ingress.id
			capability: capability
		}
	}
	return issues
}

pub interface PipelineDispatcher {
	id() string
mut:
	dispatch(mut services RuntimeServices, mut exchange Exchange) !DeliveryOutcome
}
