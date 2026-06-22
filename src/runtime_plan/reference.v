module runtime_plan

pub enum RefDomain {
	listener
	resource
	engine
	adapter
	transform
	policy
	pipeline
	relay
	terminal
}

pub struct ResourceRef {
pub:
	domain RefDomain
	id     string
}

pub fn parse_ref(value string) !ResourceRef {
	trimmed := value.trim_space()
	separator := trimmed.index(':') or { return error('plan_ref_missing_domain:${trimmed}') }
	domain_name := trimmed[..separator]
	id := trimmed[separator + 1..].trim_space()
	if id == '' {
		return error('plan_ref_missing_id:${trimmed}')
	}
	domain := match domain_name {
		'listener' { RefDomain.listener }
		'resource' { RefDomain.resource }
		'engine' { RefDomain.engine }
		'adapter' { RefDomain.adapter }
		'transform' { RefDomain.transform }
		'policy' { RefDomain.policy }
		'pipeline' { RefDomain.pipeline }
		'relay' { RefDomain.relay }
		'terminal' { RefDomain.terminal }
		else { return error('plan_ref_unknown_domain:${domain_name}') }
	}
	return ResourceRef{
		domain: domain
		id:     id
	}
}

pub fn (reference ResourceRef) str() string {
	return '${reference.domain}:${reference.id}'
}
