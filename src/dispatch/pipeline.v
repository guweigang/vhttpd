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

pub interface PipelineDispatcher {
	id() string
mut:
	dispatch(mut services RuntimeServices, mut exchange Exchange) !DeliveryOutcome
}
